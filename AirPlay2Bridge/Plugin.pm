package Plugins::AirPlay2Bridge::Plugin;

# AirPlay 2 Bridge — LMS plugin wrapper (HomePodOS 27+ workaround for LMS-Raop #57).
# Управляет python-мостами (bridge.py + pyatv): squeezelite(PCM stdout) -> AirPlay2 -> HomePod.
# Плагин запускает по одному процессу моста на каждый настроенный плеер,
# следит за ними (автоперезапуск) и останавливает при выключении LMS.

use strict;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $prefs = preferences('plugin.airplay2bridge');

$prefs->init({
	enabled       => 1,
	players       => "HomePod1,aa:aa:3d:81:fc:00,7E957DB99745,192.168.1.119\n"
	               . "HomePod2,aa:aa:f0:7c:54:95,1E2CDBBA4F30,192.168.1.121\n"
	               . "HomePod3,aa:aa:96:95:81:94,E2E2F50FBF09,192.168.1.123",
	pythonpath    => '/usr/bin/python3',
	bridgebin     => '',   # auto: <basedir>/Bin/bridge.py
	squeezelite   => '/usr/local/bin/squeezelite-ap2',
	lmsip         => '127.0.0.1',
});

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.airplay2bridge',
	'defaultLevel' => 'INFO',
	'description'  => 'PLUGIN_AIRPLAY2_BRIDGE',
});

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(@_);

	require Plugins::AirPlay2Bridge::BridgeProcess;

	if ( main::INFOLOG && $log->is_info ) {
		$log->info('AirPlay2Bridge plugin initialized');
	}

	if ($prefs->get('enabled')) {
		Plugins::AirPlay2Bridge::BridgeProcess->startAll;
	}

	if (!$::noweb) {
		require Plugins::AirPlay2Bridge::Settings;
		Plugins::AirPlay2Bridge::Settings->new;
	}
}

sub shutdownPlugin {
	Plugins::AirPlay2Bridge::BridgeProcess->stopAll;
}

1;