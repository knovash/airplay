package Plugins::AirPlay2Bridge::BridgeProcess;

# Управление python-процессами моста (bridge.py) — по одному на каждый HomePod.
# Формат настройки players (одна строка = один плеер):
#   name,player_mac,airplay_id,homepod_ip
# Запуск: python3 -u bridge.py name mac airplay_id ip 127.0.0.1 (SQUEEZELITE_BIN=...)
# Контроль: pid-файл на плеер + kill 0, автоперезапуск таймером beat() каждые 30 с.

use strict;

use File::Spec::Functions qw(catdir catfile);
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::OSDetect;
use Slim::Utils::PluginManager;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Time::HiRes;

my $prefs = preferences('plugin.airplay2bridge');
my $log   = logger('plugin.airplay2bridge');

my $pluginModule = 'Plugins::AirPlay2Bridge::Plugin';

sub baseDir {
	my $plugins = Slim::Utils::PluginManager->allPlugins;
	return $plugins->{'AirPlay2Bridge'}->{'basedir'} if $plugins->{'AirPlay2Bridge'} && $plugins->{'AirPlay2Bridge'}->{'basedir'};
	while (my ($name, $data) = each %$plugins) {
		next unless ref $data;
		if (($data->{'module'} || '') eq $pluginModule && $data->{'basedir'}) {
			return $data->{'basedir'};
		}
	}
	return;
}

sub dataDir {
	my $dir = catdir(Slim::Utils::OSDetect::dirsFor('cache'), 'AirPlay2Bridge');
	mkdir $dir if !-d $dir;
	return $dir;
}

sub bridgeBin {
	my $custom = $prefs->get('bridgebin') || '';
	return $custom if $custom && -e $custom;
	my $base = baseDir() || return;
	return catfile($base, 'Bin', 'bridge.py');
}

# разбор настройки players -> listref of {name, mac, macid, host, pid, log}
sub playerList {
	my @out;
	my $text = $prefs->get('players') || '';
	for my $line (split /[\r\n]+/, $text) {
		$line =~ s/^\s+|\s+$//g;
		next unless $line =~ /\S/;
		next if $line =~ /^#/;
		my ($name, $mac, $id, $host) = split /\s*,\s*/, $line;
		next unless $name && $mac && $host;
		(my $macid = $mac) =~ s/://g;
		push @out, {
			name  => $name,
			mac   => $mac,
			macid => lc($macid),
			id    => $id || '',
			host  => $host,
			pid   => catfile(dataDir(), "bridge-$macid.pid"),
			log   => catfile(dataDir(), "bridge-$macid.log"),
		};
	}
	return \@out;
}

sub pythonPath {
	my $path = $prefs->get('pythonpath') || '';
	$path =~ s/^\s+|\s+$//g;
	return $path if $path && -x $path;
	return Slim::Utils::Misc::findbin('python3') || '/usr/bin/python3';
}

# ---- состояние процесса ----

sub _readPid {
	my ($file) = @_;
	return unless -e $file;
	open my $fh, '<', $file or return;
	my $pid = <$fh>;
	close $fh;
	return unless defined $pid;
	$pid =~ s/\D//g;
	return $pid || undef;
}

sub _pidIsOurs {
	my ($pid, $name) = @_;
	return 0 unless $pid && $pid > 1;
	return 0 unless kill(0, $pid);
	my $cmd = '';
	if (open my $fh, '<', "/proc/$pid/cmdline") {
		local $/;
		$cmd = <$fh>;
		close $fh;
	}
	return 1 unless defined $cmd && length $cmd;
	return index($cmd, 'bridge.py') >= 0 && index($cmd, $name) >= 0;
}

sub alive {
	my ($class, $p) = @_;
	my $pid = _readPid($p->{'pid'});
	return ($pid && _pidIsOurs($pid, $p->{'name'})) ? $pid : 0;
}

# ---- запуск/остановка ----

sub _startOne {
	my ($class, $p) = @_;

	return 1 if $class->alive($p);

	my $py  = pythonPath();
	my $bin = bridgeBin();
	if (!$bin || !-e $bin) {
		$log->error('AirPlay2Bridge: bridge.py not found: ' . ($bin || '<basedir>/Bin/bridge.py'));
		return;
	}
	my $sq = $prefs->get('squeezelite') || '/usr/local/bin/squeezelite-ap2';
	my $lmsip = $prefs->get('lmsip') || '127.0.0.1';

	my $shell = join('',
		"SQUEEZELITE_BIN='$sq' exec '$py' -u '$bin' ",
		"'$p->{'name'}' '$p->{'mac'}' '$p->{'id'}' '$p->{'host'}' '$lmsip' ",
		">> '$p->{'log'}' 2>&1 & echo \$! > '$p->{'pid'}'");

	$log->info("starting bridge for $p->{'name'} -> $p->{'host'}");
	my $rc = system('/bin/sh', '-c', $shell);
	if ($rc != 0) {
		$log->error("AirPlay2Bridge: cannot start bridge for $p->{'name'} (rc=$rc)");
		return;
	}
	return 1;
}

sub _stopOne {
	my ($class, $p) = @_;
	my $pid = _readPid($p->{'pid'});
	if ($pid && kill(0, $pid)) {
		$log->info("stopping bridge for $p->{'name'} (pid $pid)");
		kill('TERM', $pid);
		for (1..15) {
			last unless kill(0, $pid);
			select(undef, undef, undef, 0.2);
		}
		kill('KILL', $pid) if kill(0, $pid);
	}
	unlink $p->{'pid'} if -e $p->{'pid'};
}

sub startAll {
	my $class = shift;
	my $players = playerList();
	for my $p (@$players) {
		$class->_startOne($p);
	}
	Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 30, \&beat);
}

sub stopAll {
	my $class = shift;
	my $players = playerList();
	for my $p (@$players) {
		$class->_stopOne($p);
	}
}

# перезапуск упавших + подхват добавленных в настройках
sub beat {
	my $class = shift;
	if ($prefs->get('enabled')) {
		my $players = playerList();
		for my $p (@$players) {
			if (!$class->alive($p)) {
				$log->error("bridge for $p->{'name'} crashed - restarting");
				$class->_startOne($p);
			}
		}
	}
	Slim::Utils::Timers::setTimer($class, Time::HiRes::time() + 30, \&beat);
}

# вызывается из Settings после сохранения: перезапустить всё по новой конфигурации
sub restartAll {
	my $class = shift;
	$class->stopAll;
	sleep 1;
	$class->startAll if $prefs->get('enabled');
}

1;