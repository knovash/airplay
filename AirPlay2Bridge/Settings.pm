package Plugins::AirPlay2Bridge::Settings;

# Страница настроек AirPlay2Bridge: discovery-скан AirPlay-устройств (кнопка Scan,
# как у RaopBridge) + таблица с галочками выбора, имена редактируемые.
# Данные: pref devices = TSV-строки "id\tname\tip\tmac\tenabled\tmodel\tov".
#   MAC никогда не генерируется заново для известного id (наследование плейлистов
#   RaopBridge). pref players (формат BridgeProcess) генерируется из devices при Save.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.airplay2bridge');
my $log   = logger('plugin.airplay2bridge');

sub name { 'PLUGIN_AIRPLAY2_BRIDGE' }

sub page { 'plugins/AirPlay2Bridge/settings/basic.html' }

# ---------- devices pref ----------

sub _parseDevices {
	my ($text) = @_;
	my @out;
	for my $line (split /[\r\n]+/, $text || '') {
		next unless $line =~ /\S/;
		my @f = split /\t/, $line, -1;
		next unless @f >= 4 && $f[0] ne '';
		push @out, {
			id      => $f[0],
			name    => $f[1] ne '' ? $f[1] : $f[0],
			ip      => $f[2],
			mac     => $f[3],
			enabled => ($f[4] // '0') eq '1' ? 1 : 0,
			model   => $f[5] // '',
			ov      => $f[6] // '',
			absent  => 0,
			warn    => 0,
		};
	}
	return \@out;
}

sub _devicesToStr {
	my ($devs) = @_;
	return join "\n", map {
		join "\t", $_->{id}, $_->{name}, $_->{ip}, $_->{mac}, $_->{enabled} ? 1 : 0, $_->{model} || '', $_->{ov} || ''
	} @$devs;
}

sub _devices {
	return _parseDevices($prefs->get('devices'));
}

# мак для НОВОГО устройства: aa:aa + первые 4 байта airplay-id (схема RaopBridge)
sub _deriveMac {
	my ($id) = @_;
	my $hex = uc($id // '');
	$hex =~ s/[^0-9A-F]//g;
	$hex = substr($hex . '00000000', 0, 8);
	return sprintf('aa:aa:%s:%s:%s:%s',
		substr($hex, 0, 2), substr($hex, 2, 2), substr($hex, 4, 2), substr($hex, 6, 2));
}

# миграция: devices пуст -> сеем из players (все включены)
sub _seedFromPlayers {
	my @devs;
	for my $line (split /[\r\n]+/, $prefs->get('players') || '') {
		next unless $line =~ /\S/;
		my ($name, $mac, $id, $host) = split /\s*,\s*/, $line;
		next unless $name && $mac && $host;
		push @devs, { id => ($id || $host), name => $name, ip => $host, mac => $mac,
			enabled => 1, model => '', ov => '', absent => 0, warn => 0 };
	}
	$prefs->set('devices', _devicesToStr(\@devs)) if @devs;
	return \@devs;
}

sub _currentDevices {
	my $devs = _devices();
	$devs = _seedFromPlayers() unless @$devs;
	return $devs;
}

# ---------- scan ----------

sub _runScan {
	require Plugins::AirPlay2Bridge::BridgeProcess;
	my $py  = Plugins::AirPlay2Bridge::BridgeProcess::pythonPath();
	my $bin = Plugins::AirPlay2Bridge::BridgeProcess::bridgeBin();
	return ('', "python or bridge.py not found ($py / $bin)") unless $py && $bin && -e $bin;

	my $qpy  = $py;  $qpy  =~ s/'/'\\''/g;
	my $qbin = $bin; $qbin =~ s/'/'\\''/g;
	my $cmd = "timeout 20 '$qpy' '$qbin' --scan 2>/dev/null";
	$log->info("discovery scan: $cmd");
	my $out = `$cmd`;
	my $rc = $? >> 8;
	return ('', "scan failed (rc=$rc)") if $rc != 0 && !$out;
	return ($out, '');
}

# влить результаты скана: ip/name/model обновить, mac/enabled сохранить,
# новые добавить выключенными, отсутствующие пометить absent (в преф не пишется)
sub _mergeScan {
	my ($scanout) = @_;
	my $devs = _currentDevices();
	my %byid = map { $_->{id} => $_ } @$devs;
	my %seen;

	for my $line (split /[\r\n]+/, $scanout) {
		next unless $line =~ /\S/;
		my ($id, $name, $ip, $model, $ov) = split /\t/, $line, -1;
		next unless ($id || $ip) && ($ip // '') ne '';
		$id = $ip unless $id && $id ne '';
		$seen{$id} = 1;
		if (my $d = $byid{$id}) {
			$d->{ip}    = $ip;
			$d->{name}  = $name if defined $name && $name ne '';
			$d->{model} = $model // '';
			$d->{ov}    = $ov // '';
		}
		else {
			push @$devs, { id => $id, name => ($name || $id), ip => $ip, mac => _deriveMac($id),
				enabled => 0, model => $model // '', ov => $ov // '', absent => 0, warn => 0 };
			$log->info("scan: new device $name ($id) at $ip");
		}
	}
	for my $d (@$devs) { $d->{absent} = $seen{$d->{id}} ? 0 : 1; }
	$prefs->set('devices', _devicesToStr($devs));
	return $devs;
}
sub handler {
	my ($class, $client, $paramRef, $callback, @args) = @_;

	# ВАЖНО: footer формы всегда шлёт hidden saveSettings=1, поэтому Scan-клик
	# (submit scanSettings) обрабатываем ПЕРВЫМ и не выполняем сохранение
	if ($paramRef->{'scanSettings'}) {
		my ($out, $err) = _runScan();
		if ($err) {
			$paramRef->{'scanerror'} = $err;
			$log->error("discovery scan: $err");
		}
		else {
			_mergeScan($out);
			$paramRef->{'scanned'} = 1;
		}
	}
	elsif ($paramRef->{'saveSettings'}) {
		my $old = _currentDevices();
		my %oldby = map { $_->{id} => $_ } @$old;

		my @devs;
		for my $k (sort keys %$paramRef) {
			next unless $k =~ /^dev_name_(.+)$/;
			my $id = $1;
			my $name = $paramRef->{$k} // '';
			$name =~ s/^\s+|\s+$//g;
			$name =~ s/,/ /g;  # запятая ломает формат players
			my $o = $oldby{$id};
			my $ip  = $paramRef->{"dev_ip_$id"}  || ($o ? $o->{ip}  : '');
			my $mac = $paramRef->{"dev_mac_$id"} || ($o ? $o->{mac} : _deriveMac($id));
			next unless $ip && $mac;
			$name = $o->{name} if $name eq '' && $o;
			push @devs, {
				id => $id, name => $name, ip => $ip, mac => $mac,
				enabled => $paramRef->{"dev_enable_$id"} ? 1 : 0,
				model => $o ? $o->{model} : '', ov => $o ? $o->{ov} : '',
				absent => 0, warn => 0,
			};
		}
		@devs = sort { lc($a->{name}) cmp lc($b->{name}) } @devs;
		$prefs->set('devices', _devicesToStr(\@devs));

		# players для BridgeProcess: только включённые
		my @lines = map { join ',', $_->{name}, $_->{mac}, $_->{id}, $_->{ip} }
			grep { $_->{enabled} } @devs;
		$prefs->set('players', join "\n", @lines);

		for my $key (qw(pythonpath bridgebin squeezelite lmsip)) {
			(my $v = $paramRef->{"pref_$key"} // '') =~ s/^\s+|\s+$//g;
			$prefs->set($key, $v);
		}
		$prefs->set('enabled', $paramRef->{'pref_enabled'} ? 1 : 0);

		require Plugins::AirPlay2Bridge::BridgeProcess;
		Plugins::AirPlay2Bridge::BridgeProcess->restartAll;
		$paramRef->{'validated'} = 1;
	}

	# данные для таблицы (+ предупреждение о совпадении имён с плеерами LMS)
	my $devs = _currentDevices();
	my %lmsnames = map { lc($_->name) => 1 } grep { ref $_ } Slim::Player::Client::clients();
	for my $d (@$devs) {
		$d->{warn} = 1 if $d->{enabled} && $lmsnames{lc($d->{name})};
	}
	$paramRef->{'devices'} = $devs;
	$paramRef->{'devcount'} = scalar @$devs;

	for my $key (qw(enabled pythonpath bridgebin squeezelite lmsip)) {
		$paramRef->{"pref_$key"} = $prefs->get($key);
	}

	return $class->SUPER::handler($client, $paramRef, $callback, @args);
}

1;
