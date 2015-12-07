#!/usr/bin/perl

# (c) Jonas 2003+2004+2005 .)
# multithreaded 100% perl prebot with fxp/pre/dupe/search features ...

# ------------------------------------------------------------------
# dont change anything below
# ------------------------------------------------------------------

use strict qw (vars subs) ;
use warnings;

use prebot_config qw($debug $ftp_timeout $ftp_timeout_high $ftp_debug $ftp_use_statlist @complet_tags $enable_trading 
	@trading_rules $nfo_date_line $nfo_name @allowed_commands $irc_debug $irc_Nick $irc_Server 
	$irc_Ircname $irc_Port $irc_Username $irc_Password $irc_SSL $irc_channel $irc_passwd @hidden_files 
	@dupecheck_rels @dupecheck_tracks @dupecheck_tracksearch $ftp_use_progress
	$help_per_msg $use_blow $blowkey $max_sim_commands $irc_msg_delay $use_register_line $register_line $first_run
	$max_spreading_threads $local_address);

my $bot_version='HateBot v0.98-28 SQLite - modified by Advis0r';
my $pid_file = 'prebot.PID';
my $index_ext = 'lst';
my $db_file = 'prebot.db';

my $sql_debug = 0;

use threads ();
use threads::shared qw(cond_signal cond_wait cond_broadcast);
use Thread::Queue ();
use Net::FTP ();
use Net::IRC ();
use IO::Socket ();
use Time::Unix ();
use Time::HiRes qw(gettimeofday);
use Crypt::ircBlowfish ();
use DBI();

my $CODE_ERROR = "000";
my $CODE_FXP_OK = 226;
my $CODE_CMD_OK = 250;
my $CODE_FILE_EXISTS = 553;
my $CODE_FILE_EXISTS2 = 550;
my $CODE_CANNOT_CREATE = 552;
my $CODE_OUT_OF_SPACE = 452;
my $CODE_CANNOT_READ = 522;
my $CODE_CONNECTION_CLOSED = 599;

my $create_table =
"CREATE TABLE sites ( ".
"  site varchar(6) NOT NULL default '', ".
"  sitename varchar(255) NOT NULL default '', ".
"  STATUS varchar(255) NOT NULL default '', ".
"  bnc varchar(255) NOT NULL default '', ".
"  presite int(11) NOT NULL default '0', ".
"  archive int(11) NOT NULL default '0', ".
"  dump int(11) NOT NULL default '0', ".
"  dump_path varchar(255) NOT NULL default '', ".
"  today_dir varchar(255) NOT NULL default '', ".
"  sorted_mp3 varchar(255) NOT NULL default '', ".
"  additional_searchdirs text NOT NULL, ".
"  prepath varchar(255) NOT NULL default '', ".
"  precommand varchar(255) NOT NULL default '', ".
"  ssl_status varchar(255) NOT NULL default '', ".
"  login varchar(11) NOT NULL default '', ".
"  passwd varchar(11) NOT NULL default '', ".
"  source_sites varchar(255) NOT NULL default '', ".
"  logins int(11) NOT NULL default '0', ".
"  speed_index int(11) NOT NULL default '0', ".
"  fxp_speeds_from text NOT NULL, ".
"  fxp_speeds_to text NOT NULL, ".
"  affils varchar(255) NOT NULL default '', ".
"  location varchar(255) NOT NULL default '', ".
"  speed varchar(255) NOT NULL default '', ".
"  siteops varchar(255) NOT NULL default ''".
");";

# db fields, for validation
my @db_fields = ('sitename','status','bnc','presite','dump','dump_path','sorted_mp3','additional_searchdirs','today_dir','prepath','precommand','ssl_status','login','passwd','source_sites','logins','speed_index','archive','affils','location','speed','siteops');
my @db_binary_fields = ('presite', 'dump', 'archive');
my @db_ssl_values = ('nope', 'auth', 'full');


# blowfish object
my $blowfish = new Crypt::ircBlowfish;
$blowfish->set_key($blowkey);

# irc init
my $irc=new Net::IRC;
$irc->debug($irc_debug);
my $irc_conn;

# init for giving op
#$opme = main::IRC;

# global trigger for pre
my $syncvar : shared;

# global syncvar for command-pool
my $pool_syncvar : shared;

# global pool for commands to get executed
my @pool : shared;

# output-queue for irc msgs
my $irc_msgs = Thread::Queue->new();

# global helper vars for pre/spread - dont change !
my %free				:	shared;
my %sourcehash			:	shared;
my %desthash			:	shared;
my %downhash			:	shared;
my %busy				:	shared;
my %preferedsource		:	shared;
my $doingspread			:	shared = 0;
my $releasesize			:	shared = -1;
my $gotopre				:	shared = 0;
my $readypre			:	shared = 0;
my $first_rel			:	shared ='';
my %gimme_counter_total :	shared;
my %gimme_counter_done  :	shared;
my %timer_field			:	shared;
my $last_speed			:	shared = 0;
my %archive_scan_hash	:	shared;
my $reset_scan			:	shared;


# global, holds all running fxp processes
my %current_fxps :		shared;

# ------------------------------------------------------------------

debug_msg($bot_version.' loaded.');
debug_msg('performing startup / configuration test');
test_config();
init_command_pool();
init_irc();

# ------------------------------------------------------------------

# worker thread
sub worker {
	my $index = shift;

	debug_msg(sprintf('thread %s: created', $index));

	while(1) {
		my $job = undef;
		if(1) {
			# lock the syncvar - and wait until its free
			lock($pool_syncvar);
			cond_wait($pool_syncvar);

			# lock the queue pool
			lock(@pool);
			$job = shift @pool;
		}

		if(defined($job)) {
			if(scalar(@$job)>0) {
				my $code = shift @$job;
				debug_msg(sprintf('thread %s: got job: %s', $index, $code));
				my $key1 = start_timer('worker_thread_'.$index);
				eval ( \&$code(@$job) );
				debug_msg(sprintf('thread %s: finished job: %s (%s secs)', $index, $code, stop_timer($key1, 1)));
			}
		}
	}
}

# ------------------------------------------------------------------

# enqueues a new job to get executed
sub enqueue_job {
	my ($code, @args) = @_;

	if (!ref($code) && $code !~ /::/ && $code !~ /'/) {
		$code = caller() . "::$code";
	}

	if(1) {
		# lock the queue pool
		lock(@pool);
		my @pool_item : shared = ($code, @args);
		push(@pool, \@pool_item);

		# lock the syncvar
		lock($pool_syncvar);
		cond_signal($pool_syncvar);
	}
}

# ------------------------------------------------------------------

# simply forces execution of tasks stored in the pool
sub command_pusher {
	while (1) {
		sleep(5);
		if(1) {
			lock($pool_syncvar);
			cond_signal($pool_syncvar);
		}
	}
}

# ------------------------------------------------------------------

# creates the command thread pool
sub init_command_pool {
	debug_msg('initializing command-thread-pool');

	if(!($max_sim_commands > 0)) {
		debug_msg('thread initialization failed, define at least one worker thread (max_sim_commands)');
		exit();
	}

	for (my $i=0;$i<$max_sim_commands;$i++) {
		threads->create(\&worker, $i)->detach();
	}

	# let the threads get created before we really start
	sleep(2);

	# pushes tasks stored in pool to get executed
	threads->create(\&command_pusher)->detach();
}

# ------------------------------------------------------------------

# creates a new irc connection
sub init_irc {
	debug_msg('start irc client');

	$irc_conn=$irc->newconn(
		Nick=>$irc_Nick,
		Server=>$irc_Server,
		Ircname=>$irc_Ircname,
		Port=>$irc_Port,
		Username=>$irc_Username,
		Password=>$irc_Password,
		SSL=>$irc_SSL);

	$irc_conn->{channel}=$irc_channel;

	$irc_conn->add_handler('public', \&on_public);
	$irc_conn->add_handler('376', \&on_connect);
	$irc_conn->add_handler('422', \&on_connect);
	$irc_conn->add_handler('join', \&on_join);
	$irc_conn->add_handler('part', \&on_part);
	$irc_conn->add_handler('kick', \&on_kick);

	$irc_conn->add_global_handler([ 251,252,253,254,302,255 ], \&on_init);
	$irc_conn->add_global_handler(433, \&on_nick_taken);
	$irc_conn->add_global_handler('disconnect', \&on_disconnect);

	# main irc-loop
	while (1) {
		$irc->do_one_loop();
		while ($irc_msgs->pending)
		{
			if($irc_msg_delay>0) {
				sleep($irc_msg_delay);
			}

			my $ref = $irc_msgs->dequeue;
			my @args = @$ref;
			if(exists($args[2])) {
				_chan_msg($irc_conn, $args[0], $args[1], $args[2]);
			}
			else {
				_chan_msg($irc_conn, $args[0], $args[1]);
			}
		}
	}
}

# ------------------------------------------------------------------

sub debug_msg {
	my $msg=shift;
	if($debug eq 1) {
		printf("%s\n",$msg);
	}
}

# ------------------------------------------------------------------

# enqueue a msg for irc
sub irc_msg {
	my $queue = shift;
	my @task : shared = @_;
	$queue->enqueue(\@task);
}

# ------------------------------------------------------------------

# internal sub that gets output to irc - should never get called directly
sub _chan_msg {
	my $use_irc_conn = shift;
	my $msg = shift;
	my $nick = shift || '';

	if($use_blow eq 1 && $blowkey eq '') {
		$msg = 'Blowfish encryption enabled but no key set, check config-file';
	}

	# lets use blowfish
	if($use_blow eq 1 && $blowfish ne '' ) {
		$msg = '+OK ' . $blowfish->encrypt($msg);
	}

	if($nick ne '') {
		$use_irc_conn->privmsg($nick,$msg);
	}
	else {
		$use_irc_conn->privmsg($use_irc_conn->{channel},$msg);
	}
	return 1;
}

# ------------------------------------------------------------------

sub start_timer {
	my $key = shift || '';
	lock(%timer_field);
	my ($s1,$s2) = gettimeofday();
	$timer_field{$key.'|'.$s1.'|'.$s2.'S'}=$s1;
	$timer_field{$key.'|'.$s1.'|'.$s2.'MS'}=$s2;
	return $key.'|'.$s1.'|'.$s2;
}

# ------------------------------------------------------------------

sub stop_timer {
	my $key = shift;
	my $shorten = shift || 0;
	lock(%timer_field);
	my ($ns,$nms) = gettimeofday();
	my $s = $timer_field{$key.'S'};
	my $ms = $timer_field{$key.'MS'};

	delete($timer_field{$key.'S'});
	delete($timer_field{$key.'MS'});

	my $time_total = ($ns.'.'.$nms) - ($s.'.'.$ms);
	if($time_total < 0) {
		$time_total = '0.01';
	}

	if($shorten eq 1) {
		return sprintf('%.2f', $time_total);
	}
	return $time_total;
}

# ------------------------------------------------------------------

# dirlist using stats -la
sub dirlist {
	my $ftp = shift;
	my @dir=();
	my $failed = 0;

	if($ftp_use_statlist eq 1) {
		my $result = $ftp->quot('STAT -la');
		if($result == 5 || $result eq '') {
			debug_msg(sprintf('STAT -la failed - trying regular dirlist'));
			$failed=1;
		}
		else {
			@dir=$ftp->message();
			my @out=();
			for my $line (@dir) {
				if($line=~/^(.*)\n$/i) {
					$line=$1;
				}
				push(@out, $line);
			}
		}
	}

	# regular dirlist
	if($ftp_use_statlist eq 0 || $failed eq 1) {
		my $newerr=0;
		@dir=$ftp->dir or $newerr=1;
		if($newerr eq 1) {
			return;
		}
	}

	return @dir;
}

# ------------------------------------------------------------------

# format a byte-line
sub format_bytes_line {
	my $bytes = shift;
	my $size='Bytes';

	if($bytes>1024) {
		$bytes=$bytes / 1024;
		$size='KB';
	}
	if($bytes>1024) {
		$bytes=$bytes / 1024;
		$size='MB';
	}
	if($bytes>1024) {
		$bytes=$bytes / 1024;
		$size='GB';
	}

	return (sprintf('%.2f',$bytes),$size);
}

# ------------------------------------------------------------------

# trim .)
sub trim {
	my $in=shift;
	if($in=~/^[ ]*([^ ]+)[ ]*$/i) {
		$in=$1;
	}
	return $in;
}

# ------------------------------------------------------------------

# simple exists_in_array
sub exists_in_arr {
	my $key = shift;
	my @arr = @_;

	for my $index (@arr) {
		if($index eq $key) {
			return 1;
		}
	}
	return 0;
}

# ------------------------------------------------------------------

sub on_init {
	my ($self, $event) = @_;
	my (@args) = ($event->args);
	shift (@args);
	debug_msg('IRC Init');
}

# ------------------------------------------------------------------

sub on_nick_taken {
	my ($self) = shift;
	$self->nick(substr($self->nick, -1) . substr($self->nick, 0, 8));
}

# ------------------------------------------------------------------

sub on_kick {
	my ($use_irc_conn, $event) = @_;
	$use_irc_conn->join($use_irc_conn->{channel},$irc_passwd);
}

# ------------------------------------------------------------------

sub on_connect {
	my $use_irc_conn = shift;
	debug_msg('IRC Connect');
	$use_irc_conn->join($use_irc_conn->{channel},$irc_passwd);
	$use_irc_conn->{connected}=1;
	debug_msg(sprintf('IRC Joined %s',$use_irc_conn->{channel}));
}

# ------------------------------------------------------------------

sub on_disconnect {
	my ($self, $event) = @_;
	debug_msg('IRC Disconnect');

	sleep(10);
	init_irc();
}

# ------------------------------------------------------------------

sub on_join {
	my ($use_irc_conn, $event) = @_;
	my $nick = $event->{nick};
	my @selfchan = $event->to;
}

# ------------------------------------------------------------------

sub on_part {
	my ($use_irc_conn, $event) = @_;
	my $nick = $event->{nick};
}

# ------------------------------------------------------------------

sub on_public {
	my ($irc_conn, $event) = @_;
	my @to = $event->to;
	my $nick=$event->nick;
	my ($arg) = ($event->args);

	my $pid=0;
	my $use_irc_conn = 1;

	my $text = $event->{args}[0];

	# lets use blowfish
	if($use_blow eq 1 && $blowfish ne '' ) {
		my @tmp = split(' ', $text);
		if($tmp[0] eq '+OK') {
			$text = $blowfish->decrypt($tmp[1]);
			# remove  \0 whitespace at the end
			$text =~ /^([^\0]+)[\0]*$/i;
			$text = $1;
		}
		else {
			debug_msg('ignoring not encrypted msgs');
			return;
		}
	}

	my @parse = split(' ',$text);
	my $dest = ($help_per_msg eq 1) ? $nick : '';

	# give OP
	if(lc($parse[0]) eq '!giveop') {
		my $who = uc($parse[1]);
		unless ($who =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !giveop username');
				return;
		}
		if($who eq 'HELP') {
			irc_msg($irc_msgs, '!giveop username: gives op to a user', $dest);
			return;
		} else {		
			$irc_conn->mode($irc_channel, '+o', $who);
			return;
		}
	}

	# archive functions
	if(lc($parse[0]) eq '!archive') {
		my $cmd = uc($parse[1]);
		if($cmd eq 'HELP') {
			irc_msg($irc_msgs, 'Archive functions (try "!pre help" for fxp/sites help, "!sites help" for site administration):', $dest);
			irc_msg($irc_msgs, '!archive status: shows up/down-status of all sites', $dest);
			irc_msg($irc_msgs, '!archive scan site startdir: scans the archive, creates new index file', $dest);
			irc_msg($irc_msgs, '!archive search keyword1 keyword2 .. keywordx: searches index-files for releases matching the keywords, u can get the rels with the !pre gimme command', $dest);
			irc_msg($irc_msgs, '!archive stopscan: stops a currently running scan', $dest);
			irc_msg($irc_msgs, '[HELP] Done.', $dest);
			return;
		}
		if($cmd eq 'STATUS') {
			enqueue_job('show_sites', $use_irc_conn);
			return;
		}
		if($cmd eq 'SCAN') {
			my $site = uc($parse[2]);
			my $start = $parse[3] || '';
			unless ($site =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !archive scan site startdir - if no startdir is give, / is used');
				return;
			}
			$reset_scan = 0;
			enqueue_job('scan_site',$site,$start,$use_irc_conn);
			return;
		}
		if($cmd eq 'STOPSCAN') {
			$reset_scan = 1;
			irc_msg($irc_msgs, '[SCAN] trying to stop a running scan ... ');
			return;
		}
		if($cmd eq 'SEARCH') {
			my @params;
			for(my $index=2;$index < scalar(@parse); $index++) {
				push(@params, $parse[$index]);
			}
			unless(join('', @params) =~ /\w/) {
				irc_msg($irc_msgs, 'no keywords given');
				return;
			}
			enqueue_job('search_archive', 0, '', $use_irc_conn, @params);
			return;
		}
	}

	# site administration
	if(lc($parse[0]) eq '!sites') {
		my $cmd = uc($parse[1]);
		if($cmd eq 'HELP') {
			irc_msg($irc_msgs, 'Sites Administration (try "!pre help" for fxp/sites help, "!archive help" for archive functions):', $dest);
			irc_msg($irc_msgs, '!sites status: shows up/down-status of all sites', $dest);
			irc_msg($irc_msgs, '!sites show SITE: shows added details for SITE', $dest);
			irc_msg($irc_msgs, '!sites add SITE: adds new (empty) record for a new site - fill data with !sites set SITE parameter values', $dest);
			irc_msg($irc_msgs, '!sites del SITE: deletes the site from the database', $dest);
			irc_msg($irc_msgs, '!sites set SITE param values: sets the detailed information for the site record:', $dest);
			irc_msg($irc_msgs, ' - sitename STRING: real sitename', $dest);
			irc_msg($irc_msgs, ' - location STRING: Site\'s location', $dest);
			irc_msg($irc_msgs, ' - speed STRING: Site\'s speed', $dest);
			irc_msg($irc_msgs, ' - siteops STRING: Siteop Nicks', $dest);
			irc_msg($irc_msgs, ' - affils STRING: Seperate Affils with \',\'', $dest);
			irc_msg($irc_msgs, ' - status STRING: up/down-status of the site', $dest);
			irc_msg($irc_msgs, ' - bnc STRING: ip:port,ip:port,ip:port - sets all bncs', $dest);
			irc_msg($irc_msgs, ' - presite INT: 0/1 - site is presite (or not)', $dest);
			irc_msg($irc_msgs, ' - archive INT: 0/1 - site is archive (or not)', $dest);
			irc_msg($irc_msgs, ' - dump INT: 0/1 - site is dumpsite (or not)', $dest);
			irc_msg($irc_msgs, ' - dump_path STRING: full path to the sites incoming/request dir', $dest);
			irc_msg($irc_msgs, ' - sorted_mp3 STRING: full path to the sites mp3-sorted-by-artist dir (koma-sep list)', $dest);
			irc_msg($irc_msgs, ' - additional_searchdirs STRING: list of directories, used by release-search,  (koma-sep list)', $dest);
			irc_msg($irc_msgs, ' - today_dir STRING: full path to the sites mp3-today dir', $dest);
			irc_msg($irc_msgs, ' - prepath STRING: full path to the groups pre-dir', $dest);
			irc_msg($irc_msgs, ' - precommand STRING: command to pre there - like "pre RELEASENAME mp3"', $dest);
			irc_msg($irc_msgs, ' - ssl_status STRING: sets if ssl is needed or not -> nope, auth, full', $dest);
			irc_msg($irc_msgs, ' - login STRING: prebots login', $dest);
			irc_msg($irc_msgs, ' - passwd STRING: prebots passwd', $dest);
			irc_msg($irc_msgs, ' - source_sites STRING: sites to use as source for spreading/gimme (sorted koma-sep list like "SITE1,SITE2...")', $dest);
			irc_msg($irc_msgs, ' - logins INT: max logins (with allowed download) - usually 2', $dest);
			irc_msg($irc_msgs, ' - speed_index INT: 1-255, the higher the more important for the global spread or gimme process', $dest);
			irc_msg($irc_msgs, '!sites affilsearch GROUP: Lists the sites of a certain group', $dest);
			irc_msg($irc_msgs, '!sites locations: Shows the locations of all sites', $dest);
			irc_msg($irc_msgs, '[HELP] Done.', $dest);
			return;
		}
		if($cmd eq 'STATUS') {
			enqueue_job('show_sites',$use_irc_conn);
			return;
		}
		if($cmd eq 'AFFILSEARCH') {
			my $group = uc($parse[2]);
			unless ($group =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !sites affilsearch group');
				return;
			}
			enqueue_job('search_affils',$group,$use_irc_conn);
			return;
		}
		if($cmd eq 'LOCATIONS') {
			enqueue_job('show_locations',$use_irc_conn);
			return;
		}
		if($cmd eq 'SHOW') {
			my $site = uc($parse[2]);
			unless ($site =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !sites show site');
				return;
			}
			enqueue_job('show_site',$site,$use_irc_conn);
			return;
		}
		if($cmd eq 'ADD') {
			my $site = uc($parse[2]);
			unless ($site =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !sites add site');
				return;
			}
			enqueue_job('add_site',$site,$use_irc_conn);
			return;
		}
		if($cmd eq 'DEL') {
			my $site = uc($parse[2]);
			unless ($site =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !sites del site');
				return;
			}
			enqueue_job('del_site',$site,$use_irc_conn);
			return;
		}
		if($cmd eq 'SET') {
			my $site = uc($parse[2]);
			my $param = lc($parse[3]);
			my @val;
			for(my $index = 4; $index<scalar(@parse);$index++) {
				push(@val, $parse[$index]);
			}
			unless ($site =~ /\w/ && $param =~ /\w/ && join('',@val) =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !sites set site parameter value');
				return;
			}
			enqueue_job('set_site',$site,$use_irc_conn,$param,@val);
			return;
		}
	}


	# site functions
	if(lc($parse[0]) eq '!pre')
	{
		my $cmd = uc($parse[1]);
		if($cmd eq 'HELP') {
			irc_msg($irc_msgs, 'FXP/Sites Functionality (try "!sites help" for administration help, "!archive help" for archive functions):', $dest);
			irc_msg($irc_msgs, '!pre test SITE: tests login and predir, tries all bnc\'s, if no sitename is given, it checks all sites', $dest);
			irc_msg($irc_msgs, '!pre status: shows up/down-status of all sites', $dest);
			irc_msg($irc_msgs, '!pre sysinfo - shows system information / overview');
			irc_msg($irc_msgs, '!pre show SITE: shows added details for SITE', $dest);
			irc_msg($irc_msgs, '!pre search SITENAME RELEASE: searches the release on SITE (or all sites if no sitename given), checks if its really there (max 10 results per site)', $dest);
			irc_msg($irc_msgs, '!pre check SITE RELEASE: checks if RELEASE is complete and ok on SITE', $dest);
			irc_msg($irc_msgs, '!pre checkall RELEASE: checks if RELEASE is complete and ok on all sites', $dest);
			irc_msg($irc_msgs, '!pre prelist SITE RELEASE: shows releases laying in predir on SITE (or all sites), or content of RELEASE in predir', $dest);
			irc_msg($irc_msgs, '!pre dirlist SITE DIRECTORY SEARCHPHRASE: shows files and folders matching searchphrase (if given)', $dest);
			irc_msg($irc_msgs, '!pre fxp SITE1 SITE2 RELEASE/FILE: fxp\'s a release/file from SITE1 to SITE2 (from predir to predir)', $dest);
			irc_msg($irc_msgs, '!pre chainfxp SITE1 SITE2 .. SITEx RELEASE: fxp\'s a release chained from SITE1 to SITE2, SITE2 to SITE3 and so on (from predir to predir, if no RELEASE given, it transfers complete predir)', $dest);
			irc_msg($irc_msgs, '!pre spreadfxp SITE1 SITE2 .. SITEx RELEASE: fxp\'s a release from SITE1 to SITE2, SITE1 to SITE3 and so on (from predir to predir, if no RELEASE given, it transfers complete predir)', $dest);
			irc_msg($irc_msgs, '!pre spread RELEASE: spreads the release automatically to all sites to prepare a pre', $dest);
			irc_msg($irc_msgs, '!pre speeds SITE: shows avg speeds from/to other sites (gets updated with every fxp process) - or total amound of traffic if no sitename is given', $dest);
			irc_msg($irc_msgs, '!pre reset: stops spread and resets the bot', $dest);
			irc_msg($irc_msgs, '!pre kill SITE: kills an existing connection to SITE', $dest);
			irc_msg($irc_msgs, '!pre pre RELEASE: finally pre\'s the release on all sites that are up', $dest);
			irc_msg($irc_msgs, '!pre del SITE RELEASE/FILE: tries to delete the RELEASE on SITE', $dest);
			irc_msg($irc_msgs, '!pre delall RELEASE: tries to delete the RELEASE on all sites', $dest);
			irc_msg($irc_msgs, '!pre delnfo SITE RELEASE: tries to delete the RELEASE on SITE', $dest);
			irc_msg($irc_msgs, '!pre updnfo SITE RELEASE: tries update nfo for RELEASE on all sites (updates release-date in nfo + takes nfo from source SITE if given)', $dest);
			irc_msg($irc_msgs, '!pre delallnfo RELEASE: tries to delete the RELEASE on all sites', $dest);
			irc_msg($irc_msgs, '!pre showstats SITE: tries to show the bot\'s stats on SITE, if no sitename is given, it checks all sites', $dest);
			irc_msg($irc_msgs, '!pre gimme SOURCE DESTINATION RELEASE: searches for RELEASE on SOURCE or all added sites and delivers to SITE (use !pre gimmeHELP first)', $dest);
			irc_msg($irc_msgs, '!pre gimmeHELP: shows available source-sites and destination-sites for GIMME', $dest);
			irc_msg($irc_msgs, '!pre dupe keyword1 keyword2 ... keyword5 : makes a dupecheck (scsi)', $dest);
			irc_msg($irc_msgs, '!pre tracks RELEASE : lists all tracks in RELEASE (scsi)', $dest);
			irc_msg($irc_msgs, '!pre tracksearch TRACK : lists all releases containing TRACK (scsi)', $dest);
			irc_msg($irc_msgs, '!pre ginfo SITE: checks creds (ginfo+user) for all added users in your group on SITE', $dest);
			irc_msg($irc_msgs, '!pre cmd SITE command param1 param2.. : sends raw command to site', $dest);
			irc_msg($irc_msgs, '!pre fxps: shows all currently running fxp processes (spread, gimme, fxp and so on)', $dest);
			irc_msg($irc_msgs, '!pre speedtest SITE FILE: takes a FILE from SITE and fxps to all presites to test speeds (removes after fxp))', $dest);

			irc_msg($irc_msgs, '!pre forcespread RELEASE: spreads a dirfix or nfofix automatically to all sites to prepare a forcepre', $dest);
			irc_msg($irc_msgs, '!pre forcepre RELEASE: finally pre\'s the dirfix or nfofix on all sites that are up', $dest);

			if($enable_trading eq 1) {
				irc_msg($irc_msgs, '!pre trade RELEASE GENRE: tries to trade RELEASE from current daydir to all sites that match the rulesets', $dest);
			}
			irc_msg($irc_msgs, '[HELP] Done.', $dest);
			return;
		}
		if($cmd eq 'SHOWSTATS') {
			my $site = uc($parse[2]);
			unless ($site =~ /\w/) {
				enqueue_job('show_stats_all',$use_irc_conn);
				return;
			}
			enqueue_job('show_stats',$site, $use_irc_conn, 0);
			return;
		}
		if($cmd eq 'TEST') {
			my $site = uc($parse[2]);
			unless ($site =~ /\w/) {
				enqueue_job('check_all_sites',$use_irc_conn);
				return;
			}
			enqueue_job('get_site_data',$site, 1, $use_irc_conn,0,1);
			return;
		}
		if($cmd eq 'STATUS') {
			enqueue_job('show_sites',$use_irc_conn);
			return;
		}
		if($cmd eq 'SYSINFO') {
			enqueue_job('show_sysinfo',$use_irc_conn);
			return;
		}
		if($cmd eq 'CHECK') {
			my $site = uc($parse[2]);
			my $rel = $parse[3];
			unless ($site =~ /\w/ && $rel =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre check site release');
				return;
			}
			enqueue_job('check_release',$site, $rel, $use_irc_conn,0);
			return;
		}
		if($cmd eq 'SPEEDTEST') {
			my $site = uc($parse[2]);
			my $rel = $parse[3];
			unless ($site =~ /\w/ && $rel =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre speedtest site file');
				return;
			}
			enqueue_job('speedtest',$site, $rel, $use_irc_conn);
			return;
		}
		if($cmd eq 'CHECKALL') {
			my $rel = $parse[2];
			unless ($rel =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre checkall release');
				return;
			}
			if($doingspread ne 0){
				irc_msg($irc_msgs, 'there is already a spreading-process running');
				return;
			}
			else {
				$doingspread = 1;
			}
			enqueue_job('spread_release',$rel,$use_irc_conn,0);
			return;
		}
		if($cmd eq 'SHOW') {
			my $site = uc($parse[2]);
			unless ($site =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre show site');
				return;
			}
			enqueue_job('show_site',$site,$use_irc_conn);
			return;
		}
		if($cmd eq 'DEL') {
			my $site = uc($parse[2]);
			my $rel = $parse[3];
			unless ($rel =~ /\w/ && $site =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre del site release/file');
				return;
			}
			enqueue_job('delete_release',$site,$rel,$use_irc_conn,0);
			return;
		}
		if($cmd eq 'DELALL') {
			my $rel = $parse[2];
			unless ($rel =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre delall release');
				return;
			}
			enqueue_job('delete_all_release',$rel,$use_irc_conn);
			return;
		}
		if($cmd eq 'UPDNFO') {
			my $site = uc($parse[2]);
			my $rel = $parse[3];
			unless ($site =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre updnfo site release - or - !pre updnfo release');
				return;
			}
			if($site ne '' && $rel ne '') {
				$site = uc($site);
				enqueue_job('updnfo',$rel,$site,$use_irc_conn);
			}
			else {
				enqueue_job('updnfo',$site,'',$use_irc_conn);
			}
			return;
		}
		if($cmd eq 'DELNFO') {
			my $site = uc($parse[2]);
			my $rel = $parse[3];
			unless ($rel =~ /\w/ && $site =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre delnfo site release');
				return;
			}
			enqueue_job('delete_nfo',$site,$rel,$use_irc_conn,0);
			return;
		}
		if($cmd eq 'DELALLNFO') {
			my $rel = $parse[2];
			unless ($rel =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre delallnfo release');
				return;
			}
			enqueue_job('delete_all_nfo',$rel,$use_irc_conn);
			return;
		}
		if($cmd eq 'SPREAD') {
			my $rel = $parse[2];
			unless ($rel =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre spread release');
				return;
			}
			if ($doingspread ne 0){
				irc_msg($irc_msgs, 'there is already a spreading-process running');
				return;
			}
			else {
				$doingspread = 1;
			}
			enqueue_job('spread_release',$rel,$use_irc_conn,1);
			return;
		}
		if($cmd eq 'FORCESPREAD') {
			my $rel = $parse[2];
			unless ($rel =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre forcespread release');
				return;
			}
			if ($doingspread ne 0){
				irc_msg($irc_msgs, 'there is already a spreading-process running');
				return;
			}
			else {
				$doingspread = 1;
			}
			enqueue_job('force_spread_release',$rel,$use_irc_conn,1);
			return;
		}
		if($cmd eq 'RESET') {
			irc_msg($irc_msgs, '[RESET] trying reset global vars.....');
			$doingspread = 0;
			$readypre = -100;
			$reset_scan = 1;
			lock(%gimme_counter_total);
			for my $key (keys(%gimme_counter_total)) {
				delete($gimme_counter_total{$key});
			}
			lock(%gimme_counter_done);
			for my $key (keys(%gimme_counter_done)) {
				delete($gimme_counter_done{$key});
			}
			return;
		}
		if($cmd eq 'PRE') {
			my $rel = $parse[2];
			unless ($rel =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre pre release');
				return;
			}
			enqueue_job('pre_rel',$rel,$use_irc_conn);
			sleep(1);
			return;
		}
		if($cmd eq 'FORCEPRE') {
			my $rel = $parse[2];
			unless ($rel =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre forcepre release');
				return;
			}
			enqueue_job('force_pre_rel',$rel,$use_irc_conn);
			sleep(1);
			return;
		}
		if($cmd eq 'TRADE') {
			my $rel = $parse[2];
			my $genre1 = $parse[3];
			my $genre2 = $parse[4];
			unless ($rel =~ /\w/ && $genre1 =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre trade release genre');
				return;
			}
			enqueue_job('auto_trade',$rel,$genre1,$genre2,$use_irc_conn);
			return;
		}
		if($cmd eq 'FXP') {
			my $site1 = uc($parse[2]);
			my $site2 = uc($parse[3]);
			my $rel = $parse[4];
			unless ($site1 =~ /\w/ && $site1 =~ /\w/ && $rel =~ /\w/) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre fxp site1 site2 release/file');
				return;
			}
			enqueue_job('fxp_rel',$site1,$site2,$rel,$use_irc_conn,0,'','',0,0,0);
			return;
		}
		if($cmd eq 'CHAINFXP') {
			my $len = scalar(@parse);
			my @sites;
			if($len<4) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre chainfxp site1 site2 site3 .. sitex release/file (no release/file means complete predir)');
				return;
			}
			for(my $i=2;$i<$len-1;$i++) {
				push(@sites, $parse[$i]);
			}
			my $rel=$parse[$len-1];
			if(length($rel)<10) {
				push(@sites, $rel);
				enqueue_job('chain_fxp','chainfxp_predirs',$use_irc_conn,@sites);
			}
			else {
				enqueue_job('chain_fxp',$rel,$use_irc_conn,@sites);
			}
			return;
		}
		if($cmd eq 'SPREADFXP') {
			my $len = scalar(@parse);
			my @sites;
			if($len<4) {
				irc_msg($irc_msgs, 'wrong parameters, use !pre spreadfxp site1 site2 site3 .. sitex release/file (no release/file means complete predir)');
				return;
			}
			for(my $i=2;$i<$len-1;$i++) {
				push(@sites, $parse[$i]);
			}
			my $rel=$parse[$len-1];
			if(length($rel)<10) {
				push(@sites, $rel);
				enqueue_job('spread_fxp','chainfxp_predirs',$use_irc_conn,@sites);
			}
			else {
				enqueue_job('spread_fxp',$rel,$use_irc_conn,@sites);
			}
			return;
		}
		if($cmd eq 'PRELIST') {
			my $site = uc($parse[2]);
			my $rel = $parse[3];
			if($site eq '') {
				enqueue_job('show_predirs',$use_irc_conn);
			}
			else {
				enqueue_job('show_predir',$site, $use_irc_conn, $rel,'', 0);
			}
			return;
		}
		if($cmd eq 'DIRLIST') {
			my $site = uc($parse[2]);
			my $rel = '/'.$parse[3];
			my $search  = $parse[4];
			unless ($site =~ /\w/) {
				irc_msg($irc_msgs, 'no sitename given');
				return;
			}
			unless ($search =~ /\w/) {
				irc_msg($irc_msgs, sprintf('[%s] you should use search patterns, max output is 20 lines',$site));
				$search = '.';
			}
			enqueue_job('show_predir',$site, $use_irc_conn, $rel, $search, 0);
			return;
		}
		if($cmd eq 'SEARCH') {
			my $site = $parse[2];
			my $rel = $parse[3] || '';
			unless ($rel =~ /\w/) {
				$rel=$site;
				$site='';
			}
			unless ($rel =~ /\w/) {
				irc_msg($irc_msgs, 'no releasename given');
				return;
			}
			enqueue_job('search_rel',$rel, $site, $use_irc_conn, '', 0);
			return;
		}
		if($cmd eq 'KILL') {
			my $site = uc($parse[2]);
			unless ($site =~ /\w/) {
				irc_msg($irc_msgs, 'no sitename given');
				return;
			}
			enqueue_job('kill_connection',$site, $use_irc_conn);
			return;
		}
		if($cmd eq 'GIMME') {
			my $site = uc($parse[2]);
			my $rel = $parse[3];
			my $source_site = $parse[4] || '';
			unless ($site =~ /\w/ && $rel =~ /\w/) {
				irc_msg($irc_msgs, 'no sitename or releasename given');
				return;
			}
			if($source_site ne '') {
				$source_site = uc($parse[2]);
				$site = uc($parse[3]);
				$rel = $parse[4];
			}
			enqueue_job('gimme',$site, $rel, $source_site, $use_irc_conn);
			return;
		}
		if($cmd eq 'GIMMEHELP') {
			enqueue_job('gimmehelp', $use_irc_conn);
			return;
		}
		if($cmd eq 'CMD') {
			my $site = uc($parse[2]);
			my $cmd = $parse[3];
			my @params;
			for(my $index=4;$index < scalar(@parse); $index++) {
				push(@params, $parse[$index]);
			}
			unless($site =~ /\w/ && $cmd =~ /\w/) {
				irc_msg($irc_msgs, 'no sitename or command given');
				return;
			}
			enqueue_job('command',$site, $cmd, $use_irc_conn, @params);
			return;
		}
		if($cmd eq 'DUPE' || $cmd eq 'TRACKS' || $cmd eq 'TRACKSEARCH') {
			my @params;
			for(my $index=2;$index < scalar(@parse); $index++) {
				push(@params, $parse[$index]);
			}
			if($cmd eq 'DUPE') {
				enqueue_job('command', $dupecheck_rels[0],$dupecheck_rels[1], $use_irc_conn, @params);
				return;
			}
			if($cmd eq 'TRACKS') {
				enqueue_job('command',$dupecheck_tracks[0],$dupecheck_tracks[1], $use_irc_conn, @params);
				return;
			}
			if($cmd eq 'TRACKSEARCH') {
				enqueue_job('command',$dupecheck_tracksearch[0],$dupecheck_tracksearch[1],$use_irc_conn, @params);
				return;
			}
		}
		if($cmd eq 'GINFO') {
			my $site = uc($parse[2]);
			unless ($site =~ /\w/) {
				irc_msg($irc_msgs, 'no sitename given');
				return;
			}
			enqueue_job('ginfo',$site, $use_irc_conn);
			return;
		}
		if($cmd eq 'SPEEDS') {
			my $site = uc($parse[2]) || '';
			enqueue_job('show_speeds',$site, 0, $use_irc_conn);
			return;
		}
		if($cmd eq 'FXPS') {
			enqueue_job('show_fxps', $use_irc_conn);
			return;
		}
		irc_msg($irc_msgs, $nick.': unknown command '.$cmd.', try \'!pre help\'');
	}
}

# ------------------------------------------------------------------

# get msg from ftpd
sub get_message {
	my $ftp = shift;
	my $msg=join('',$ftp->message());
	$msg=~ s/\n//g;
	$msg=~ s/\r//g;
	if($msg eq '') {
		$msg='Code: '.$ftp->code();
	}
	if(length($msg)>255)
	{
		$msg=~/^(.{255}).*$/i;
		$msg=$1.' ...';
	}
	return $msg;
}

# ------------------------------------------------------------------

# connects to the sqlite db - returns handle
sub _connect_db {
	my $dbh = DBI->connect(sprintf("dbi:SQLite:dbname=%s", $db_file), '', '',{'RaiseError' => 1});
	if(!$dbh) {
		return 0;
	}
	return $dbh;
}

# ------------------------------------------------------------------

# connects to the sqlite db, executes query - returns handles
sub conquery_db {
	my $query = shift;
	my @out;

	my $key1 = start_timer('SQL_QUERY');

	my $dbh = _connect_db();
	if(!$dbh) {
		debug_msg('cannot connect to DB');
		return (0, 'cannot connect to DB', @out);
	}

	if($sql_debug eq 1) {
		debug_msg(sprintf('SQL: query: %s', $query));
	}

	my $sth = $dbh->prepare($query);
	if(!$sth) {
		$dbh->disconnect();
		return (0, '[SQL] Error: '.$dbh->errstr, @out);
	}
	if(!$sth->execute()) {
		$sth->finish();
		$dbh->disconnect();
		return (0, '[SQL] Error: '.$sth->errstr, @out);
	}

	while(my @row = $sth->fetchrow_array()) {
		push(@out, \@row);
	}
	$sth->finish();
	undef $sth;
	$dbh->disconnect();

	if($sql_debug eq 1) {
		debug_msg(sprintf('SQL: Done - secs (%s), %s rows', stop_timer($key1, 1), scalar(@out)));
	}

	return (1, '', @out);
}

# ------------------------------------------------------------------

# connects to the sqlite db, executes do-statement - returns errors
sub condo_db {
	my $query = shift;

	my $key1 = start_timer('SQL_QUERY');
	my $dbh = _connect_db();
	my $res = $dbh->do($query);
	if($sql_debug eq 1) {
		debug_msg(sprintf('SQL: %s secs (%s)', stop_timer($key1, 1), $query));
	}

	return $res;
}

# ------------------------------------------------------------------

# perform some tests on startup - if something fails - simply dont start the bot .)
# clears fxp_speeds_from/to table too (removes deleted sites)
sub test_config {

	# blowfish settings
	debug_msg('checking Blowfish-settings:');
	if(1) { # local scope
		if($use_blow eq 1) {
			if($blowkey eq '') {
				debug_msg('blowfish enabled but no key set, check configuration');
				exit();
			}
			debug_msg('... ok');
		}
		else {
			debug_msg('... disabled');
		}
	}

	# db connection
	debug_msg('testing DB-connection:');
	if(1) { # local scope
		my $dbh;
		if(!($dbh=_connect_db())) {
			debug_msg('cannot connect to db, check configuration');
			exit();
		}
		else {
			debug_msg('... DB-connection: ok');
		}

		# initialize database
		if($first_run eq 1) {
			debug_msg('creating new database:');
			if(!$dbh->do($create_table)) {
				debug_msg('cannot create the database: '..$dbh->errstr);
				$dbh->disconnect();
				exit();
			}
			debug_msg('... DB-creation: ok, now edit configfile, disable $first_run and restart the bot');
			$dbh->disconnect();
			exit();
		}

		# check db tables
		my $sth = $dbh->prepare("select * from sites");
		if(!$sth) {
			debug_msg('cannot query the database: '..$dbh->errstr);
			$dbh->disconnect();
			exit();
		}
		else {
			debug_msg('... sql prepare: ok');
		}
		if(!$sth->execute()) {
			debug_msg('cannot query the database: '..$dbh->errstr);
			$sth->finish();
			$dbh->disconnect();
			exit();
		}
		else {
			debug_msg('... sql execute: ok');
		}
	}

	# cleaning fxp_speeds_from/to table
	debug_msg('cleaning tmp-table (fxp_speeds_from/to)');
	if(1) { # local scope
		my ($res, $msg, @rows) = conquery_db("select upper(site), fxp_speeds_from, fxp_speeds_to from sites order by site");
		if(!$res) {
			debug_msg('... sql error: '.$msg);
		}
		elsif(!scalar(@rows)) {
			debug_msg('... nothing to do');
		}
		else {

			my %sites_hash;
			for my $out (@rows) {
				$sites_hash{@$out[0]}{'fxp_from'}=@$out[1];
				$sites_hash{@$out[0]}{'fxp_to'}=@$out[2];
			}

			debug_msg('... found '.scalar(keys(%sites_hash)).' sites');
			for my $site (keys(%sites_hash)) {
				my $fxp_from = $sites_hash{$site}{'fxp_from'};
				my $fxp_to = $sites_hash{$site}{'fxp_to'};

				my @new_arr_from = ();
				my @new_arr_to = ();

				my @sites_from_arr = split(/,/,$fxp_from);
				for my $row1 (@sites_from_arr) {
					if($row1=~/^([^ ]+):([0-9]+):([0-9\.]+)$/i) {
						my $tmp_site = $1;
						my $tmp_total = $2;
						my $tmp_speed = $3;
						if(exists($sites_hash{$tmp_site})) {
							push(@new_arr_from,$row1);
						}
						else {
							debug_msg('... removing unused site-data for: '.$tmp_site);
						}
					}
				}
				my $sites_from_string = join(',',@new_arr_from);
				condo_db(sprintf("update sites set fxp_speeds_from='%s' where upper(site)='%s'",$sites_from_string,$site));

				my @sites_to_arr = split(/,/,$fxp_to);
				for my $row2 (@sites_to_arr) {
					if($row2=~/^([^ ]+):([0-9]+):([0-9\.]+)$/i) {
						my $tmp_site = $1;
						my $tmp_total = $2;
						my $tmp_speed = $3;
						if(exists($sites_hash{$tmp_site})) {
							push(@new_arr_to,$row2);
						}
						else {
							debug_msg('... removing unused site-data for: '.$tmp_site);
						}
					}
				}
				my $sites_to_string = join(',',@new_arr_to);
				condo_db(sprintf("update sites set fxp_speeds_to='%s' where upper(site)='%s'",$sites_to_string,$site));
			}
			debug_msg('... cleaning done');
		}
	}

	# cleaning source_sites list - remove deleted sites
	debug_msg('cleaning source_sites list');
	if(1){ # local scope
		my ($res, $msg, @rows) = conquery_db("select upper(site), upper(source_sites) from sites order by site");
		if(!$res) {
			debug_msg('... sql error: '.$msg);
		}
		elsif(!scalar(@rows)) {
			debug_msg('... nothing to do');
		}
		else {
			my %sites_hash;
			for my $out (@rows) {
				$sites_hash{@$out[0]}{'source_sites'}=@$out[1];
			}
			debug_msg('... found '.scalar(keys(%sites_hash)).' sites');
			for my $site (keys(%sites_hash)) {
				my $source_sites = $sites_hash{$site}{'source_sites'};
				my @sites_arr = split(',', $source_sites);
				my @sites_new = ();
				for my $tmp_site (@sites_arr) {
					if(exists($sites_hash{$tmp_site})) {
						push(@sites_new, $tmp_site);
					}
					else {
						debug_msg('... removing unused site-data for: '.$tmp_site);
					}
				}
				my $sites_string = join(',',@sites_new);
				condo_db(sprintf("update sites set source_sites='%s' where upper(site)='%s'",$sites_string,$site));
			}
			debug_msg('... cleaning done');
		}
	}

	# all done - now simply write the PID file
	open(FH, "> $pid_file") || debug_msg('cannot create PID-file');
	close(FH);
	return 1;
}

# ------------------------------------------------------------------

# simply returns time-difference current_time - time of creation of the pid file
sub get_runtime() {
	my $write_secs = (stat($pid_file))[9];
	return scalar localtime($write_secs);
}

# ------------------------------------------------------------------

# show some system information / overview
sub show_sysinfo {
	my $use_irc_conn = shift;

	my $presites = 0;
	my $dumpsites = 0;
	my $sourcesites = 0;
	my $totalsites = 0;
	my $archivesites = 0;

	my ($res, $msg, @rows) = conquery_db("select count(*) as sites_total, sum(presite), sum(dump), sum(case when (presite=0 and dump=0) then 1 else 0 end), sum(archive) from sites");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(scalar(@rows)) {
		($totalsites, $presites, $dumpsites, $sourcesites, $archivesites) = @{$rows[0]};
	}

	my ($size, $bytes) = show_speeds('', 1, $use_irc_conn);
	my $uptime = get_runtime();

	my %arch_sites;
	($res, $msg, @rows) = conquery_db("select upper(site) from sites where archive=1 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(scalar(@rows)) {
		for my $out (@rows) {
			$arch_sites{@$out[0]}=0;
			my $filename = sprintf('%s.%s',uc(@$out[0]), $index_ext);
			my $error = 0;
			open(FILE, $filename) or $error=1;
			if($error eq 0) {
				my $lines = 0;
				my $buffer = '';
				while (sysread FILE, $buffer, 4096) {
					$lines += ($buffer =~ tr/\n//);
				}
				close FILE;
				$arch_sites{@$out[0]} = $lines;
			}
			else {
				debug_msg('error opening file: '.$filename);
			}
		}
	}
	my @tmp = ();
	for my $site (keys(%arch_sites)) {
		push(@tmp, sprintf('%s (%s)', $site, $arch_sites{$site}));
	}
	my $arch_sites_string = join(', ', @tmp);

	irc_msg($irc_msgs, sprintf('[SYSINFO] %s - last started: %s', $bot_version, $uptime));
	irc_msg($irc_msgs, sprintf('[SYSINFO] auto-trading: %s', $enable_trading eq 1 ? 'enabled':'disabled'));
	irc_msg($irc_msgs, sprintf('[SYSINFO] Sites: %s presites, %s dumpsites, %s source-sites, %s archives - %s total (ignoring up/down-state)', $presites, $dumpsites, $sourcesites, $archivesites, $totalsites));
	irc_msg($irc_msgs, sprintf('[SYSINFO] Archives (index-files): %s', $arch_sites_string));
	irc_msg($irc_msgs, sprintf('[SYSINFO] Total fxp traffic: %s %s',$size,$bytes));
	irc_msg($irc_msgs, sprintf('[SYSINFO] BlowFish: %s', $use_blow eq 1?'enabled':'disabled'));
	irc_msg($irc_msgs, sprintf('[SYSINFO] Threads in command-pool: %s', $max_sim_commands));

	return 1;
}


# ------------------------------------------------------------------

# disconnect from a site
sub disconnect {
	my $site1 = shift;
	my $sname1 = shift;
	my $site2 = shift;
	my $sname2 = shift;
	my $use_irc_conn  = shift;

	if(($site1 ne 0) && ($site2 ne 0)) {
		$site1->quit();
		$site2->quit();
		if($use_irc_conn ne 0) {
			irc_msg($irc_msgs,sprintf('[%s] && [%s] disconnected',$sname1,$sname2));
		}
		return 1;
	}
	if($site1 ne 0) {
		$site1->quit();
		if($use_irc_conn ne 0) {
			irc_msg($irc_msgs,sprintf('[%s] disconnected',$sname1));
		}
	}
	if($site2 ne 0) {
		$site2->quit();
		if($use_irc_conn ne 0) {
			irc_msg($irc_msgs,sprintf('[%s] disconnected',$sname2));
		}
	}
	return 1;
}

# ------------------------------------------------------------------

# show credits/ratio/section on a site in predir/dumpdir
sub show_stats {
	my $site=shift;
	my $use_irc_conn=shift;
	my $silent_mode=shift;

	my $error=0;
	my @site=get_site_data($site,0,$use_irc_conn,0,1) or $error=1;
	if($error || scalar(@site) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site));
		return 0;
	}
	my @s=connect_to_site($site[0],$site[1],$site[2],$site[3],$site[4],$site[5],0,0);
	if($s[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site[1],$s[1]));
		return 0;
	}
	if(!dirlist($s[0])) {
		irc_msg($irc_msgs, sprintf('[%s] cannot send command (%s)',$site[1],get_message($s[0])));
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return 0;
	}

	my ($group, $flags, $creds, $ratio) = ('-', '-', '-', '-');

	# call 'site user login'
	my $result=$s[0]->site(sprintf('user %s', $site[4]));

	my @out=$s[0]->message();
	if( !( (join('',@out)=~/not have access/i) || (join('',@out)=~/command disabled/i)) ) {
		for my $line2 (@out) {
			if($line2=~/Credits: (.+) MB/i) {
				$creds=trim($1);
			}
			if($line2=~/Groups: ([^ ]+)/i) {
				$group=trim($1);
			}
			if($line2=~/Flags: ([^ ]+)/i) {
				$flags=trim($1);
			}
			if($line2=~/Ratio: ([^ ]+)/i) {
				$ratio=trim($1);
			}
		}
	}

	irc_msg($irc_msgs, sprintf('[%s] Group: %s Flags: %s Credits: %s Ratio: %s',$site[1], $group, $flags, $creds, $ratio));

	disconnect($s[0],$site[1],0,0,0);
	return 1;
}

# ------------------------------------------------------------------

# kills a connection
sub kill_connection {
	my $site = shift;
	my $use_irc_conn = shift;

	my $error=0;
	my @site=get_site_data($site,0,$use_irc_conn,0,1) or $error=1;
	if($error || scalar(@site) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site));
		return 0;
	}

	my @s=connect_to_site($site[0],$site[1],$site[2],$site[3],'!'.$site[4],$site[5],0,0);
	if($s[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site[1],$s[1]));
		return 1;
	}
	else {
		my $msg = $s[2];
		if($msg=~/No dead connections found/i) {
			irc_msg($irc_msgs, sprintf('[%s] no connections to kill (No dead connections found)',$site[1]));
		}
		elsif($msg=~/(Killed 1 .* out of .* connection)/i) {
			$msg = $1;
			irc_msg($irc_msgs, sprintf('[%s] successfully killed connections (%s)',$site[1], $msg));
		}
		else {
			irc_msg($irc_msgs, sprintf('[%s] connected, no connections killed - site doesnt support that feature?',$site[1]));
		}
		disconnect($s[0],$site[1],0,0,0);
		return 0;
	}
	return 1;
}

# ------------------------------------------------------------------

# shows credits/ratio/section on all sites
sub show_stats_all {
	my $use_irc_conn=shift;

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(status)='UP' and presite=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[STATS] no sites found');
		return 0;
	}

	my $key0 = start_timer('show_stats_all');
	irc_msg($irc_msgs,'[STATS] started, checking sites');

	my %threads;
	for my $out (@rows) {
		my $thread  = threads->create('show_stats',@$out[0], $use_irc_conn,1);
		$threads{@$out[0]}=$thread;
	}

	my @done=();
	my @failed=();

	sleep(3);
	for my $sitename (keys %threads) {
		my $result=$threads{$sitename}->join();
		if($result eq 0) {
			push @failed,$sitename;
		}
		else {
			push @done,$sitename;
		}
	}

	irc_msg($irc_msgs,sprintf('[STATS] Done (%s secs) Sites done: %s - Sites failed: %s',stop_timer($key0, 1), join(', ',@done),join(', ',@failed)));
	return 1;
}

# ------------------------------------------------------------------

# gets source-sites for a site
sub fill_source_sites {
	my $dest=shift;
	my $use_irc_conn = shift;

	my ($res, $msg, @rows) = conquery_db("select upper(site),upper(source_sites) from sites where upper(site)=upper('$dest') and presite=1 and logins>0;");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[SPREAD] no sites found');
		return 0;
	}
	if(1) {
		lock(%preferedsource);
		for my $row (@rows) {
			$preferedsource{$dest}=@$row[1];
		}
	}
	return 1;
}

# ------------------------------------------------------------------

# find a source-site that can be used to get a rel from
sub find_source_site {
	my $dest=shift;

	my $temp = $preferedsource{$dest};
	my @sites=split(/,/,$temp);

	for my $tmp (@sites) {
		if((exists($free{$tmp}) && $free{$tmp}>0) && exists($sourcehash{$tmp})) {
			if (exists($busy{$tmp}) && $busy{$tmp} eq $dest) {
					debug_msg(sprintf('%s already fxping to %s... skipping choice', $tmp, $dest));
			}
			else {
				return $tmp;
			}
		}
	}
	return 0;
}

# ------------------------------------------------------------------

# control-thread for spread
sub threaded_fxp {
debug_msg('i am in sub threaded_fxp');
	my $rel = shift;
	my $use_irc_conn = shift;

	my $source;
	my $dest;
	my $target;
	my $base;
	my $maxval = 0;
	my $topsite = 0;
	my $found;
	my $result = 0;
	my $done = 0;
	my $counter = 0;
	my $value = 0;
	my %failedlogins = ();

	for (;;) {
		my $forward = 0;
		$found = 0;

		while ( my ($key, $value) = each(%sourcehash)) {
			if ($free{$key} > 0) {
				$forward++;
			}
		}
		if ($forward eq 0) {
			debug_msg('no free source, skipping route search and sleeping (wait 5 sec)');
			sleep(5);
			$found = 2;
		}

		debug_msg(sprintf('sites left: %s | sites busy: %s | site left # : %s',join(',',%desthash),join(',',%busy),scalar (keys %desthash)));

		if (scalar(keys %desthash) eq 0) {
			debug_msg('we are done!!! :)');
			return 0;
		}

		$target = 0;
		$base = 0;
		$source = 0;
		$dest = 0;
		$counter = 0;
		my %desthashcp = ();

		## refill the working hash
		for my $key ( keys %desthash ) {
			$desthashcp{$key} = $desthash{$key};
		}

		while (($found ne 1) and ($counter < 1) and ($done ne 1) and (scalar (keys %desthashcp) ne 0)) {
			debug_msg('Route Calculation - Locking Variables');

			while ($found eq 0) {
				$value = 0;
				$topsite = 0;
				$maxval = 0;

				while ( my ($key, $value) = each(%desthashcp)) {
					if (($value > $maxval) and ($free{$key} > 0)) {
						$maxval = $value;
						$topsite = $key;
					}
				}
				if ($topsite ne 0) {
					if(($free{$topsite}>0) and ($found eq 0)) {
						$source = find_source_site($topsite);
						if($source ne 0) {
							debug_msg(sprintf('found source %s and target %s .. moving on...',$source,$topsite));
							$found = 1;
							$target = $topsite;
							$base = $source;
							lock(%free);
							$free{$base}--;
							$free{$target}--;
							lock(%busy);
							$busy{$base} = $target;
						}
						else {
							delete $desthashcp{$topsite}; 
							debug_msg(sprintf('no route for topsite %s',$topsite));
						}
					}
				}
				else {
					$found = 2;
					debug_msg('no route for all sites!');
				}
			}
			if ($doingspread eq 0){
				debug_msg('spread terminated by user!!!! :)');
				return -1;
			}
			if (($found eq 0) or ($found eq 2)) {
				debug_msg('no route, freeing variables... (5 sec wait)');
				$counter++;
				sleep(5);
			}
		}
		
		if (($found eq 1) and ($base ne 0) and ($target ne 0)) {
			debug_msg('started fxp from '.$base.' to '.$target);
			$result=fxp_rel($base,$target,$rel,$use_irc_conn,1,'','',1,0,0);
			debug_msg('finished fxp from '.$base.' to '.$target.' result: '.$result);
			$done = 1;
		}
		else {
			debug_msg('no fxp found. waiting... (5 sec wait)');
			# no fxp, letting other threads work
			sleep(5);
		}

		if($done eq 1) {
			lock(%free);
			$free{$base}++;
			$free{$target}++;
			lock(%busy);
			delete $busy{$base};
			if($result eq 1) {
				lock(%sourcehash);
				$sourcehash{$target} = 0;
				lock(%desthash);
				delete $desthash{$target};

				debug_msg(sprintf('moved from destinations to source:  %s',$target));
				$result = 0;
			}
			else {
				if ($result ne 0) {
					debug_msg(sprintf('failed fxp from/to site:  %s',$result));
					$failedlogins{$result}++;
					if ($failedlogins{$result} > 2) {
						irc_msg($irc_msgs, sprintf('[SPREAD] 3 failed fxps! Removing %s from destinations! check site (space/login...) manually!',$result));
						delete $failedlogins{$result};
						lock(%desthash);
						delete $desthash{$result};
					}
				}
			}
		}

		$done = 0;
	}
	debug_msg('ERROR !!! THREAD ENDING!');
}

# ------------------------------------------------------------------

# control-thread for spread
sub force_threaded_fxp {
debug_msg('i am in sub forced_threaded_fxp');
	my $rel = shift;
	my $use_irc_conn = shift;

	my $source;
	my $dest;
	my $target;
	my $base;
	my $maxval = 0;
	my $topsite = 0;
	my $found;
	my $result = 0;
	my $done = 0;
	my $counter = 0;
	my $value = 0;
	my %failedlogins = ();

	for (;;) {
		my $forward = 0;
		$found = 0;

		while ( my ($key, $value) = each(%sourcehash)) {
			if ($free{$key} > 0) {
				$forward++;
			}
		}
		if ($forward eq 0) {
			debug_msg('no free source, skipping route search and sleeping (wait 5 sec)');
			sleep(5);
			$found = 2;
		}

		debug_msg(sprintf('sites left: %s | sites busy: %s | site left # : %s',join(',',%desthash),join(',',%busy),scalar (keys %desthash)));

		if (scalar(keys %desthash) eq 0) {
			debug_msg('we are done!!! :)');
			return 0;
		}

		$target = 0;
		$base = 0;
		$source = 0;
		$dest = 0;
		$counter = 0;
		my %desthashcp = ();

		## refill the working hash
		for my $key ( keys %desthash ) {
			$desthashcp{$key} = $desthash{$key};
		}

		while (($found ne 1) and ($counter < 1) and ($done ne 1) and (scalar (keys %desthashcp) ne 0)) {
			debug_msg('Route Calculation - Locking Variables');

			while ($found eq 0) {
				$value = 0;
				$topsite = 0;
				$maxval = 0;

				while ( my ($key, $value) = each(%desthashcp)) {
					if (($value > $maxval) and ($free{$key} > 0)) {
						$maxval = $value;
						$topsite = $key;
					}
				}
				if ($topsite ne 0) {
					if(($free{$topsite}>0) and ($found eq 0)) {
						$source = find_source_site($topsite);
						if($source ne 0) {
							debug_msg(sprintf('found source %s and target %s .. moving on...',$source,$topsite));
							$found = 1;
							$target = $topsite;
							$base = $source;
							lock(%free);
							$free{$base}--;
							$free{$target}--;
							lock(%busy);
							$busy{$base} = $target;
						}
						else {
							delete $desthashcp{$topsite}; 
							debug_msg(sprintf('no route for topsite %s',$topsite));
						}
					}
				}
				else {
					$found = 2;
					debug_msg('no route for all sites!');
				}
			}
			if ($doingspread eq 0){
				debug_msg('spread terminated by user!!!! :)');
				return -1;
			}
			if (($found eq 0) or ($found eq 2)) {
				debug_msg('no route, freeing variables... (5 sec wait)');
				$counter++;
				sleep(5);
			}
		}
		
		if (($found eq 1) and ($base ne 0) and ($target ne 0)) {
			debug_msg('started fxp from '.$base.' to '.$target);
			$result=force_fxp_rel($base,$target,$rel,$use_irc_conn,1,'','',1,0,0);
			debug_msg('finished fxp from '.$base.' to '.$target.' result: '.$result);
			$done = 1;
		}
		else {
			debug_msg('no fxp found. waiting... (5 sec wait)');
			# no fxp, letting other threads work
			sleep(5);
		}

		if($done eq 1) {
			lock(%free);
			$free{$base}++;
			$free{$target}++;
			lock(%busy);
			delete $busy{$base};
			if($result eq 1) {
				lock(%sourcehash);
				$sourcehash{$target} = 0;
				lock(%desthash);
				delete $desthash{$target};

				debug_msg(sprintf('moved from destinations to source:  %s',$target));
				$result = 0;
			}
			else {
				if ($result ne 0) {
					debug_msg(sprintf('failed fxp from/to site:  %s',$result));
					$failedlogins{$result}++;
					if ($failedlogins{$result} > 2) {
						irc_msg($irc_msgs, sprintf('[SPREAD] 3 failed fxps! Removing %s from destinations! check site (space/login...) manually!',$result));
						delete $failedlogins{$result};
						lock(%desthash);
						delete $desthash{$result};
					}
				}
			}
		}

		$done = 0;
	}
	debug_msg('ERROR !!! THREAD ENDING!');
}

# ------------------------------------------------------------------

# master spread fun .. starts the fxp threads
sub spread_master_fun {
debug_msg('i am in sub spread_master_fun');
	my $rel=shift;
	my $use_irc_conn=shift;

	if(1) {
		lock(%preferedsource);
		%preferedsource = ();
	}

	#filling sources for destinations
	for my $dest ( keys %desthash ) {
		fill_source_sites($dest, $use_irc_conn);
		debug_msg(sprintf('sources: %s <- %s!', $dest,$preferedsource{$dest}));
	}

	# number of threads = max simultan fxp processes
	my @threads=();
	debug_msg('starting threads');
	for (my $i=0; $i<$max_spreading_threads; $i++) {
		push(@threads, threads->create('threaded_fxp',$rel,$use_irc_conn));
		sleep(3);
	}

	my $final_result = 1;
	for my $thread (@threads) {
		my $res = $thread->join();
		if($res eq -1) {
			$final_result = -1;
		}
	}

	if ($final_result eq -1) {
		debug_msg('Spreading Terminated!');
		return -1;
	}
	debug_msg('Spreading done!');
	return 0;
}

# ------------------------------------------------------------------

sub force_spread_master_fun {
debug_msg('i am in sub force_spread_master_fun');
	my $rel=shift;
	my $use_irc_conn=shift;

	if(1) {
		lock(%preferedsource);
		%preferedsource = ();
	}

	#filling sources for destinations
	for my $dest ( keys %desthash ) {
		fill_source_sites($dest, $use_irc_conn);
		debug_msg(sprintf('sources: %s <- %s!', $dest,$preferedsource{$dest}));
	}

	# number of threads = max simultan fxp processes
	my @threads=();
	debug_msg('starting threads');
	for (my $i=0; $i<$max_spreading_threads; $i++) {
		push(@threads, threads->create('force_threaded_fxp',$rel,$use_irc_conn));
		sleep(3);
	}

	my $final_result = 1;
	for my $thread (@threads) {
		my $res = $thread->join();
		if($res eq -1) {
			$final_result = -1;
		}
	}

	if ($final_result eq -1) {
		debug_msg('Spreading Terminated!');
		return -1;
	}
	debug_msg('Spreading done!');
	return 0;
}

# ------------------------------------------------------------------

sub reset_shared_spread_vars {
	if(1) {
		lock(%downhash);
		lock(%sourcehash);
		lock(%desthash);
		lock(%busy);
		lock(%free);
		%downhash=();	# alle sites die down sind
		%sourcehash=();	# source sites
		%desthash=();	# destination sites
		%busy=();		# alle aktuellen fxp's
		%free=();	 	# slots (logins) fuer alle sites
	}
}

# ------------------------------------------------------------------

# find rel on sites and spread it to all other sites
sub spread_release {
debug_msg('i am in sub spread_release');
	my $rel=shift;
	my $use_irc_conn=shift;
	my $do_spread=shift;	

	if(length($rel)<=10) {
		irc_msg($irc_msgs,sprintf('[SPREAD] release %s seems to not match releasing/naming-rules (too short)',$rel));
		$doingspread = 0;
		return 0;
	}

	reset_shared_spread_vars();

	# free filln
	my ($res, $msg, @rows) = conquery_db("select upper(site),logins from sites where presite=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(1) {
		lock(%free);
		for my $out (@rows) {
			$free{@$out[0]}=@$out[1];
		}
	}

	# down filln
	($res, $msg, @rows) = conquery_db("select upper(site),speed_index from sites where upper(status)!='UP' and presite=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$res);
		return 0;
	}
	if(1) {
		lock(%downhash);
		for my $out (@rows) {
			$downhash{@$out[0]}=@$out[1];
		}
	}

	# ups filln
	my %uphash = ();
	($res, $msg, @rows) = conquery_db("select upper(site),speed_index from sites where upper(status)='UP' and presite=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[SPREAD] no sites found');
		return 0;
	}
	for my $out (@rows) {
		$uphash{@$out[0]}=@$out[1];
	}

	my $key0 = start_timer('spread_master_fun');

	irc_msg($irc_msgs,'[SPREAD] started, checking sites');

	my %speeds =();
	my %threads =();
	my $upsite = 0;

	for my $upsite (keys %uphash) {
		debug_msg(sprintf('checking status of site %s',$upsite));

		my $thread  = threads->create('check_release',$upsite, $rel, $use_irc_conn,1); 

		$threads{$upsite}=$thread;
		$speeds{$upsite}=$uphash{$upsite};
	}

	sleep(2);
	if(1) {
		lock(%sourcehash);
		lock(%desthash);
		for my $sitename (keys %threads) {
			my $result=$threads{$sitename}->join();
			debug_msg(sprintf('joined %s',$sitename));
			if($result eq 0) {
				$desthash{$sitename}=$speeds{$sitename};
			}
			else {
				lock(%sourcehash);
				$sourcehash{$sitename}=$speeds{$sitename};
			}
		}
	}

	irc_msg($irc_msgs,sprintf('[SPREAD] Sites OK: %s - Sites missing the release: %s - Sites down: %s',join(', ',keys %sourcehash),join(', ',keys %desthash),join(', ',keys %downhash)));

	if($do_spread eq 1) {
		if(scalar(keys %sourcehash) eq 0) {
			reset_shared_spread_vars();
			$doingspread = 0;
			irc_msg($irc_msgs,'[SPREAD] aborted, no sources available');
			return 0;
		}
		if(scalar(keys %desthash) eq 0) {
			reset_shared_spread_vars();
			$doingspread = 0;
			irc_msg($irc_msgs,'[SPREAD] aborted, seems all sites are done');
			return 0;
		}
		my $return = 0;
		if ($doingspread ne 0) {
			$return = spread_master_fun($rel,$use_irc_conn);
		}
		else {
			reset_shared_spread_vars();
			$doingspread = 0;
			irc_msg($irc_msgs,'[SPREAD] all sites checked and variables reset');
			return 1;
		}
		if ($return eq -1) {
			reset_shared_spread_vars();
			$doingspread = 0;
			irc_msg($irc_msgs,'[SPREAD] terminated, bot reset!');
			return 1;
		}
		irc_msg($irc_msgs,sprintf('[SPREAD] Done (%s secs)', stop_timer($key0, 1)));

	} else {
		irc_msg($irc_msgs,sprintf('[SPREAD] Done (%s secs)', stop_timer($key0, 1)));
	}

	reset_shared_spread_vars();
	$doingspread = 0;

	return 1;
}

# -----------------------------------------------------------------

# force spreading for dirfix and nfofix
sub force_spread_release {
debug_msg('i am in sub force_spread_release');
	my $rel=shift;
	my $use_irc_conn=shift;
	my $do_spread=shift;	

	if(length($rel)<=10) {
		irc_msg($irc_msgs,sprintf('[SPREAD] release %s seems to not match releasing/naming-rules (too short)',$rel));
		$doingspread = 0;
		return 0;
	}

	reset_shared_spread_vars();

	# free filln
	my ($res, $msg, @rows) = conquery_db("select upper(site),logins from sites where presite=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(1) {
		lock(%free);
		for my $out (@rows) {
			$free{@$out[0]}=@$out[1];
		}
	}

	# down filln
	($res, $msg, @rows) = conquery_db("select upper(site),speed_index from sites where upper(status)!='UP' and presite=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$res);
		return 0;
	}
	if(1) {
		lock(%downhash);
		for my $out (@rows) {
			$downhash{@$out[0]}=@$out[1];
		}
	}

	# ups filln
	my %uphash = ();
	($res, $msg, @rows) = conquery_db("select upper(site),speed_index from sites where upper(status)='UP' and presite=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[SPREAD] no sites found');
		return 0;
	}
	for my $out (@rows) {
		$uphash{@$out[0]}=@$out[1];
	}

	my $key0 = start_timer('force_spread_master_fun');

	irc_msg($irc_msgs,'[SPREAD] started, checking sites');

	my %speeds =();
	my %threads =();
	my $upsite = 0;

	for my $upsite (keys %uphash) {
		debug_msg(sprintf('checking status of site %s',$upsite));

		my $thread  = threads->create('force_check_release',$upsite, $rel, $use_irc_conn,1); 

		$threads{$upsite}=$thread;
		$speeds{$upsite}=$uphash{$upsite};
	}

	sleep(2);
	if(1) {
		lock(%sourcehash);
		lock(%desthash);
		for my $sitename (keys %threads) {
			my $result=$threads{$sitename}->join();
			debug_msg(sprintf('joined %s',$sitename));
			if($result eq 0) {
				$desthash{$sitename}=$speeds{$sitename};
			}
			else {
				lock(%sourcehash);
				$sourcehash{$sitename}=$speeds{$sitename};
			}
		}
	}

	irc_msg($irc_msgs,sprintf('[SPREAD] Sites OK: %s - Sites missing the release: %s - Sites down: %s',join(', ',keys %sourcehash),join(', ',keys %desthash),join(', ',keys %downhash)));

	if($do_spread eq 1) {
		if(scalar(keys %sourcehash) eq 0) {
			reset_shared_spread_vars();
			$doingspread = 0;
			irc_msg($irc_msgs,'[SPREAD] aborted, no sources available');
			return 0;
		}
		if(scalar(keys %desthash) eq 0) {
			reset_shared_spread_vars();
			$doingspread = 0;
			irc_msg($irc_msgs,'[SPREAD] aborted, seems all sites are done');
			return 0;
		}
		my $return = 0;
		if ($doingspread ne 0) {
			$return = force_spread_master_fun($rel,$use_irc_conn);
		}
		else {
			reset_shared_spread_vars();
			$doingspread = 0;
			irc_msg($irc_msgs,'[SPREAD] all sites checked and variables reset');
			return 1;
		}
		if ($return eq -1) {
			reset_shared_spread_vars();
			$doingspread = 0;
			irc_msg($irc_msgs,'[SPREAD] terminated, bot reset!');
			return 1;
		}
		irc_msg($irc_msgs,sprintf('[SPREAD] Done (%s secs)', stop_timer($key0, 1)));

	} else {
		irc_msg($irc_msgs,sprintf('[SPREAD] Done (%s secs)', stop_timer($key0, 1)));
	}

	reset_shared_spread_vars();
	$doingspread = 0;

	return 1;
}

# ------------------------------------------------------------------

# delete a rel on a site
sub delete_release {
	my $site=shift;
	my $rel=shift;
	my $use_irc_conn=shift;
	my $silent_mode=shift;

	my $error=0;
	my @site=get_site_data($site,0,$use_irc_conn,0,0) or $error=1;
	if($error || scalar(@site) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site));
		return 0;
	}
	my @s=connect_to_site($site[0],$site[1],$site[2],$site[3],$site[4],$site[5],0,0);
	if($s[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site[1],$s[1]));
		return 0;
	}

	my $found = 0;
	my $directory = 1;
	my $file = '';

	if(!$s[0]->cwd($rel) || ($s[0]->code ne $CODE_CMD_OK)) {
		$directory =0;

		my $newerr=0;
		my @list=dirlist($s[0]) or $newerr=1;
		if($newerr) {
			if($silent_mode eq 0) {
				irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site[1],$rel,get_message($s[0])));
			}
			disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
			return 0;
		}
		for my $line (@list) {
			# only files
			if($line=~ /^([rwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+(.+)$/i) {
				my $sub_dir=$1;
				my $sub_siz=$2;
				my $sub_fil=$3;
				if($sub_fil=~/^$rel$/i) {
					$found=1;
					$file = $sub_fil;
					last;
				}
			}
		}
	}
	else {
		$found = 1;
	}

	if($found eq 0) {
		if($silent_mode eq 0) {
			irc_msg($irc_msgs,sprintf('[%s] nope, release/file %s isnt here (%s)',$site[1],$rel,get_message($s[0])));
		}
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return 1;
	}

	if($directory eq 1) {
		my $newerr=0;
		my @list=dirlist($s[0]) or $newerr=1;
		if($newerr) {
			if($silent_mode eq 0) {
				irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site[1],$rel,get_message($s[0])));
			}
			disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
			return 0;
		}

		for my $line (@list) {
			if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+(.+)$/i) {
				my $sub_dir=$1;
				my $sub_siz=$2;
				my $sub_fil=$3;
				if($sub_dir=~/^d/i || $sub_dir=~/^l/i) {
					$s[0]->rmdir($sub_fil);
					$error=$s[0]->code();
				}
				else {
					$s[0]->delete($sub_fil);
					$error=$s[0]->code();
				}
				if($error>$CODE_CMD_OK) {
					irc_msg($irc_msgs,sprintf('[%s] cannot delete %s (%s)',$site[1],$sub_fil,get_message($s[0])));
				}
				else {
					if($silent_mode eq 0) {
						irc_msg($irc_msgs,sprintf('[%s] deleted %s',$site[1],$sub_fil));
					}
				}
			}
		}

		for my $hidden_file (@hidden_files) {
			$s[0]->delete($hidden_file);
		}

		$s[0]->cwd('..');
		$s[0]->rmdir($rel);
		$error=$s[0]->code();
		if($error>$CODE_CMD_OK) {
			irc_msg($irc_msgs,sprintf('[%s] cannot remove dir %s (%s)',$site[1],$rel,get_message($s[0])));
			disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
			return 0;
		}
		else {
			if($silent_mode eq 0) {
				irc_msg($irc_msgs,sprintf('[%s] deleted %s',$site[1],$rel));
			}
			disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
			return 1;
		}
	}
	else {
		$s[0]->delete($file);
		$error=$s[0]->code();
		if($error>$CODE_CMD_OK) {
			irc_msg($irc_msgs,sprintf('[%s] cannot delete %s (%s)',$site[1],$file,get_message($s[0])));
		}
		else {
			if($silent_mode eq 0) {
				irc_msg($irc_msgs,sprintf('[%s] deleted %s',$site[1],$file));
			}
		}
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return 1;
	}
}

# ------------------------------------------------------------------

# delete a rel on all sites
sub delete_all_release {
	my $rel=shift;
	my $use_irc_conn=shift;

	if(length($rel)<=10) {
		irc_msg($irc_msgs,sprintf('[DEL] release %s seems to not match releasing/naming-rules (too short)',$rel));
		return 0;
	}

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(status)='UP' and presite=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[DEL] no sites found');
		return 0;
	}

	irc_msg($irc_msgs,'[DEL] started, checking sites');

	my $key1 = start_timer('delete_all_release');

	my %threads;
	for my $out (@rows) {
		my $thread  = threads->create('delete_release',@$out[0], $rel, $use_irc_conn,1);
		$threads{@$out[0]}=$thread;
	}

	my @done=();
	my @failed=();

	sleep(3);
	for my $sitename (keys %threads) {
		my $result=$threads{$sitename}->join();
		if($result eq 0) {
			push @failed,$sitename;
		}
		else {
			push @done,$sitename;
		}
	}

	irc_msg($irc_msgs,sprintf('[DEL] Done (%s secs) Sites done: %s - Sites failed: %s',stop_timer($key1, 1), join(', ',@done),join(', ',@failed)));
	return 1;
}

# ------------------------------------------------------------------

# searches and downloads the nfo file on a site
sub get_nfo_file {
	my $site = shift;
	my $rel = shift;
	my $use_irc_conn = shift;
	my $download_it = shift;

	my $error=0;
	my @site=get_site_data($site,0,$use_irc_conn,0,0) or $error=1;
	if($error || scalar(@site) eq 1) {
		return 0;
	}
	my @s=connect_to_site($site[0],$site[1],$site[2],$site[3],$site[4],$site[5],0,0);
	if($s[0] eq 0) {
		return 0;
	}
	if(!$s[0]->cwd($rel) || ($s[0]->code ne $CODE_CMD_OK)) {
		disconnect($s[0],$site[1],0,0,0);
		return 0;
	}
	my $newerr=0;
	my @list=dirlist($s[0]) or $newerr=1;
	if($newerr) {
		disconnect($s[0],$site[1],0,0,0);
		return 0;
	}

	for my $line (@list) {
		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+)$/i) {
			my $sub_dir=$1;
			my $sub_siz=$2;
			my $sub_fil=$3;
			if($sub_fil=~/$nfo_name$/i) {
				if($download_it eq 1) {
					$s[0]->binary();
					my $err = $s[0]->get($sub_fil);
					return ($err eq 1)?0:$sub_fil;
				}
				else {
					return $sub_fil;
				}
			}
		}
	}
	return 0;
}

# ------------------------------------------------------------------

# dels nfo + uploads new one, 1 = ok, 0 = no release, -1 = error writing/connect
sub del_nfo {
	my $site = shift;
	my $rel = shift;
	my $nfo = shift;
	my $upload_new = shift;
	my $use_irc_conn = shift;
	my $silent_mode = shift;

	my $error=0;
	my @s;
	my @site=get_site_data($site,0,$use_irc_conn,0,0) or $error=1;
	if($error || scalar(@site) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site));
		return -1;
	}
	@s=connect_to_site($site[0],$site[1],$site[2],$site[3],$site[4],$site[5],0,0);
	if($s[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site[1],$s[1]));
		return -1;
	}
	if(!$s[0]->cwd($rel) || ($s[0]->code ne $CODE_CMD_OK)) {
		if($silent_mode eq 0) {
			irc_msg($irc_msgs,sprintf('[%s] nope, release %s isnt here (%s)',$site[1],$rel,get_message($s[0])));
		}
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return 0;
	}

	my $newerr=0;
	my @list=dirlist($s[0]) or $newerr=1;
	if($newerr) {
		if($silent_mode eq 0) {
			irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site[1],$rel,get_message($s[0])));
		}
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return -1;
	}

	for my $line (@list) {
		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+(.+)$/i) {
			my $sub_dir=$1;
			my $sub_siz=$2;
			my $sub_fil=$3;
			
			if($sub_fil=~/$nfo/i) {
				$s[0]->delete($sub_fil);
				$error=$s[0]->code();
				# file exists but cannot get deleted
				if($error>$CODE_CMD_OK) {
					if($silent_mode eq 0) {
						irc_msg($irc_msgs,sprintf('[%s] cannot delete %s (%s)',$site[1],$sub_fil,get_message($s[0])));
					}
					disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
					return -1;
				}
				else {
					if($silent_mode eq 0) {
						irc_msg($irc_msgs,sprintf('[%s] deleted %s',$site[1],$sub_fil));
					}
					last;
				}
			}
		}
	}

	# nfo file not found or successfully deleted
	if($upload_new) {
		$s[0]->binary();
		if(!$s[0]->put($nfo)) {
			if($silent_mode eq 0) {
				irc_msg($irc_msgs,sprintf('[%s] cannot upload new nfo to %s (%s)',$site[1],$nfo,get_message($s[0])));
			}
			disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
			return -1;
		}
	}

	disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
	return 1;
}

# ------------------------------------------------------------------

# searches nfo file of the rel on all sites - updates the release-date - uploads to all sites where the rel is
sub updnfo {
	my $rel = shift;
	my $site = shift;
	my $use_irc_conn = shift;

	if(length($rel)<=10) {
		irc_msg($irc_msgs,sprintf('[DEL] release %s seems to not match releasing/naming-rules (too short)',$rel));
		return 0;
	}

	my ($res, $msg, @rows) = conquery_db($site ne '' ? "select upper(site) from sites where upper(status)='UP' and presite=1 and logins>0 and upper(site)='$site' order by site" :
		"select upper(site) from sites where upper(status)='UP' and presite=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[UPDNFO] no sites found');
		return 0;
	}

	my $key1 = start_timer('updnfo');

	irc_msg($irc_msgs,'[UPDNFO] searching old nfo');
	my $source = '';
	my $nfo_file = '';
	my @sites=();
	for my $out (@rows) {
		push(@sites,@$out[0]);
	}

	for my $site (@sites) {
		debug_msg(sprintf('looking for %s on %s', $rel, $site));
		my $result = get_nfo_file($site,$rel,$use_irc_conn,1);
		if($result ne 0 && $result ne '') {
			$source = $site;
			$nfo_file = $result;
			last;
		}
	}

	if($source eq '' || $nfo_file eq '') {
		irc_msg($irc_msgs,sprintf('[UPDNFO] cannot find nfo file for release: '.$rel));
		return 0;
	}

	irc_msg($irc_msgs,sprintf('[UPDNFO] found %s on %s', $nfo_file, $source));

	# now we have downloaded the nfo file .. lets open it - replace the date - send it to all sites with the rel on it
	if(!open(NFO, $nfo_file)) {
		irc_msg($irc_msgs,sprintf('[UPDNFO] cannot read local nfo file (%s)', $!));
		return 0;
	}
	my @lines = ();
	foreach my $line (<NFO>) {
		if($line=~/$nfo_date_line/i) {
			my $old_date = $1;
			my ($Second, $Minute, $Hour, $Day, $Month, $Year, $WeekDay, $DayOfYear, $IsDST) = localtime(time);
			$Day='0'.$Day
				if($Day<10);
			$Month+=1;
			$Month='0'.$Month 
				if($Month<10);
			$Year+=1900;
			$line=~s/$old_date/$Month\/$Day\/$Year/i;
		}
		push(@lines, $line);
	}
	close(NFO);
	# del old nfo - create new one
	if(!unlink($nfo_file)) {
		irc_msg($irc_msgs,sprintf('[UPDNFO] cannot del local nfo file (%s)', $!));
		return 0;
	}
	if(!open(NFO,">$nfo_file")) {
		irc_msg($irc_msgs,sprintf('[UPDNFO] cannot create local nfo file (%s)', $!));
		return 0;
	}
	for my $line (@lines) {
		printf NFO $line;
	}
	close(NFO);

	irc_msg($irc_msgs,'[UPDNFO] sending new nfo to all sites');
	# now send the nfo to all sites where the rel is ...
	my @ok=();
	my @no_rel=();
	my @failed=();
	for my $site (@sites) {
		debug_msg('delnfo on site '.$site);
		my $result = del_nfo($site, $rel, $nfo_file, 1, $use_irc_conn, 1);
		if($result eq 1) {
			irc_msg($irc_msgs,sprintf('[%s] OK',$site));
			push(@ok, $site);
		}
		if($result eq 0) {
			irc_msg($irc_msgs,sprintf('[%s] not found',$site));
			push(@no_rel, $site);
		}
		if($result eq -1) {
			irc_msg($irc_msgs,sprintf('[%s] failed',$site));
			push(@failed, $site);
		}
	}

	irc_msg($irc_msgs,sprintf('[UPDNFO] Done (%s secs). OK: %s - NotFound: %s - Error: %s', stop_timer($key1, 1), join(', ',@ok), join(', ',@no_rel), join(', ',@failed)));

	if(!unlink($nfo_file)) {
		irc_msg($irc_msgs,sprintf('[UPDNFO] cannot del local nfo file (%s)', $!));
		return 0;
	}
	return 1;
}

# ------------------------------------------------------------------

sub scan_directory {
	my $site = shift;
	my $ftp = shift;
	my $root = shift;
	my $use_irc_conn = shift;
	my $silent_mode = 0;

	if($root=~/(\/.+)\/$/i) {
		$root = $1;
	}

	if($reset_scan eq 1) {
		debug_msg('scan stopped');
		return 1;
	}

	debug_msg('Scanning dir: '.$root);

	my $newerr=0;
	my @list=dirlist($ftp) or $newerr=1;
	if($newerr) {
		if($silent_mode eq 0) {
			irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site,$root,get_message($ftp)));
		}
		disconnect($ftp,$site,0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return 0;
	}

	my $missing_files=0;
	my $sfv_here=0;
	my $nfo_here=0;
	my $anzahl=0;
	my $sum=0;

	for my $line (@list) {
		# files + dirs
		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+.*)$/i) {
			my $sub_dir=$1;
			my $sub_siz=$2;
			my $sub_fil=$3;
			# directories
			if($sub_dir=~/^d/i && $sub_fil ne '.' && $sub_fil ne '..') {
				if(!$ftp->cwd($sub_fil) || ($ftp->code ne $CODE_CMD_OK)) {
					if($silent_mode eq 0) {
						irc_msg($irc_msgs,sprintf('[%s] cannot change to directory %s, ignoring (%s)',$site,$root.'/'.$sub_fil,get_message($ftp)));
					}
				}
				else {
					my $res = scan_directory($site, $ftp, $root.'/'.$sub_fil, $use_irc_conn);
					if($res eq 0) {
						return 0;
					}
					if($reset_scan eq 1) {
						debug_msg('scan stopped');
						return 1;
					}
					if(!$ftp->cdup() || ($ftp->code ne $CODE_CMD_OK)) {
						if($silent_mode eq 0) {
							irc_msg($irc_msgs,sprintf('[%s] cannot change to parent directory (%s)',$site,get_message($ftp)));
						}
						disconnect($ftp,$site,0,0,($silent_mode eq 0)?$use_irc_conn:0);
						return 0;
					}
				}
			}

			if($sub_fil=~/\.mp3$/i || $sub_fil=~/\.sfv$/i || $sub_fil=~/\.nfo$/i) {
				if($sub_fil=~/\.mp3$/i) {
					$anzahl++;
					$sum+=$sub_siz;
				}
			}
			if($sub_fil=~/mp3-missing/i) {
				$missing_files++;
			}
			if($sub_fil=~/\.sfv$/i) {
				$sfv_here=1;
			}
			if($sub_fil=~/\.nfo$/i) {
				$nfo_here=1;
			}
		}
		else {
			debug_msg('dirlist doesnt match: ' . $line);
		}

	}

	if($missing_files ne 0 || $sfv_here eq 0 || $nfo_here eq 0 || $anzahl eq 0 || $sum eq 0)
	{
		# we've found an incomplete mp3 rel - or - just another directory - continue
		debug_msg(sprintf('scan: %s is not a rel', $root));
	}
	else {
		# we've found a complete mp3 rel
		if($root ne '/') {
			if($root=~/^(\/.*)\/([^\/]+)\/?$/i) {
				my $path = $1;
				my $rel = $2;
				debug_msg(sprintf('scan: %s / %s is mp3 rel', $path, $rel));
				$archive_scan_hash{$rel} = $path;
				if((scalar(keys(%archive_scan_hash)) % 50) eq 0) {
					irc_msg($irc_msgs,sprintf('[%s] found %s rels .. and still scanning',$site,scalar(keys(%archive_scan_hash))));
				}
			}
		}
	}

	return 1;
}

# ------------------------------------------------------------------

# scans a site, searches all mp3 rels, creates an index file
# doesnt use fast-login, but uses stat-la
sub scan_site {
	my $site=shift;
	my $startdir=shift;
	my $use_irc_conn=shift;

	my $silent_mode = 1;
	if($startdir eq '') {
		$startdir='/';
	}

	if(!($startdir=~/^\/.*/i)) {
		irc_msg($irc_msgs,'[SCAN] error: startdir hast to begin with "/"');
		return 0;
	}

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(status)='UP' and archive=1 and logins>0 and upper(site)=upper('$site') order by speed_index");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[SCAN] site doesnt exist or site is down or site misses archive flag');
		return 0;
	}

	my $key1 = start_timer('scan_site');
	irc_msg($irc_msgs,sprintf('[SCAN] started scanning site %s at entry %s', $site, $startdir));

	my $error=0;
	my @site=get_site_data($site,0,$use_irc_conn,0,1) or $error=1;
	if($error || scalar(@site) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site));
		return 0;
	}

	my @s=connect_to_site($site[0],$site[1],$site[2],$startdir,$site[4],$site[5],0,1);
	if($s[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site[1],$s[1]));
		return 0;
	}

	if($reset_scan eq 1) {
		irc_msg($irc_msgs,sprintf('[SCAN] stopping ..'));
		return 0;
	}

	%archive_scan_hash = ();

	my $result = scan_directory($site[1], $s[0], $startdir, $use_irc_conn);

	if($reset_scan eq 1) {
		irc_msg($irc_msgs,sprintf('[SCAN] stopped scan ..'));
	}

	if(scalar(keys(%archive_scan_hash)) eq 0 || $result eq 0) {
		irc_msg($irc_msgs,sprintf('[SCAN] %s failed (%s secs)', $site, stop_timer($key1, 1)));
	}
	else {
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);

		my $filename = sprintf('%s.%s',uc($site), $index_ext);
		if(!open(FH, "> $filename")) {
			irc_msg($irc_msgs, '[SCAN] cannot create index-file');
			return 1;
		}
		for my $key (keys(%archive_scan_hash)) {
			my $rel = $key;
			my $path =  $archive_scan_hash{$key};
			my $line = sprintf("%s : %s\n", $path, $rel);
			printf FH $line;
		}
		close(FH);

		irc_msg($irc_msgs,sprintf('[SCAN] %s finished (%s secs), found %s mp3 rels, created index file', $site, stop_timer($key1, 1), scalar(keys(%archive_scan_hash))));
		%archive_scan_hash = ();
	}

	return 1;
}

# ------------------------------------------------------------------

# checks index files - searches for rels matching the keywords
sub search_archive {
	my $called_external = shift;
	my $only_site = uc(shift);
	my $use_irc_conn = shift;
	my @params = @_;

	if(length(join('', @params))<5) {
		if($called_external eq 0) {
			irc_msg($irc_msgs, '[ARCHIVESEARCH] keywords too short');
		}
		return 0;
	}

	my ($res, $msg, @rows) = conquery_db($only_site eq '' ? "select upper(site) from sites where upper(status)='UP' and archive=1 and logins>0 order by speed_index" : 
		"select upper(site) from sites where upper(status)='UP' and archive=1 and logins>0 and upper(site)='$only_site' order by speed_index");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[ARCHIVESEARCH] no archive sites that are up or no index files present for given sitenname');
		return 0;
	}

	my @sites=();
	for my $out (@rows) {
		push @sites,@$out[0];
	}

	my $key1=start_timer('search_archive');
	if($called_external eq 0) {
		irc_msg($irc_msgs, sprintf('[ARCHIVESEARCH] checking index files from %s for \'%s\'', join(', ', @sites), join(' ', @params)));
	}

	my %found;
	my $max_reached = 0;
	my $pattern = join('.*', @params);
	for my $site (@sites) {
		my $error = 0;
		my $filename = sprintf('%s.%s', $site, $index_ext);
		open(FH, $filename) or $error = 1;
		if($error eq 0) {
			foreach my $line (<FH>) {
				if($line=~/^(.+) : (.+)$/i) {
					my $path = $1;
					my $rel = $2;
					if($rel=~/$pattern/i) {
						if($max_reached eq 0) {
							irc_msg($irc_msgs, sprintf('[ARCHIVESEARCH] %s found %s in %s', $site, $rel, $path));
						}
						$found{sprintf('%s/%s', $path, $rel)} = $site;
						if($max_reached eq 0 && scalar(keys(%found)) > 20) {
							$max_reached = 1;
							if($called_external eq 0) {
								irc_msg($irc_msgs, '[ARCHIVESEARCH] too many results ...');
							}
						}
					}
				}
			}
			close(FH);
		}
		else {
			debug_msg(sprintf('check_archive: no index file for %s', $site));
		}
	}

	if(scalar(keys(%found))>0) {
		if($called_external eq 0) {
			irc_msg($irc_msgs, sprintf('[ARCHIVESEARCH] Done (%s secs), found %s rels, now you can use !pre gimme to get these rels', stop_timer($key1, 1), scalar(keys(%found))));
		}
		else {
			irc_msg($irc_msgs, sprintf('[ARCHIVESEARCH] Done (%s secs), found %s rels', stop_timer($key1, 1), scalar(keys(%found))));
		}
	}
	else {
		irc_msg($irc_msgs, sprintf('[ARCHIVESEARCH] Done (%s secs), nothing found', stop_timer($key1, 1)));
	}
	return %found;
}


# ------------------------------------------------------------------

# check if a release is complete (tagline + nfo + sfv + mp3-files + no missing ones ... )
sub check_release {
debug_msg('i am in sub check_release');
	my $site=shift;
	my $rel=shift;
	my $use_irc_conn=shift;
	my $silent_mode=shift;

	my $error=0;
	my @site=get_site_data($site,0,$use_irc_conn,0,0) or $error=1;
	if($error || scalar(@site) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site));
		return 0;
	}
	my @s=connect_to_site($site[0],$site[1],$site[2],$site[3],$site[4],$site[5],0,0);
	if($s[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site[1],$s[1]));
		return 0;
	}
	if(!$s[0]->cwd($rel) || ($s[0]->code ne $CODE_CMD_OK)) {
		if($silent_mode eq 0) {
			irc_msg($irc_msgs,sprintf('[%s] nope, release %s isnt here (%s)',$site[1],$rel,get_message($s[0])));
		}
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return 0;
	}
	my $newerr=0;
	my @list=dirlist($s[0]) or $newerr=1;
	if($newerr) {
		if($silent_mode eq 0) {
			irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site[1],$rel,get_message($s[0])));
		}
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return 0;
	}

	my $completed=0;
	my $missing_files=0;
	my $site_tag='';
	my $sfv_here=0;
	my $nfo_here=0;
	my $anzahl=0;
	my $anzahl_total=0;
	my $sum=0;

	# directory einlesen
	for my $line (@list) {
		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+)$/i) {
			my $sub_dir=$1;
			my $sub_siz=$2;
			my $sub_fil=$3;
			if($sub_fil=~/\.mp3$/i || $sub_fil=~/\.sfv$/i ||  $sub_fil=~/\.zip$/i ||  $sub_fil=~/\.jpg$/i ||  $sub_fil=~/\.gif$/i ||  $sub_fil=~/\.nfo$/i || $sub_fil=~/\.cue$/i) {
				if($sub_dir=~/^\-/i && $sub_siz>0 and $sub_fil=~/^[^\.]/i) {
					$anzahl_total++;
				}
				if($sub_fil=~/\.mp3$/i) {
					$anzahl++;
					$sum+=$sub_siz;
				}
			}
			if($sub_fil=~/mp3-missing/i) {
				$missing_files++;
				$completed=0;
			}
			if($sub_fil=~/\.sfv$/i) {
				$sfv_here=1;
			}
			if($sub_fil=~/\.nfo$/i) {
				$nfo_here=1;
			}
		}
		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+(.+)$/i) {
			my $sub_fil=$3;
			for my $reg_arr (@complet_tags) {
				my ($reg1,$reg2) = @$reg_arr;
				if($sub_fil=~/$reg1/ && $sub_fil=~/$reg2/) {
					$completed=1;
					$site_tag=$sub_fil;
				}
				last if($completed eq 1);
			}
		}
	}

	if($completed eq 0 || $missing_files ne 0 || $site_tag eq '' || $sfv_here eq 0 || $nfo_here eq 0 || $anzahl eq 0 || $sum eq 0)
	{
		if($site_tag ne '') {
			$site_tag='found';
		}
		else {
			$site_tag='not found';
		}
		if($silent_mode eq 0) {
			irc_msg($irc_msgs, sprintf('[%s] %s is incomplete (mp3\'s: %s, size: %s, missing: %s, site_tag: %s, sfv: %s, nfo: %s)',
						$site[1],$rel, $anzahl, $sum, $missing_files, $site_tag, $sfv_here, $nfo_here));
		}
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return 0;
	}

	if($silent_mode eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] release %s is complete',$site[1],$rel));
	}
	disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);

	return 1;
}

# ------------------------------------------------------------------

# check if a dir is existing with an nfo
sub force_check_release {
debug_msg('i am in sub force_check_release');
	my $site=shift;
	my $rel=shift;
	my $use_irc_conn=shift;
	my $silent_mode=shift;

	my $error=0;
	my @site=get_site_data($site,0,$use_irc_conn,0,0) or $error=1;
	if($error || scalar(@site) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site));
		return 0;
	}
	my @s=connect_to_site($site[0],$site[1],$site[2],$site[3],$site[4],$site[5],0,0);
	if($s[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site[1],$s[1]));
		return 0;
	}
	if(!$s[0]->cwd($rel) || ($s[0]->code ne $CODE_CMD_OK)) {
		if($silent_mode eq 0) {
			irc_msg($irc_msgs,sprintf('[%s] nope, release %s isnt here (%s)',$site[1],$rel,get_message($s[0])));
		}
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return 0;
	}
	my $newerr=0;
	my @list=dirlist($s[0]) or $newerr=1;
	if($newerr) {
		if($silent_mode eq 0) {
			irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site[1],$rel,get_message($s[0])));
		}
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return 0;
	}

	my $completed=0;
	my $missing_files=0;
	my $site_tag='';
	my $sfv_here=0;
	my $nfo_here=0;
	my $anzahl=0;
	my $anzahl_total=0;
	my $sum=0;

	# directory einlesen
	for my $line (@list) {
		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+)$/i) {
			my $sub_dir=$1;
			my $sub_siz=$2;
			my $sub_fil=$3;
			if($sub_fil=~/\.mp3$/i || $sub_fil=~/\.sfv$/i ||  $sub_fil=~/\.zip$/i ||  $sub_fil=~/\.jpg$/i ||  $sub_fil=~/\.gif$/i ||  $sub_fil=~/\.nfo$/i || $sub_fil=~/\.cue$/i) {
				if($sub_dir=~/^\-/i && $sub_siz>0 and $sub_fil=~/^[^\.]/i) {
					$anzahl_total++;
				}
				if($sub_fil=~/\.mp3$/i) {
					$anzahl++;
					$sum+=$sub_siz;
				}
			}
			if($sub_fil=~/mp3-missing/i) {
				$missing_files++;
				$completed=0;
			}
			if($sub_fil=~/\.sfv$/i) {
				$sfv_here=1;
			}
			if($sub_fil=~/\.nfo$/i) {
				$nfo_here=1;
			}
		}
		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+(.+)$/i) {
			my $sub_fil=$3;
			for my $reg_arr (@complet_tags) {
				my ($reg1,$reg2) = @$reg_arr;
				if($sub_fil=~/$reg1/ && $sub_fil=~/$reg2/) {
					$completed=1;
					$site_tag=$sub_fil;
				}
				last if($completed eq 1);
			}
		}
	}

	if($nfo_here eq 0)
	{
		# if($site_tag ne '') {
			# $site_tag='found';
		# }
		# else {
			# $site_tag='not found';
		# }
		if($silent_mode eq 0) {
			irc_msg($irc_msgs, sprintf('[%s] %s is incomplete (nfo: %s)',
						$site[1],$rel, $nfo_here));
		}
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return 0;
	}

	if($silent_mode eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] release %s is complete',$site[1],$rel));
	}
	disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);

	return 1;
}


# ------------------------------------------------------------------

# pre on a single site
sub do_pre {
	my $precmd=shift;
	my $ftp=shift;
	my $site_name=shift;
	my $rel=shift;
	my $msg;

	debug_msg(sprintf('%s: waiting for broadcast',$site_name));
	if (1) {
		lock($readypre);
		$readypre--;
	}
	if (1) {
		lock($syncvar);
		cond_wait($syncvar);
	}

	my ($Second, $Minute, $Hour, $Day, $Month, $Year, $WeekDay, $DayOfYear, $IsDST) = localtime(time);
	my $time = ($Hour<10?'0':'').$Hour.':'.($Minute<10?'0':'').$Minute.':'.($Second<10?'0':'').$Second;

	if(!$ftp->site($precmd)){
		$msg=sprintf('[PRE] %s - %s failed (connection timed out!)',$time,$site_name);
		#lets try late pre: 

		my $error=0;
		my @site=get_site_data($site_name,0,0,0,0) or $error=1;
		if($error || scalar(@site) eq 1) {
			$msg=$msg . ' - Late PRE failed !! pre by hand!';
			return $msg;
		}
		my @s=connect_to_site($site[0],$site[1],$site[2],$site[3],$site[4],$site[5],0,0);
		if($s[0] eq 0) {
			$msg=$msg . sprintf(' - Late PRE failed !! cant connect to %s pre by hand!',$site_name);
			return $msg;
		}
		if(!$s[0]->cwd($rel) || ($s[0]->code ne $CODE_CMD_OK)) {
			disconnect($s[0],$site[1],0,0,0);
			$msg=$msg . ' - Late PRE failed !! total site error! pre by hand!';
			return $msg;
		}
		$ftp=$site[0];
		if(!$ftp->site($precmd)){
			$msg=$msg . ' - Late PRE failed !! (2nd pre test) try to pre by hand!';
			return $msg;
		}
		$msg=$msg . ' - Late PRE worked!';
		return $msg;
	}

	my $result=$ftp->code();
	if($result eq 200) {
		my $msg=sprintf('[PRE] %s - %s done',$time,$site_name);
		disconnect($ftp,$site_name,0,0,0);
		return $msg;
	}
	else {
		my $msg=sprintf('[PRE] %s - %s failed (%s)',$time,$site_name,get_message($ftp));
		disconnect($ftp,$site_name,0,0,0);
		return $msg;
	}
}

# ------------------------------------------------------------------

# start threads to connect to all sites - synchronize them - then call pre
sub pre_rel {
	my $rel=shift;
	my $use_irc_conn=shift;

	$gotopre = 0;
	$readypre = 0;
	$releasesize = -1;

	if(length($rel)<=10) {
		irc_msg($irc_msgs,sprintf('[PRE] release %s seems to not match releasing/naming-rules (too short)',$rel));
		return 0;
	}

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(status)='UP' and presite=1 and logins>0 order by speed_index");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[PRE] no sites found');
		return 0;
	}

	my $key0 = start_timer('pre_master_fun');
	irc_msg($irc_msgs,'[PRE] started');

# get all sites that are up
	my @sites=();
	for my $out (@rows) {
		push @sites,@$out[0];
	}

#starting pre threads
	my @threads = ();
	for my $site (@sites) {
		if ($readypre > -10) {
			my $thread  = threads->create('site_pre_rel',$rel, $site, $use_irc_conn);
			push @threads,$thread;
		}
	}

	sleep(3);

	if ($readypre > -10) {
		irc_msg($irc_msgs,'[PRE] threads created waiting till all sites connected');
	}
# connect all sites
	while ($readypre ne scalar(@sites)) {
		if ($readypre < -10) {
			irc_msg($irc_msgs,'[PRE] cancled');
			return;
		}
		sleep(1);
	}

	$gotopre = 1;
# all sites in lock (readypre is decreased when sitethread ready)

	while ($readypre ne 0) {
		sleep(1);
	}

	$gotopre = 1;
	irc_msg($irc_msgs,'[PRE] pre started');
	if(1) {
		lock($syncvar);
		cond_broadcast($syncvar);
	}
	sleep(5);

	for my $thread (@threads) {
		my $res=$thread->join();
		irc_msg($irc_msgs,$res);
	}

	my $out_line = $register_line;
	$out_line =~ s/{rel}/$rel/i;

	if($use_register_line eq 1) {
		irc_msg($irc_msgs,$out_line);
	}

	if($enable_trading eq 1) {
		sleep(3);
		irc_msg($irc_msgs,sprintf('[PRE] Done (%s secs). Now spreading the rel to several sites .)', stop_timer($key0, 1)));
		auto_trade($rel,$use_irc_conn);
		return;
	}

	return;
}

# ------------------------------------------------------------------

# log on site - check if rel is complete - idle there - wait for broadcast to pre finally
sub site_pre_rel {
	my $rel=shift;
	my $site_name=shift;
	my $use_irc_conn=shift;

	my @site_data=();
	my @site_obj=();

	my $error=0;
	my $key1 = start_timer('site_pre_rel_'.$site_name);
	@site_data=get_site_data($site_name,0,$use_irc_conn,0,0) or $error=1;
	if($error || (scalar(@site_data) eq 1)) {
		irc_msg($irc_msgs, sprintf('[%s] database failure!',$site_name));
		lock($readypre);
		$readypre = -100;
		return -1;
	}

	@site_obj=connect_to_site($site_data[0],$site_data[1],$site_data[2],$site_data[3],$site_data[4],$site_data[5],0,0);
	if($site_obj[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site_data[1],$site_obj[1]));
		lock($readypre);
		$readypre = -100;
		return -1;
	}
	irc_msg($irc_msgs,sprintf('[%s] connected (%s secs)',$site_data[1], stop_timer($key1, 1)));

	if(!$site_obj[0]->cwd($rel) || ($site_obj[0]->code ne $CODE_CMD_OK)) {
		irc_msg($irc_msgs,sprintf('[%s] nope, release %s isnt here (%s)',$site_data[1],$rel,get_message($site_obj[0])));
		disconnect($site_obj[0],$site_data[1],0,0,$use_irc_conn);
		lock($readypre);
		$readypre = -100;
		return -1;
	}


	# check if release is complete
	my $newerr=0;
	my @list=dirlist($site_obj[0]) or $newerr=1;
	if($newerr) {
		irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site_data[1],$rel,get_message($site_obj[0])));
		disconnect($site_obj[0],$site_data[1],0,0,$use_irc_conn);
		return -1;
	}

	my $completed=0;
	my $missing_files=0;
	my $site_tag='';
	my $sfv_here=0;
	my $nfo_here=0;
	my $anzahl=0;
	my $anzahl_total=0;
	my $sum=0;

	# directory einlesen
	for my $line (@list) {
		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+)$/i) {
			my $sub_dir=$1;
			my $sub_siz=$2;
			my $sub_fil=$3;
			if($sub_fil=~/\.mp3$/i || $sub_fil=~/\.sfv$/i ||  $sub_fil=~/\.zip$/i ||  $sub_fil=~/\.jpg$/i ||  $sub_fil=~/\.gif$/i ||  $sub_fil=~/\.nfo$/i || $sub_fil=~/\.cue$/i) {
				if($sub_dir=~/^\-/i && $sub_siz>0 and $sub_fil=~/^[^\.]/i) {
					$anzahl_total++;
				}
				if($sub_fil=~/\.mp3$/i) {
					$anzahl++;
					$sum+=$sub_siz;
				}
			}
			if($sub_fil=~/mp3-missing/i) {
				$missing_files++;
				$completed=0;
			}
			if($sub_fil=~/\.sfv$/i) {
				$sfv_here=1;
			}
			if($sub_fil=~/\.nfo$/i) {
				$nfo_here=1;
			}
		}
		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+(.+)$/i) {
			my $sub_fil=$3;
			for my $reg_arr (@complet_tags) {
				my ($reg1,$reg2) = @$reg_arr;
				if($sub_fil=~/$reg1/ && $sub_fil=~/$reg2/) {
					$completed=1;
					$site_tag=$sub_fil;
				}
				last if($completed eq 1);
			}
		}
	}

	if(1){
		lock($releasesize);
		if ($releasesize eq -1) {
			$releasesize = $sum;
		}
	}

	if($completed eq 0 || $missing_files ne 0 || $site_tag eq '' || $sfv_here eq 0 || $nfo_here eq 0 || $anzahl eq 0 || $sum eq 0 || $releasesize ne $sum){
		if($site_tag ne '') {
			$site_tag='found';
		}
		else {
			$site_tag='not found';
		}
		if($releasesize ne $sum) {
			irc_msg($irc_msgs,sprintf('[%s] sum of filesizes (mp3) differs!',$site_data[1]));
		}
		else {
			irc_msg($irc_msgs, sprintf('[%s] %s is incomplete (mp3\'s: %s, size: %s, missing: %s, site_tag: %s, sfv: %s, nfo: %s) - aborting',
						$site_data[1],$rel, $anzahl, $sum, $missing_files, $site_tag, $sfv_here, $nfo_here));
		}
		disconnect($site_obj[0],$site_data[1],0,0,$use_irc_conn);
		irc_msg($irc_msgs,'[PRE] failed');
		lock($readypre);
		$readypre = -100;
		return -1;
	}

# chdir ..

	$site_obj[0]->cwd('..');

	my $ftp_object=$site_obj[0];
	my $prepath = $site_data[6];
	my $forward = 0;
	my $counter = 0;
	my $result;

	debug_msg(sprintf('[%s] ready',$site_name));

	while ($forward eq 0) {
		$result = 0;
		if ($readypre < -10) {
			debug_msg(sprintf('[%s] stopped pre',$site_name));
			disconnect($ftp_object,$site_name,0,0,0);
			return -1;
		}
		if(!$ftp_object->ascii()) {
			irc_msg($irc_msgs,sprintf('[%s] lost connection, cancling pre!',$site_name));
			lock($readypre);
			$readypre = -100;
		}
		if ($counter eq 0) {
			$counter++;
			lock($readypre);
			$readypre++;
		}
		if ($gotopre ne 0) {
			$forward = 1;
		}
		else {
			sleep(5);
		}
	}

# finally pre on all sites

	my $precmd=$prepath;
	$precmd=~s/RELEASENAME/$rel/i;
	my $replymsg = do_pre($precmd,$ftp_object,$site_name,$rel);
	disconnect($ftp_object,$site_name,0,0,0);
	return $replymsg;
}

# ------------------------------------------------------------------

# start threads to connect to all sites - synchronize them - then call pre
sub force_pre_rel {
	my $rel=shift;
	my $use_irc_conn=shift;

	$gotopre = 0;
	$readypre = 0;
	$releasesize = -1;

	if(length($rel)<=10) {
		irc_msg($irc_msgs,sprintf('[PRE] release %s seems to not match releasing/naming-rules (too short)',$rel));
		return 0;
	}

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(status)='UP' and presite=1 and logins>0 order by speed_index");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[PRE] no sites found');
		return 0;
	}

	my $key0 = start_timer('pre_master_fun');
	irc_msg($irc_msgs,'[PRE] started');

# get all sites that are up
	my @sites=();
	for my $out (@rows) {
		push @sites,@$out[0];
	}

#starting pre threads
	my @threads = ();
	for my $site (@sites) {
		if ($readypre > -10) {
			my $thread  = threads->create('site_force_pre_rel',$rel, $site, $use_irc_conn);
			push @threads,$thread;
		}
	}

	sleep(3);

	if ($readypre > -10) {
		irc_msg($irc_msgs,'[PRE] threads created waiting till all sites connected');
	}
# connect all sites
	while ($readypre ne scalar(@sites)) {
		if ($readypre < -10) {
			irc_msg($irc_msgs,'[PRE] cancled');
			return;
		}
		sleep(1);
	}

	$gotopre = 1;
# all sites in lock (readypre is decreased when sitethread ready)

	while ($readypre ne 0) {
		sleep(1);
	}

	$gotopre = 1;
	irc_msg($irc_msgs,'[PRE] pre started');
	if(1) {
		lock($syncvar);
		cond_broadcast($syncvar);
	}
	sleep(5);

	for my $thread (@threads) {
		my $res=$thread->join();
		irc_msg($irc_msgs,$res);
	}

	my $out_line = $register_line;
	$out_line =~ s/{rel}/$rel/i;

	irc_msg($irc_msgs,$out_line);

	if($enable_trading eq 1) {
		sleep(3);
		irc_msg($irc_msgs,sprintf('[PRE] Done (%s secs). Now spreading the rel to several sites .)', stop_timer($key0, 1)));
		auto_trade($rel,$use_irc_conn);
		return;
	}

	return;
}

# ------------------------------------------------------------------

# log on site - check if rel is complete - idle there - wait for broadcast to pre finally
sub site_force_pre_rel {
	my $rel=shift;
	my $site_name=shift;
	my $use_irc_conn=shift;

	my @site_data=();
	my @site_obj=();

	my $error=0;
	my $key1 = start_timer('site_force_pre_rel_'.$site_name);
	@site_data=get_site_data($site_name,0,$use_irc_conn,0,0) or $error=1;
	if($error || (scalar(@site_data) eq 1)) {
		irc_msg($irc_msgs, sprintf('[%s] database failure!',$site_name));
		lock($readypre);
		$readypre = -100;
		return -1;
	}

	@site_obj=connect_to_site($site_data[0],$site_data[1],$site_data[2],$site_data[3],$site_data[4],$site_data[5],0,0);
	if($site_obj[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site_data[1],$site_obj[1]));
		lock($readypre);
		$readypre = -100;
		return -1;
	}
	irc_msg($irc_msgs,sprintf('[%s] connected (%s secs)',$site_data[1], stop_timer($key1, 1)));

	if(!$site_obj[0]->cwd($rel) || ($site_obj[0]->code ne $CODE_CMD_OK)) {
		irc_msg($irc_msgs,sprintf('[%s] nope, release %s isnt here (%s)',$site_data[1],$rel,get_message($site_obj[0])));
		disconnect($site_obj[0],$site_data[1],0,0,$use_irc_conn);
		lock($readypre);
		$readypre = -100;
		return -1;
	}


	# check if release is complete
#	my $newerr=0;
#	my @list=dirlist($site_obj[0]) or $newerr=1;
#	if($newerr) {
#		irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site_data[1],$rel,get_message($site_obj[0])));
#		disconnect($site_obj[0],$site_data[1],0,0,$use_irc_conn);
#		return -1;
#	}
#
#	my $completed=0;
#	my $missing_files=0;
#	my $site_tag='';
#	my $sfv_here=0;
#	my $nfo_here=0;
#	my $anzahl=0;
#	my $anzahl_total=0;
#	my $sum=0;
#
#	# directory einlesen
#	for my $line (@list) {
#		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+)$/i) {
#			my $sub_dir=$1;
#			my $sub_siz=$2;
#			my $sub_fil=$3;
#			if($sub_fil=~/\.mp3$/i || $sub_fil=~/\.sfv$/i ||  $sub_fil=~/\.zip$/i ||  $sub_fil=~/\.jpg$/i ||  $sub_fil=~/\.gif$/i ||  $sub_fil=~/\.nfo$/i || $sub_fil=~/\.cue$/i) {
#				if($sub_dir=~/^\-/i && $sub_siz>0 and $sub_fil=~/^[^\.]/i) {
#					$anzahl_total++;
#				}
#				if($sub_fil=~/\.mp3$/i) {
#					$anzahl++;
#					$sum+=$sub_siz;
#				}
#			}
#			if($sub_fil=~/mp3-missing/i) {
#				$missing_files++;
#				$completed=0;
#			}
#			if($sub_fil=~/\.sfv$/i) {
#				$sfv_here=1;
#			}
#			if($sub_fil=~/\.nfo$/i) {
#				$nfo_here=1;
#			}
#		}
#		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+(.+)$/i) {
#			my $sub_fil=$3;
#			for my $reg_arr (@complet_tags) {
#				my ($reg1,$reg2) = @$reg_arr;
#				if($sub_fil=~/$reg1/ && $sub_fil=~/$reg2/) {
#					$completed=1;
#					$site_tag=$sub_fil;
#				}
#				last if($completed eq 1);
#			}
#		}
#	}
#
#	if(1){
#		lock($releasesize);
#		if ($releasesize eq -1) {
#			$releasesize = $sum;
#		}
#	}
#
#	if($completed eq 0 || $missing_files ne 0 || $site_tag eq '' || $sfv_here eq 0 || $nfo_here eq 0 || $anzahl eq 0 || $sum eq 0 || $releasesize ne $sum){
#		if($site_tag ne '') {
#			$site_tag='found';
#		}
#		else {
#			$site_tag='not found';
#		}
#		if($releasesize ne $sum) {
#			irc_msg($irc_msgs,sprintf('[%s] sum of filesizes (mp3) differs!',$site_data[1]));
#		}
#		else {
#			irc_msg($irc_msgs, sprintf('[%s] %s is incomplete (mp3\'s: %s, size: %s, missing: %s, site_tag: %s, sfv: %s, nfo: %s) - aborting',
#						$site_data[1],$rel, $anzahl, $sum, $missing_files, $site_tag, $sfv_here, $nfo_here));
#		}
#		disconnect($site_obj[0],$site_data[1],0,0,$use_irc_conn);
#		irc_msg($irc_msgs,'[PRE] failed');
#		lock($readypre);
#		$readypre = -100;
#		return -1;
#	}
	


# chdir ..

	$site_obj[0]->cwd('..');

	my $ftp_object=$site_obj[0];
	my $prepath = $site_data[6];
	my $forward = 0;
	my $counter = 0;
	my $result;

	debug_msg(sprintf('[%s] ready',$site_name));

	while ($forward eq 0) {
		$result = 0;
		if ($readypre < -10) {
			debug_msg(sprintf('[%s] stopped pre',$site_name));
			disconnect($ftp_object,$site_name,0,0,0);
			return -1;
		}
		if(!$ftp_object->ascii()) {
			irc_msg($irc_msgs,sprintf('[%s] lost connection, cancling pre!',$site_name));
			lock($readypre);
			$readypre = -100;
		}
		if ($counter eq 0) {
			$counter++;
			lock($readypre);
			$readypre++;
		}
		if ($gotopre ne 0) {
			$forward = 1;
		}
		else {
			sleep(5);
		}
	}

# finally pre on all sites

	my $precmd=$prepath;
	$precmd=~s/RELEASENAME/$rel/i;
	my $replymsg = do_pre($precmd,$ftp_object,$site_name,$rel);
	disconnect($ftp_object,$site_name,0,0,0);
	return $replymsg;
}

# ------------------------------------------------------------------



# searches a rel on a site - checks today-dir + sorted-daydirs + site-search + site-dupe
sub search_rel_on_site {
	my $site = shift;
	my $sorted = shift;
	my $today = shift;
	my $additional = shift;
	my $rel = shift;
	my $gimmemode = shift;
	my $use_irc_conn = shift;

	my $found_rels = '';
	my $error=0;
	my @site=get_site_data($site,0,$use_irc_conn,0,1) or $error=1;
	if($error || scalar(@site) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site));
		return '';
	}

	my @s=connect_to_site($site[0],$site[1],$site[2],0,$site[4],$site[5],0,1);
	if($s[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site[1],$s[1]));
		return '';
	}

	my $error_msg1 = 'No such file or directory';
	my $error_msg2 = 'file or directory not found';

	debug_msg(sprintf('search: %s on %s', $rel, $site));

	my $key = start_timer($site.$rel);

	my @found=();
	my $bla='';

	# first check site-search - glftpd standard + ioftpd
	if((scalar(@found) eq 0)) {
		my $result=$s[0]->site(sprintf('SEARCH %s',$rel));
		my @out=$s[0]->message();
		for my $line (@out) {
			$line=~ s/[|¦³]+//g;
			if($line=~/^[ ]{1,2}(\/[^ ]+)[ ]*.*$/i) {
				$bla=$1;
				$bla=~ s/\n//g;
				$bla=~ s/\r//g;
				last if(scalar(@found) eq 10);
				if(scalar(grep(/^$bla/,@found)) eq 0)
				{
					if($s[0]->cwd($bla) && ($s[0]->code eq $CODE_CMD_OK)) {
						$bla=$s[0]->pwd();
						push @found,$bla;
						if($gimmemode ne 1) {
							irc_msg($irc_msgs,sprintf('[%s] (site search) found %s',$site[1],$bla));
						} else {
							if($found_rels eq '') {
								lock($first_rel);
								if($first_rel eq '' and $bla=~/^.*\/([^\/]+[(]*[0-9]{4}[)]*\-.{2,9})$/i) {
									$first_rel=$1;
									debug_msg($site.' search: found '.$first_rel);
								}
								my $use_rel = $first_rel;
								$use_rel =~ s/([()]+)/\\$1/g;
								if($first_rel ne '' and $bla=~/^.+$use_rel$/i) {
									$found_rels=$bla;
									debug_msg($site.' search: added '.$bla);
								}
							}
						}
					}
					else {
						my $msg = get_message($s[0]);
						if(!($msg=~/$error_msg1/i || $msg=~/$error_msg2/i)) {
							debug_msg($site.': cannot change to release-dir: '.$bla.' ('.$msg.')');
						}
					}
				}
			}
		}
	}

	# then check today-dir (not in site-search nor sorted-daydirs)
	if((scalar(@found) eq 0) && ($today ne '')) {
		if($s[0]->cwd($today) && ($s[0]->code eq $CODE_CMD_OK)) {
			if($s[0]->cwd($rel) && ($s[0]->code eq $CODE_CMD_OK)) {
				$bla=$s[0]->pwd();
				push @found,$bla;
				if($gimmemode ne 1) {
					irc_msg($irc_msgs,sprintf('[%s] (today) found %s',$site[1],$bla));
				} else {
					if($found_rels eq '') {
						lock($first_rel);
						if($first_rel eq '' and $bla=~/^.*\/([^\/]+[(]*[0-9]{4}[)]*\-.{2,9})$/i) {
							$first_rel=$1;
							debug_msg($site.' daydir: found '.$first_rel);
						}
						my $use_rel = $first_rel;
						$use_rel =~ s/([()]+)/\\$1/g;
						if($first_rel ne '' and $bla=~/^.+$use_rel$/i) {
							$found_rels=$bla;
							debug_msg($site.' today: added '.$bla);
						}
					}
				}
			}
			else {
				my $msg = get_message($s[0]);
				if(!($msg=~/$error_msg1/i || $msg=~/$error_msg2/i)) {
					debug_msg($site.': cannot change to today/rel-dir: '.$rel.' ('.$msg.')');
				}
			}
		}
		else {
			my $msg = get_message($s[0]);
			if(!($msg=~/$error_msg1/i || $msg=~/$error_msg2/i)) {
				debug_msg($site.': cannot change to today-dir: '.$today.' ('.$msg.')');
			}
		}
	}

	# list of sorted daydirs
	if((scalar(@found) eq 0) && ($sorted ne '')) {
		my @sorteds = split(',', $sorted);
		for my $tmp (@sorteds) {

			# then check sorted-daydir
			if((scalar(@found) eq 0) && ($tmp ne '')) {
				$rel=~/^(.{1}).+$/;
				my $case = uc($1);
				$bla=$tmp.'/'.$case.'/'.$rel;
				if($s[0]->cwd($bla) && ($s[0]->code eq $CODE_CMD_OK)) {
					$bla=$s[0]->pwd();
					push @found,$bla;
					if($gimmemode ne 1) {
						irc_msg($irc_msgs,sprintf('[%s] (sorted daydir) found %s',$site[1],$bla));
					} else {
						if($found_rels eq '') {
							lock($first_rel);
							if($first_rel eq '' and $bla=~/^.*\/([^\/]+[(]*[0-9]{4}[)]*\-.{2,9})$/i) {
								$first_rel=$1;
								debug_msg($site.' daydir: found '.$first_rel);
							}
							my $use_rel = $first_rel;
							$use_rel =~ s/([()]+)/\\$1/g;
							if($first_rel ne '' and $bla=~/^.+$use_rel$/i) {
								$found_rels=$bla;
								debug_msg($site.' daydir: added '.$bla);
							}
						}
					}
				}
				else {
					my $msg = get_message($s[0]);
					if(!($msg=~/$error_msg1/i || $msg=~/$error_msg2/i)) {
						debug_msg($site.': cannot change to sorted-dir: '.$bla.' ('.$msg.')');
					}
				}

				# 2nd case for various
				if(uc($case) eq 'V') {
					$bla=$tmp.'/Various/'.$rel;
					if($s[0]->cwd($bla) && ($s[0]->code eq $CODE_CMD_OK)) {
						$bla=$s[0]->pwd();
						push @found,$bla;
						if($gimmemode ne 1) {
							irc_msg($irc_msgs,sprintf('[%s] (sorted daydir) found %s',$site[1],$bla));
						} else {
							if($found_rels eq '') {
								lock($first_rel);
								if($first_rel eq '' and $bla=~/^.*\/([^\/]+[(]*[0-9]{4}[)]*\-.{2,9})$/i) {
									$first_rel=$1;
									debug_msg($site.' daydir: found '.$first_rel);
								}
								my $use_rel = $first_rel;
								$use_rel =~ s/([()]+)/\\$1/g;
								if($first_rel ne '' and $bla=~/^.+$use_rel$/i) {
									$found_rels=$bla;
									debug_msg($site.' daydir: added '.$bla);
								}
							}
						}
					}
					else {
						my $msg = get_message($s[0]);
						if(!($msg=~/$error_msg1/i || $msg=~/$error_msg2/i)) {
							debug_msg($site.': cannot change to sorted-various-dir: '.$bla.' ('.$msg.')');
						}
					}
				}
			}
		}
	}

	# then check additional search-dirs
	if((scalar(@found) eq 0) && ($additional ne '')) {
		my @additionals = split(',', $additional);
		for my $tmp (@additionals) {
			$bla=$tmp.'/'.$rel;
			if($s[0]->cwd($bla) && ($s[0]->code eq $CODE_CMD_OK)) {
				$bla=$s[0]->pwd();
				push @found,$bla;
				if($gimmemode ne 1) {
					irc_msg($irc_msgs,sprintf('[%s] (additional searchdir) found %s',$site[1],$bla));
				} else {
					if($found_rels eq '') {
						lock($first_rel);
						if($first_rel eq '' and $bla=~/^.*\/([^\/]+[(]*[0-9]{4}[)]*\-.{2,9})$/i) {
							$first_rel=$1;
							debug_msg($site.' additional: found '.$first_rel);
						}
						my $use_rel = $first_rel;
						$use_rel =~ s/([()]+)/\\$1/g;
						if($first_rel ne '' and $bla=~/^.+$use_rel$/i) {
							$found_rels=$bla;
							debug_msg($site.' additional: added '.$bla);
						}
					}
				}
			}
			else {
				my $msg = get_message($s[0]);
				if(!($msg=~/$error_msg1/i || $msg=~/$error_msg2/i)) {
					debug_msg($site.': cannot change to additional searchdir: '.$bla.' ('.$msg.')');
				}
			}
		}
	}

	# then check site-dupe
	if($gimmemode ne 1) {
		if(scalar(@found) eq 0) {
			my $result=$s[0]->site(sprintf('DUPE %s',$rel));
			my @out=$s[0]->message();
			for my $line (@out) {
				if($line=~/^ ([0-9]{4,8} [^ ]+)/i) {
					$bla=$1;
					last if(scalar(@found) eq 10);

					if(scalar(grep(/^$bla/,@found)) eq 0)
					{
						push @found,$bla;
						irc_msg($irc_msgs,sprintf('[%s] (site dupe) found in log %s',$site[1],$bla));
					}
				}
			}
		}
	}

	if(scalar(@found) eq 0) {
		if($gimmemode ne 1) {
			irc_msg($irc_msgs,sprintf('[%s] nothing found (%s secs)',$site[1], stop_timer($key, 1)));
		}
	}
	disconnect($s[0],$site[1],0,0,0);

	return $found_rels;
}

# ------------------------------------------------------------------

# starts threads to search a rel on all sites (presites + dumpsites + external sources)
sub search_rel {
	my $rel = shift;
	my $site = shift;
	my $use_irc_conn = shift;
	my $exclude = shift;
	my $gimmemode = shift;

	if(length($rel)<=6) {
		irc_msg($irc_msgs,sprintf('[SEARCH] parameter %s is too short',$rel));
		return 0;
	}

	my ($res, $msg, @rows) = conquery_db($site ne '' ? "select upper(site),sorted_mp3,today_dir,additional_searchdirs from sites where upper(status)='UP' and upper(site)!=upper('$exclude') and logins>0 and upper(site)=upper('$site')" : 
		"select upper(site),sorted_mp3,today_dir,additional_searchdirs from sites where upper(status)='UP' and upper(site)!=upper('$exclude') and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[SEARCH] no sites found');
		return 0;
	}

	if(1) {
		lock($first_rel);
		$first_rel='';
	}

	# final hash, holds results
	my %found_rels;

	# archive_search
	my %archive_search = search_archive(1, $site, $use_irc_conn, ($rel));
	if($gimmemode eq 1 && scalar(keys(%archive_search))>0) {
		for my $rel (keys(%archive_search)) {
			my $arch_site = $archive_search{$rel};

			if($rel=~/^(\/.*)\/([^\/]+)\/?$/i) {
				my $path = $1;
				my $real_rel = $2;

				# set found archive-rel as first one
				if($first_rel eq '') {
					$first_rel=$real_rel;
				}

				# add unique archive-rels to results-list
				if($real_rel eq $first_rel) {
					$found_rels{$arch_site}=$rel;
				}
			}
		}
	}

	if($gimmemode eq 1) {
		irc_msg($irc_msgs,'[SEARCH] started (that can take some minutes)');
	} else {
		irc_msg($irc_msgs,'[SEARCH] started');
	}

	my $key1 = start_timer('search_rel');
	my %threads;

	for my $out (@rows) {
		my ($site, $sorted, $today, $additional) = @$out;
		my $in_arch = (exists($found_rels{$site}) && $found_rels{$site} ne '') ? 1 : 0;
		if($in_arch eq 1) {
			debug_msg('site-search: skipping '.$site);
		}
	
		# if we already have a match from the archive-search - skip that site
		if($gimmemode eq 0 || $in_arch eq 0) {
			my $thread = threads->create('search_rel_on_site',$site,$sorted,$today,$additional,$rel,$gimmemode,$use_irc_conn);
			$threads{$site}=$thread;
		}
	}
	sleep(3);

	for my $sitename (keys %threads) {
		my $result=$threads{$sitename}->join();
		if($result ne '') {
			$found_rels{$sitename}=$result;
		}
	}

	my $time = stop_timer($key1, 1);
	if($gimmemode ne 1) {
		irc_msg($irc_msgs,sprintf('[SEARCH] finished (%s secs)', $time));
	} else {
		if($first_rel ne '') {
			irc_msg($irc_msgs,sprintf('[SEARCH] finished (%s secs), found %s sources (%s) for %s',$time, scalar(keys(%found_rels)),join(', ',keys(%found_rels)),$first_rel));
		} else {
			irc_msg($irc_msgs,sprintf('[SEARCH] nothing found (%s secs)', $time));
		}
	}

	if(1) {
		lock($first_rel);
		if($gimmemode eq 1) {
			$found_rels{'first_rel'}=$first_rel;
		}
		$first_rel='';
	}

	return ($gimmemode eq 1)?%found_rels:1;
}

# ------------------------------------------------------------------

# show sites with a given group
sub search_affils {
	my $group = shift;
	my $use_irc_conn = shift;
	my @sites=();

	my ($res, $msg, @rows) = conquery_db("select site from sites where affils LIKE '%$group%' order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[STATUS] group not found');
		return 0;
	}

	for my $row (@rows) {
		my ( $site ) = @$row;
		push @sites,$site;
	}
	
	irc_msg($irc_msgs,sprintf('Group %s affils on the following site(s): %s',$group,join(', ',@sites)));
	return 1;
}

# ------------------------------------------------------------------

# show locations for all sites
sub show_locations {
	my $use_irc_conn = shift;

	my ($res, $msg, @rows) = conquery_db("select site,location from sites where presite=1 order by site");
	if (!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
                irc_msg($irc_msgs,'[STATUS] no locations found');
                return 0;
        }

	irc_msg($irc_msgs,sprintf('Showing location of all presites:'));

	for my $row (@rows) {
		my @out = @$row;

		if($out[1] eq "") {
			irc_msg($irc_msgs,sprintf('%s - no location set',$out[0]));
		} else {
			irc_msg($irc_msgs,sprintf('%s - %s',$out[0],$out[1]));
		}
	}
	return 1;
}

# ----------------------------------------------------------------------------------------------

# show details for a added site
sub show_site {
	my $site = shift;
	my $use_irc_conn = shift;

	my ($res, $msg, @rows) = conquery_db("select site,sitename,bnc,prepath,precommand,ssl_status,status,speed_index,dump,dump_path,presite,today_dir,sorted_mp3,logins,source_sites,additional_searchdirs,archive,affils,location,speed,siteops from sites where upper(site)='$site'");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[STATUS] no sites found');
		return 0;
	}

	for my $row (@rows) {
		my @out = @$row;

		irc_msg($irc_msgs,sprintf('[%s] Sitename: %s, Status: %s, SSL: %s, MaxLogins: %s',$out[0],$out[1],$out[6],$out[5],$out[13]));
		irc_msg($irc_msgs,sprintf('[%s] Location: %s, Speed: %s, Siteops: %s',$out[0],$out[18],$out[19],$out[20]));
		irc_msg($irc_msgs,sprintf('[%s] Affils: %s',$out[0],$out[17]));
		irc_msg($irc_msgs,sprintf('[%s] Presite: %s, PrePath: %s, PreCommand: %s',$out[0],$out[10],$out[3],$out[4]));
		if($out[8] eq 1) {
			irc_msg($irc_msgs,sprintf('[%s] Dump: %s, DumpPath: %s',$out[0],$out[8],$out[9]));
		}
		if($out[16] eq 1) {
			irc_msg($irc_msgs,sprintf('[%s] Site is an archive-site: %s',$out[0],$out[16]));
		}
		if((!$out[11] eq "") && (!$out[12] eq "")) {
			irc_msg($irc_msgs,sprintf('[%s] Today-Dir: %s, SortedDaydir: %s',$out[0],$out[11],$out[12]));
		}
		if(!$out[15] eq "") {
			irc_msg($irc_msgs,sprintf('[%s] Additional Search Dirs: %s', $out[0], $out[15]));
		}
		if($out[10] eq 1) {
			irc_msg($irc_msgs,sprintf('[%s] BNC\'s: %s',$out[0],$out[2]));
		} else {
			irc_msg($irc_msgs,sprintf('[%s] BNC\'s: %s',$out[0],'hidden'));
		}
		irc_msg($irc_msgs,sprintf('[%s] Speed Index (important for Spreading): %s',$out[0],$out[7]));
		irc_msg($irc_msgs,sprintf('[%s] SourceSites (important for Spreading/gimme): %s',$out[0],$out[14]));
	}

	return 1;
}

# ------------------------------------------------------------------

# show status of all added sites
sub show_sites {
	my $use_irc_conn = shift;

	my ($res, $msg, @rows) = conquery_db("select upper(site),case when (upper(status)='UP') then 1 else 0 end,dump,case when (presite=0 and dump=0) then 1 else 0 end as source,presite,archive from sites where logins>0 order by status,site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[STATUS] no sites found');
		return 0;
	}
	my @pre_up=();
	my @pre_dn=();
	my @dump_up=();
	my @dump_dn=();
	my @source_up=();
	my @source_dn=();
	my @archive_up=();
	my @archive_dn=();
	for my $out (@rows) {

		my ($site, $stat, $dump, $source, $presite, $archive) = @$out;

		if($presite eq 1) {
			if($stat eq 1) {
				push @pre_up,$site;
			}
			else {
				push @pre_dn,$site;
			}
		}
		if($dump eq 1) {
			if($stat eq 1) {
				push @dump_up,$site;
			}
			else {
				push @dump_dn,$site;
			}
		}
		if($source eq 1) {
			if($stat eq 1) {
				push @source_up,$site;
			}
			else {
				push @source_dn,$site;
			}
		}
		if($archive eq 1) {
			if($stat eq 1) {
				push @archive_up,$site;
			}
			else {
				push @archive_dn,$site;
			}
		}
	}

	irc_msg($irc_msgs,sprintf('[STATUS] PRESITES: UP (%s): %s - DOWN (%s): %s',
		scalar(@pre_up),join(', ',@pre_up),scalar(@pre_dn),join(', ',@pre_dn)));
	irc_msg($irc_msgs,sprintf('[STATUS] DUMPS: UP (%s): %s - DOWN (%s): %s',
		scalar(@dump_up),join(', ',@dump_up),scalar(@dump_dn),join(', ',@dump_dn)));
	irc_msg($irc_msgs,sprintf('[STATUS] SOURCE: UP (%s): %s - DOWN (%s): %s',
		scalar(@source_up),join(', ',@source_up),scalar(@source_dn),join(', ',@source_dn)));
	irc_msg($irc_msgs,sprintf('[STATUS] ARCHIVE: UP (%s): %s - DOWN (%s): %s',
		scalar(@archive_up),join(', ',@archive_up),scalar(@archive_dn),join(', ',@archive_dn)));

	return 1;
}

# ------------------------------------------------------------------

# check all bncs of all sites
sub check_all_sites {
	my $use_irc_conn = shift;

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[STATUS] no sites found');
		return 0;
	}

	my $key1 = start_timer('check_all_sites');

	irc_msg($irc_msgs,'[STATUS] testing all bncs of all sites');

	my @threads=();
	for my $out (@rows) {
		my $thread  = threads->create('get_site_data',@$out[0], 1, $use_irc_conn,1,1);
		push @threads,$thread;
	}

	sleep(3);

	for my $thread (@threads) {
		my $res=$thread->join();
	}

	irc_msg($irc_msgs,sprintf('[STATUS] done (%s secs)', stop_timer($key1, 1)));
	return 1;
}

# ------------------------------------------------------------------

# check a bnc of a site - check if all dir's are correctly (predir / dump dir)
sub check_site_bnc {
	my $bnc = shift;
	my $site = shift;
	my $ssl = shift;
	my $prepath = shift;
	my $use_irc_conn = shift;
	my $login=shift;
	my $real_passwd=shift;
	my $fast_mode=shift;
	my $dump_path = shift;

	$bnc=~/([^ ]+):([0-9]{2,5})/;
	my $ip=$1;
	my $port=$2;

	# short mode for glftpd
	my $passwd=sprintf('-%s',$real_passwd);

	my $status=-1;
	my $result='';
	my $timer_key = start_timer();
	if(my $ftp = Net::FTP->new($ip,Timeout => $ftp_timeout, Port => $port, Passive => 1, Debug => $ftp_debug, LocalAddr => $local_address, SSL_verify_mode => 0))
	{
		my $ok = 1;
		if($ssl eq 'ssl') {
			if (!$ftp->starttls()) {
				$ok = 0;
				$result = sprintf('error switching to SSL (%s)',get_message($ftp));
			}
		}
		
		if(($ok eq 1) and (!$ftp->login($login,$passwd))) {
			# seems the site doesnt support short-login mode ... use default mode
			if($ftp = Net::FTP->new($ip,Timeout => $ftp_timeout, Port => $port, Passive => 1, Debug => $ftp_debug, LocalAddr => $local_address, SSL_verify_mode => 0)) {
				if($ssl eq 'ssl') {
					if (!$ftp->starttls()) {
						$ok = 0;
						$result = sprintf('error switching to SSL (%s)',get_message($ftp));
					}
				}
				                                         
				if(!$ftp->login($login,$real_passwd)) {
					$result=sprintf('error login in (%s)',get_message($ftp));
					$ok = 0;
				}
				else {
					$ok = 1;
				}
			}
			else {
				$result='error connecting (timeout, unreachable)';
				$ok = 0;
			}
		}

		if($ok eq 1) {
			if(($prepath =~ /\w/) or ($dump_path =~ /\w/)) {
				my $ok = 0;
				if($dump_path =~ /\w/) {
					if(!$ftp->cwd($dump_path) || ($ftp->code ne $CODE_CMD_OK)) {
						$result=sprintf('cannot change to directory %s (%s)',$dump_path,get_message($ftp));
					}
					else {
						$result='site working, connected, changed to dump-dir';
						$ok = 1;
					}
				}
				if($prepath =~ /\w/) {
					if(!$ftp->cwd($prepath) || ($ftp->code ne $CODE_CMD_OK)) {
						$result=sprintf('cannot change to directory %s (%s)',$prepath,get_message($ftp));
					}
					else {
						$result='site working, connected, changed to predir';
						$ok = 1;
					}
				}
				if($ok eq 1) {
					$status=stop_timer($timer_key, 1);
				}
			}
			else {
				$result='site working, connected';
				$status=stop_timer($timer_key, 1);
			}
			$ftp->quit();
		}
	}
	else {
		$result='error connecting (timeout, unreachable)';
	}
	if($fast_mode eq 0) {
		if($prepath =~ /\w/) {
			irc_msg($irc_msgs,sprintf('[%s] checking bnc %s (%s): %s (%s secs)',$site,$bnc,$ssl,$result,$status));
		} else {
			irc_msg($irc_msgs,sprintf('[%s] checking bnc: %s (%s secs)',$site,$result,$status));
		}
	}
	return ($status,$result);
}

# ------------------------------------------------------------------

# get site-details to connect to a site - if wanted - start bnc test
sub get_site_data {
	my $site = shift;
	my $do_login_test = shift;
	my $use_irc_conn = shift;
	my $fast_mode=shift;
	my $allow_dump_or_source = shift;

	my %new;
	my @sorted=();
	my $query='';
	my $status='down';

	my ($res, $msg, @rows) = conquery_db("select site,bnc, case when (lower(ssl_status) like '%auth%') then 'ssl' else 'nossl' end, prepath,login,passwd,precommand,presite,dump,dump_path,case when (presite=0 and dump=0) then 1 else 0 end as source from sites where upper(site)='$site'");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,sprintf('[SQL] unknown sitename %s',$site));
		return 0;
	}

	my @out;
	for my $out2 (@rows) {
		@out = @$out2;
	}

	my ($site_, $bnc, $ssl, $prepath, $login, $passwd, $precmd, $presite, $dump, $dump_path, $source) = @out;

	if(($allow_dump_or_source ne 1) && ( (($dump eq 1) && ($presite eq 0)) || ($source eq 1))) {
			irc_msg($irc_msgs, sprintf('[%s] set as internal source or dump, command not allowed for that site',$site_));
			return 0;
	}

	unless($bnc =~ /\w/) {
		irc_msg($irc_msgs, sprintf('[%s] no bnc\'s found',$site_));
		return 0;
	}

	if($presite eq 1) {
		unless($prepath =~ /\w/) {
			irc_msg($irc_msgs, sprintf('[%s] no prepath set',$site_));
			return 0;
		}
		unless($precmd =~ /\w/) {
			irc_msg($irc_msgs, sprintf('[%s] no PreCommand set',$site_));
			return 0;
		}
	}

	if($dump eq 1) {
		unless($dump_path =~ /\w/) {
			irc_msg($irc_msgs, sprintf('[%s] is marked as dump-site, but no dump-path set',$site_));
			return 0;
		}
	}

	unless($login =~ /\w/ && $passwd =~ /\w/) {
		irc_msg($irc_msgs, sprintf('[%s] no login and/or passwd set',$site_));
		return 0;
	}

	@out=();
	while($bnc=~/([^ ,]+):([0-9]{2,5})/g) {
		my $ip=$1;
		my $port=$2;
		push @out, sprintf('%s:%s',$ip,$port);
	}

	my @reasons=();
	$status='down';
	if($do_login_test eq 1) {

		my $timerkey = start_timer('login_test');

		if($fast_mode eq 0) {
			if($presite eq 1) {
				irc_msg($irc_msgs, sprintf('[%s] found bnc\'s (%s) (%s)',$site_,scalar(@out),join(', ',@out)));
			} else {
				irc_msg($irc_msgs, sprintf('[%s] found bnc\'s (%s)',$site_,scalar(@out)));
			}
		}
		for my $bnc (@out) {
			(my $result,my $reason)=check_site_bnc($bnc,$site_,$ssl,$prepath,$use_irc_conn,$login,$passwd,$fast_mode,$dump_path);
			$new{$bnc}=$result>0?100-$result:$result;
			if($result>=0) {
				$status='up';
			} else {
				if(exists_in_arr($reason, @reasons) eq 0) {
					push @reasons,$reason;
				}
			}
		}

		my $secs = stop_timer($timerkey, 1);

		@sorted = sort { $new{$b} <=> $new{$a} } keys %new;

		for my $bnc (@sorted) {
			if($bnc=~/([^ ]+):([0-9]{2,5})/) {
				$query.=sprintf('%s , ',$bnc);
			}
		}
		if($fast_mode eq 0) {
			if($presite eq 1) {
				irc_msg($irc_msgs, sprintf('[%s] %s (%s secs) - bnc results (fastest first): %s',$site_,$status,$secs,$query));
			} else {
				irc_msg($irc_msgs, sprintf('[%s] %s (%s secs)',$site_,$status,$secs));
			}
		}
		else {
			if($status eq 'up') {
				irc_msg($irc_msgs, sprintf('[%s] %s (%s secs)',$site_,$status,$secs));
			}
			else {
				irc_msg($irc_msgs, sprintf('[%s] %s (%s secs) - %s',$site_,$status,$secs,join(', ',@reasons)));
			}
		}

		condo_db(sprintf("update sites set bnc='%s',status='%s' where upper(site)='%s'",$query,$status,$site_));
	}

	return ($bnc,$site_,$ssl,$prepath,$login,$passwd,$precmd,$dump,$dump_path);
}

# ------------------------------------------------------------------

# returns n-tht bnc of a list
sub get_site_bnc {
	my $bnc_list = shift;
	my $index = shift || 0;

	$bnc_list=~/([^ ]+):([0-9]{2,5})/;
	my $ip=$1;
	my $port=$2;

	return ($ip, $port);
}

# ------------------------------------------------------------------

# connect to a site - change to predir or dump dir or other given directory
sub connect_to_site {
	my $bnc_list = shift;
	my $site = shift;
	my $ssl = shift;
	my $prepath = shift;
	my $login=shift;
	my $passwd=shift;
	my $encrypt=shift;
	my $use_high_timeout = shift || 0;

	my ($ip, $port) = get_site_bnc($bnc_list, 0);

	if(my $ftp = Net::FTP->new($ip,Timeout => ($use_high_timeout eq 0 ? $ftp_timeout: $ftp_timeout_high), Port => $port, Passive => 1, Debug => $ftp_debug, LocalAddr => $local_address, SSL_verify_mode => 0))
	{
		if($ssl eq 'ssl') {
			if(!$ftp->starttls()) {
				return (0,sprintf('error switching to SSL (%s)',get_message($ftp)));
			}
		}
		
		if(!$ftp->login($login,$passwd)) {
			return (0,sprintf('error login in (%s)',get_message($ftp)));
		}
		else {
			my $msg = get_message($ftp);
			if($prepath ne 0) {
				if(!$ftp->cwd($prepath) || ($ftp->code ne $CODE_CMD_OK)) {
					return (0,sprintf('cannot change to directory %s (%s)',$prepath,get_message($ftp)));
					$ftp->quit();
				}
				return ($ftp,sprintf('%s:%s',$ip,$port),$msg)
			}
			return ($ftp,sprintf('%s:%s',$ip,$port),$msg)
		}
	}
	return (0,'error connecting (timeout, unreachable)');
}

# ------------------------------------------------------------------

# list content of predirs of all sites
sub show_predirs {
	my $use_irc_conn = shift;

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(status)='UP' and presite=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[PRELIST] no sites found');
		return 0;
	}

	my $key1 = start_timer('list_all_predirs');
	irc_msg($irc_msgs,'[PRELIST] checking predirs');

	my %site_rels;
	# get entries of predirs of all sites
	for my $out (@rows) {
		my $site = @$out[0];
		@{$site_rels{$site}} = ();
		my $newerr=0;
		my $error=0;
		my @site=get_site_data($site,0,$use_irc_conn,0,0) or $error=1;
		if($error || scalar(@site) eq 1) {
			irc_msg($irc_msgs, sprintf('[%s] an error occured',$site));
			next;
		}
		my @s=connect_to_site($site[0],$site[1],$site[2],$site[3],$site[4],$site[5],0,0);
		if($s[0] eq 0) {
			irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site[1],$s[1]));
			next;
		}
		my @list=dirlist($s[0]) or $newerr=1;
		if($newerr) {
			irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site[1],$site[3],get_message($s[0])));
			next;
		}

		for my $line (@list) {
			$line=~ s/\n//g;
			$line=~ s/\r//g;
			if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+)$/i) {
				my $sub_dir=$1;
				my $sub_siz=$2;
				my $sub_fil=$3;
				# match only directories
				if($sub_dir=~/^d/i && $sub_fil ne '.' && $sub_fil ne '..') {
					push(@{$site_rels{$site}}, $sub_fil);
				}
			}
		}
	}

	# ok - we have a list of all sites with all rels - lets sort it
	my %releases;
	for my $sitename (keys %site_rels) {
		for my $release (@{$site_rels{$sitename}}) {
			if(!exists($releases{$release})) {
				@{$releases{$release}} = ($sitename);
			}
			else {
				push(@{$releases{$release}}, $sitename);
			}
		}
	}

	for my $release (keys %releases) {
		irc_msg($irc_msgs,sprintf('[PRELIST] %s on %s',$release, join(', ', @{$releases{$release}})));
	}

	irc_msg($irc_msgs,sprintf('[PRELIST] Done (%s secs)',stop_timer($key1, 1)));
	return 1;
}

# ------------------------------------------------------------------

# list content of predir
sub show_predir {
	my $site = shift;
	my $use_irc_conn = shift;
	my $rel = shift || '';
	my $search = shift || '';
	my $return_list = shift || 0;

	if($return_list eq 1) {
		$rel = '';
		$search = '';
	}

	my $newerr=0;
	my $error=0;
	my @site=get_site_data($site,0,$use_irc_conn,0,0) or $error=1;
	if($error || scalar(@site) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site));
		return 0;
	}
	my @s=connect_to_site($site[0],$site[1],$site[2],$site[3],$site[4],$site[5],0,0);
	if($s[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site[1],$s[1]));
		return 0;
	}

	if($rel ne '') {
		if(!$s[0]->cwd($rel) || ($s[0]->code ne $CODE_CMD_OK)) {
			irc_msg($irc_msgs, sprintf('[%s] cannot change to directory %s (%s)',$site[1],$site[3].'/'.$rel,get_message($s[0])));
			disconnect($s[0],$site[1],0,0,$use_irc_conn);
			return 0;
		}
	}

	my $first=0;
	my @list=dirlist($s[0]) or $newerr=1;
	if($newerr) {
		irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site[1],$site[3],get_message($s[0])));
	}
	else {

		if($return_list eq 1) {
			return @list;
		}

		if($search eq ''){
			if($return_list eq 0) {
				irc_msg($irc_msgs, sprintf('[%s] listing directory %s%s',$site[1],$site[3],($rel ne '')?('/'.$rel):''));
			}
			$first=1;
			for my $line (@list) {
				$line=~ s/\n//g;
				$line=~ s/\r//g;
				if($first ne 1) {
					irc_msg($irc_msgs, sprintf('[%s] %s',$site[1],$line));
				}
				$first=0;
			}
		}
		else {
			my $counter = 0;
			irc_msg($irc_msgs, sprintf('[%s] listing directory %s%s',$site[1],$rel));
			$first=1;
			for my $line (@list) {
				$line=~ s/\n//g;
				$line=~ s/\r//g;
				if($first ne 1) {
					if($line=~/$search/){
						if($counter < 20){
							irc_msg($irc_msgs, sprintf('[%s] %s',$site[1],$line));
						}
						if($counter == 20){
							irc_msg($irc_msgs, sprintf('[%s] maximum output reached (20 lines)',$site[1]));
						}
						$counter++;
					}
				}
				$first=0;
			}
		}
	}

	disconnect($s[0],$site[1],0,0,$use_irc_conn);
	return 1;
}

# ------------------------------------------------------------------

# gets content of a given directory on site
sub get_predir_content {
	my $site = shift;
	my $use_irc_conn = shift;
	my @list = show_predir($site, $use_irc_conn, '','', 1);

	my @new_list;
	for my $line (@list) {
		$line=~ s/\n//g;
		$line=~ s/\r//g;
		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+)$/i) {
			my $sub_dir=$1;
			my $sub_siz=$2;
			my $sub_fil=$3;
			# match only directories
			if($sub_dir=~/^d/i && $sub_fil ne '.' && $sub_fil ne '..' && length($sub_fil)>10) {
				push(@new_list, $sub_fil);
			}
		}
	}
	return @new_list;
}

# ------------------------------------------------------------------

# takes a rel - fxps from site1 to site2, if finished from site2 to site3 .. and so on
# can fxp complete predirs too ... 
sub chain_fxp {
	my $rel = shift;
	my $use_irc_conn = shift;
	my @sites = @_;

	my $predir_sync = ($rel eq 'chainfxp_predirs') ? 1 : 0;

	if($predir_sync eq 0 && length($rel)<=10) {
		irc_msg($irc_msgs,sprintf('[FXP] release %s seems to not match releasing/naming-rules (too short)',$rel));
		return 0;
	}

	for(my $i=0;$i<scalar(@sites);$i++) {
		$sites[$i]=uc($sites[$i]);
	}

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(status)='UP' and presite=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[DEL] no sites found');
		return 0;
	}

	my %upsites;
	for my $out (@rows) {
		$upsites{@$out[0]}=0;
	}

	for my $sitename (@sites) {
		if(!exists($upsites{$sitename})) {
			irc_msg($irc_msgs,sprintf('[FXP] site doesnt exist or isnt presite: %s',$sitename));
			return 0;
		}
		$upsites{$sitename}++;
		if($upsites{$sitename}>1) {
			irc_msg($irc_msgs,sprintf('[FXP] site found twice in chain: %s',$sitename));
			return 0;
		}
	}

	irc_msg($irc_msgs,sprintf('[FXP] starting fxp chain: %s',join(' -> ',@sites)));

	for(my $i=0;$i<scalar(@sites)-1;$i++) {
		my $site1=$sites[$i];
		my $site2=$sites[$i+1];
		my $result;

		if($predir_sync eq 1) {
			my @rels = get_predir_content($site1, $use_irc_conn);
			if(scalar(@rels) eq 0) {
				irc_msg($irc_msgs,sprintf('[FXP] %s to %s: nothing to do', $site1, $site2));
			}
			else {
				irc_msg($irc_msgs,sprintf('[FXP] fxp %s directories from %s to %s', scalar(@rels), $site1, $site2));
				for my $rel (@rels) {
					$result = fxp_rel($site1, $site2, $rel, $use_irc_conn, 1, '', '', 0, 0, 0);
					if($result ne 1) {
						irc_msg($irc_msgs,'[FXP] fxp chain broken, aborting');
						return 0;
					}
				}
			}
		}
		else {
			$result = fxp_rel($site1, $site2, $rel, $use_irc_conn, 1, '', '', 0, 0, 0);
			if($result ne 1) {
				irc_msg($irc_msgs,'[FXP] fxp chain broken, aborting');
				return 0;
			}
		}
	}
	irc_msg($irc_msgs,'[FXP] chain finished');
	return 1;
}

# ------------------------------------------------------------------

# takes a rel - fxps from site1 to site2, if finished from site1 to site3 .. and so on
# can fxp complete predirs too ... 
sub spread_fxp {
	my $rel = shift;
	my $use_irc_conn = shift;
	my @sites = @_;

	my $predir_sync = ($rel eq 'chainfxp_predirs') ? 1 : 0;

	if($predir_sync eq 0 && length($rel)<=10) {
		irc_msg($irc_msgs,sprintf('[FXP] release %s seems to not match releasing/naming-rules (too short)',$rel));
		return 0;
	}

	for(my $i=0;$i<scalar(@sites);$i++) {
		$sites[$i]=uc($sites[$i]);
	}

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(status)='UP' and presite=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[DEL] no sites found');
		return 0;
	}

	my %upsites;
	for my $out (@rows) {
		$upsites{@$out[0]}=0;
	}

	for my $sitename (@sites) {
		if(!exists($upsites{$sitename})) {
			irc_msg($irc_msgs,sprintf('[FXP] site doesnt exist or isnt presite: %s',$sitename));
			return 0;
		}
		$upsites{$sitename}++;
		if($upsites{$sitename}>1) {
			irc_msg($irc_msgs,sprintf('[FXP] site found twice in chain: %s',$sitename));
			return 0;
		}
	}

	my $source = $sites[0];
	my @out;
	my @new_sites;
	for(my $i=1;$i<scalar(@sites);$i++) {
		push(@new_sites, $sites[$i]);
		push(@out, sprintf('%s -> %s', $source, $sites[$i]));
	}
	@sites = @new_sites;
	irc_msg($irc_msgs,sprintf('[FXP] starting fxp chain: %s', join(', ', @out)));

	my @rels;
	if($predir_sync eq 1) {
		@rels = get_predir_content($source, $use_irc_conn);
		if(scalar(@rels) eq 0) {
			irc_msg($irc_msgs,sprintf('[FXP] %s to %s: nothing to do', $source, join(', ', @sites)));
			irc_msg($irc_msgs,'[FXP] chain finished');
			return 1;
		}
	}

	for(my $i=0;$i<scalar(@sites);$i++) {
		my $site1=$source;
		my $site2=$sites[$i];
		my $result;

		if($predir_sync eq 1) {
			irc_msg($irc_msgs,sprintf('[FXP] fxp %s directories from %s to %s', scalar(@rels), $site1, $site2));
			for my $rel (@rels) {
				$result = fxp_rel($site1, $site2, $rel, $use_irc_conn, 1, '', '', 0, 0, 0);
				if($result ne 1) {
					irc_msg($irc_msgs,'[FXP] fxp chain broken, aborting');
					return 0;
				}
			}
		}
		else {
			$result = fxp_rel($site1, $site2, $rel, $use_irc_conn, 1, '', '', 0, 0, 0);
			if($result ne 1) {
				irc_msg($irc_msgs,'[FXP] fxp chain broken, aborting');
				return 0;
			}
		}
	}
	irc_msg($irc_msgs,'[FXP] chain finished');
	return 1;
}


# ------------------------------------------------------------------

# fxp a release/file from one site to another one - use predirs or other given dirs as source
# different output - synchronized progress bar - or detailed file-list
# return values:
# 1 = success - release is complete on destination
# 0 = error, release is incomplete - but login/list etc worked
# sitename = global error on site - out of diskspace / error listing directory etc
sub fxp_rel {
debug_msg('i am in sub fxp_rel');
	my $site1 = shift;
	my $site2 = shift;
	my $rel = shift;
	my $use_irc_conn = shift;
	my $silent_mode=shift;
	my $from_dir=shift;
	my $to_dir=shift;
	my $spread_mode = shift || 0;
	my $no_start_end_msgs = shift || 0;
	my $ignore_incomplete = shift || 0;

	if($silent_mode eq 0) {
		$no_start_end_msgs = 0;
	}

	if(length($rel)<=10) {
		irc_msg($irc_msgs,sprintf('[FXP] release %s seems to not match releasing/naming-rules (too short)',$rel));
		return 0;
	}


	my $new_name = '';
	if($rel=~/^([^:]+):([^:]+)$/i) {
		$rel = $1;
		$new_name = $2;
		debug_msg('renaming mode: '.$rel.' should be renamed to '.$new_name.' on destination site');
	}

	my %files;
	my @sorted;
	my $ssl1 = 0;
	my $ssl2 = 0;

	my $dump_mode=0;
	if(length($from_dir)>0 && length($to_dir)>1) {
		$dump_mode=1;
		debug_msg(sprintf('dump_mode %s, from: %s/%s, to: %s/%s',$dump_mode,$site1,$from_dir,$site2,$to_dir));
	}

	# if in spread-mode - but a reset was called -> exit!
	if($spread_mode eq 1) {
		if	($doingspread eq 0){
			return 0;
		}
	}

	my $key1 = start_timer('fxp_rel'.$site1.$site2);

	my $error=0;
	my @site1=get_site_data($site1,0,$use_irc_conn,0,$dump_mode) or $error=1;
	if($error || scalar(@site1) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site1));
		return $site1;
	}
	my @site2=get_site_data($site2,0,$use_irc_conn,0,$dump_mode) or $error=1;
	if($error || scalar(@site2) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site2));
		return $site2;
	}

	my @s1=connect_to_site($site1[0],$site1[1],$site1[2],$site1[3],$site1[4],$site1[5],1,0);
	if($s1[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site1[1],$s1[1]));
		return $site1;
	}

	my @s2=connect_to_site($site2[0],$site2[1],$site2[2],$site2[3],$site2[4],$site2[5],1,0);
	if($s2[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site2[1],$s2[1]));
		if($s1[0] ne 0) {
			disconnect($s1[0],$site1[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		}
		return $site2;
	}

	if($silent_mode eq 0 && $dump_mode eq 0) {
		irc_msg($irc_msgs,sprintf('[%s] && [%s] connected (%s secs)',$site1[1],$site2[1], stop_timer($key1, 1)));
	}


	if($dump_mode eq 1) {
		if($from_dir ne '') {
			if(!$s1[0]->cwd($from_dir) || ($s1[0]->code ne $CODE_CMD_OK)) {
				irc_msg($irc_msgs,sprintf('[%s] cannot change to source directory %s (%s)',$site1[1],$from_dir,get_message($s1[0])));
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
				return 0;
			}
		}
		if($to_dir ne '') {
			if(!$s2[0]->cwd($to_dir) || ($s2[0]->code ne $CODE_CMD_OK)) {
				irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$to_dir,get_message($s2[0])));
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
				return 0;
			}
		}
	}

	my $newerr = 0;
	my @list1=dirlist($s1[0]) or $newerr=1;
	if($newerr) {
		$newerr = 0;
		if ($site1[2] ne 'ssl') {
			irc_msg($irc_msgs, sprintf('[%s] cannot list directory! (%s)',$site1[1],get_message($s1[0])));
			disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
			return $site1;
		}

		debug_msg(sprintf('[%s] cannot list directory, switching to ssl',$site1[1]));

		disconnect($s1[0],$site1[1],0,0,0);
		$ssl1 = 1;
		sleep(1);
		@s1=connect_to_site($site1[0],$site1[1],$site1[2],$site1[3],$site1[4],$site1[5],0,0); #verschlüsselt!
		if($s1[0] eq 0) {
			irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site1[1],$s1[1]));
			return $site1;
		}
		if($dump_mode eq 1) {
			if($from_dir ne '') {
				if(!$s1[0]->cwd($from_dir) || ($s1[0]->code ne $CODE_CMD_OK)) {
					irc_msg($irc_msgs,sprintf('[%s] cannot change to source directory %s (%s)',$site1[1],$from_dir,get_message($s1[0])));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return 0;
				}
			}
		}
		@list1=dirlist($s1[0]) or $newerr=1;
		if($newerr) {
			irc_msg($irc_msgs, sprintf('[%s] cannot list directory in either mode! (%s)',$site1[1],get_message($s1[0])));
			disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
			return $site1;
		}
	}

	my $found_dir='';
	my $found_siz='';
	my $found_rel='';
	my $directory=0;

	my $use_rel = $rel;
	$use_rel =~ s/([()]+)/\\$1/g;

	for my $line (@list1) {
		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+($use_rel).*$/i) {
			$found_dir=$1;
			$found_siz=$2;
			$found_rel=$3;
			if($found_dir=~/^d/i || $found_dir=~/^l/i) {
				$directory=1;
				if($dump_mode ne 1 && $no_start_end_msgs eq 0) {
					irc_msg($irc_msgs,sprintf('[%s] transfering release %s to %s',$site1[1],$found_rel,$site2[1]));
				}
				last;
			}
			else {
				$directory=0;
				if($dump_mode ne 1 && $no_start_end_msgs eq 0) {
					my ($sbytes,$sform)=format_bytes_line($found_siz);
					irc_msg($irc_msgs,sprintf('[%s] transfering %s (%s %s) to %s',$site1[1],$found_rel,$sbytes,$sform,$site2[1]));
				}
				last;
			}
		}
	}

	# renaming mode only allowed if a single file is transfered
	if($directory eq 1) {
		$new_name = '';
	}

	if($found_dir eq '') {
		irc_msg($irc_msgs,sprintf('[%s] no release/file matching %s found! (bad named?)',$site1[1],$rel));
		disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
		return $site1;
	}
	else {
		if($directory eq 1) {
			if(!$s1[0]->cwd($found_rel) || ($s1[0]->code ne $CODE_CMD_OK)) {
				irc_msg($irc_msgs,sprintf('[%s] cannot change to source directory %s (%s)',$site1[1],$found_rel,get_message($s1[0])));
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
				return $site1;
			}

			@list1=dirlist($s1[0]) or $newerr=1;
			if($newerr) {
				irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site1[1],$found_rel,get_message($s1[0])));
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
				return $site1;
			}

			my $completed=0;
			my $missing_files=0;
			my $site_tag='';
			my $sfv_here=0;
			my $nfo_here=0;
			my $anzahl=0;
			my $anzahl_total=0;
			my $sum=0;

			# directory einlesen
			for my $line (@list1) {
				if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+)$/i) {
					my $sub_dir=$1;
					my $sub_siz=$2;
					my $sub_fil=$3;
					if($sub_fil=~/\.mp3$/i || $sub_fil=~/\.sfv$/i ||  $sub_fil=~/\.zip$/i ||  $sub_fil=~/\.jpg$/i ||  $sub_fil=~/\.gif$/i ||  $sub_fil=~/\.nfo$/i || $sub_fil=~/\.cue$/i) {
						if($sub_dir=~/^\-/i && $sub_siz>0 and $sub_fil=~/^[^\.]/i) {
							$files{$sub_fil}=$sub_siz;
							$anzahl_total++;
						}
						if($sub_fil=~/\.mp3$/i) {
							$anzahl++;
							$sum+=$sub_siz;
						}
					}
					if($sub_fil=~/mp3-missing/i) {
						$missing_files++;
						$completed=0;
					}
					if($sub_fil=~/\.sfv$/i) {
						$sfv_here=1;
					}
					if($sub_fil=~/\.nfo$/i) {
						$nfo_here=1;
					}
				}
				if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+(.+)$/i) {
					my $sub_fil=$3;
					for my $reg_arr (@complet_tags) {
						my ($reg1,$reg2) = @$reg_arr;
						if($sub_fil=~/$reg1/ && $sub_fil=~/$reg2/) {
							$completed=1;
							$site_tag=$sub_fil;
						}
						last if($completed eq 1);
					}
				}
			}

			if($ignore_incomplete eq 0) {
				if($completed eq 0 || $missing_files ne 0 || $site_tag eq '' || $sfv_here eq 0 || $nfo_here eq 0 || $anzahl eq 0 || $sum eq 0)
				{
					if($site_tag ne '') {
						$site_tag='found';
					}
					else {
						$site_tag='not found';
					}
					irc_msg($irc_msgs, sprintf('[%s] %s is incomplete (mp3\'s: %s, size: %s, missing: %s, site_tag: %s, sfv: %s, nfo: %s) - aborting',
						 $site1[1],$found_rel, $anzahl, $sum, $missing_files, $site_tag, $sfv_here, $nfo_here));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return 0;
				}
			}

			if(!$s2[0]->cwd($found_rel) || ($s2[0]->code ne $CODE_CMD_OK)) {
				if(!$s2[0]->mkdir($found_rel)) {
					my $error_msg=get_message($s2[0]);
					if($silent_mode ne 1) {
						# unknown error
						if(!( ($s2[0]->code eq $CODE_FILE_EXISTS) || ($s2[0]->code eq $CODE_CANNOT_CREATE)) ) {
							irc_msg($irc_msgs,sprintf('[%s] cannot create destination directory %s (%s)',$site2[1],$found_rel,$error_msg));
						}
					}
					# global error
					if(($s2[0]->code eq $CODE_OUT_OF_SPACE)) {
						irc_msg($irc_msgs,sprintf('[%s] cannot create destination directory %s (%s)',$site2[1],$found_rel,$error_msg));
						disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
						return $site2;
					}
				}
				if(!$s2[0]->cwd($found_rel) || ($s2[0]->code ne $CODE_CMD_OK)) {
					irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$found_rel,get_message($s2[0])));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return $site2;
				}
			}

			$newerr = 0;
			my @list2=dirlist($s2[0]) or $newerr=1;

			if($newerr) {
				$newerr = 0;
				if ($site2[2] ne 'ssl') {
					irc_msg($irc_msgs, sprintf('[%s] cannot list directory! %s (%s)',$site2[1],$found_rel,get_message($s2[0])));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return $site2;
				}

				debug_msg(sprintf('[%s] cannot list directory, switching to ssl',$site2[1]));

				disconnect($s2[0],$site2[1],0,0,0);
				$ssl2 = 1;
				sleep(1);
				@s2=connect_to_site($site2[0],$site2[1],$site2[2],$site2[3],$site2[4],$site2[5],0,0); #verschlüsselt!
				if($s2[0] eq 0) {
					irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site2[1],$s2[1]));
					return $site2;
				}
				if($dump_mode eq 1) {
					if($to_dir ne '') {
						if(!$s2[0]->cwd($to_dir) || ($s2[0]->code ne $CODE_CMD_OK)) {
							irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$to_dir,get_message($s2[0])));
							disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
							return 0;
						}
					}
				}
				if(!$s2[0]->cwd($found_rel) || ($s2[0]->code ne $CODE_CMD_OK)) {
					irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$found_rel,get_message($s2[0])));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return $site2;
				}
				@list2=dirlist($s2[0]) or $newerr=1;
				if($newerr) {
					irc_msg($irc_msgs, sprintf('[%s] cannot list directory in either mode! %s (%s)',$site2[1],$found_rel,get_message($s2[0])));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return $site2;
				}
			}

			my $missing_files2=0;
			my $anzahl2=0;
			my $anzahl_total2=0;
			my $sum2=0;
			my $skipping=0;

			for my $line2 (@list2) {
				if($line2=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+)$/i) {
					my $sub_dir2=$1;
					my $sub_siz2=$2;
					my $sub_fil2=$3;
					if($sub_fil2=~/\.mp3$/i || $sub_fil2=~/\.sfv$/i ||  $sub_fil2=~/\.zip$/i ||  $sub_fil2=~/\.jpg$/i ||  $sub_fil2=~/\.gif$/i ||  $sub_fil2=~/\.nfo$/i || $sub_fil2=~/\.cue$/i) {
						$anzahl_total2++;

						# skip files that are already there - NO!!! resume!!!
						if(exists($files{$sub_fil2})) {
							$skipping++;
							delete($files{$sub_fil2});
						}

						if($sub_fil2=~/\.mp3$/i) {
							$anzahl2++;
							$sum2+=$sub_siz2;
						}
					}
					if($sub_fil2=~/mp3-missing/i) {
						$missing_files2++;
					}
				}
			}

			if(($anzahl eq $anzahl2 and $anzahl_total eq $anzahl_total2 and $missing_files2 eq 0 and $sum eq $sum2)) {
				irc_msg($irc_msgs, sprintf('[%s->%s] nothing to transfer, directory is up to date',$site1[1],$site2[1]));
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0 && $dump_mode eq 0)?$use_irc_conn:0);
				return 1;
			}
			if(scalar(keys(%files)) eq 0) {
				irc_msg($irc_msgs, sprintf('[%s->%s] nothing to transfer, but upload still incomplete',$site1[1],$site2[1]));
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0 && $dump_mode eq 0)?$use_irc_conn:0);
				return 0;
			}

			if($skipping>0) {
				if($silent_mode eq 0 && $dump_mode eq 0) {
					irc_msg($irc_msgs, sprintf('[%s->%s] skipping %s files',$site1[1],$site2[1],$skipping));
				}
			}

		}
		else {
			$files{$found_rel}=$found_siz;
		}

		@sorted = sort keys %files;

		my @tmp_arr = ();
		# first the sorted list of sfv's (hopefully only one)
		for my $tmp_val (@sorted) {
			if($tmp_val=~/^.*\.sfv$/i) {
				push(@tmp_arr, $tmp_val);
			}
		}
		# then the sorted list of other files
		for my $tmp_val (@sorted) {
			if(!($tmp_val=~/^.*\.sfv$/i)) {
				push(@tmp_arr, $tmp_val);
			}
		}
		@sorted = @tmp_arr;

		#################################################################################################
		# reconnect if site is ssl encrypted - change to uncrypted data channel
		#################################################################################################

		if ($ssl1 eq 1) {

			disconnect($s1[0],$site1[1],0,0,0);
			sleep(1);
			@s1=connect_to_site($site1[0],$site1[1],$site1[2],$site1[3],$site1[4],$site1[5],1,0);
			if($s1[0] eq 0) {
				irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site1[1],$s1[1]));
				return $site1;
			}
			else {
				if($dump_mode eq 1) {
					if($from_dir ne '') {
						if(!$s1[0]->cwd($from_dir) || ($s1[0]->code ne $CODE_CMD_OK)) {
							irc_msg($irc_msgs,sprintf('[%s] cannot change to source directory %s (%s)',$site1[1],$from_dir,get_message($s1[0])));
							disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
							return 0;
						}
					}
				}

				debug_msg(sprintf('[%s] switching off encrytion for fxp',$site1[1]));

				if($directory eq 1) {
					if(!$s1[0]->cwd($found_rel) || ($s1[0]->code ne $CODE_CMD_OK)) {
						irc_msg($irc_msgs,sprintf('[%s] cannot change to source directory %s (%s)',$site1[1],$found_rel,get_message($s1[0])));
						disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
						return $site1;
					}
				}
			}
		}

		if ($ssl2 eq 1) {

			disconnect($s2[0],$site2[1],0,0,0);
			sleep(1);
			@s2=connect_to_site($site2[0],$site2[1],$site2[2],$site2[3],$site2[4],$site2[5],1,0);
			if($s2[0] eq 0) {
				irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site2[1],$s2[1]));
					if($s1[0] ne 0) {
						disconnect($s1[0],$site1[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
					}
				return $site2;
			}
			else {
				if($dump_mode eq 1) {
					if($to_dir ne '') {
						if(!$s2[0]->cwd($to_dir) || ($s2[0]->code ne $CODE_CMD_OK)) {
							irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$to_dir,get_message($s2[0])));
							disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
							return 0;
						}
					}
				}

				debug_msg(sprintf('[%s] switching encrytion off for fxp',$site2[1]));

				if($directory eq 1) {
					if(!$s2[0]->cwd($found_rel) || ($s2[0]->code ne $CODE_CMD_OK)) {
						irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$found_rel,get_message($s2[0])));
						disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
						return $site2;
					}
				}
			}
		}

		if($ftp_use_progress eq 1) {
			lock(%gimme_counter_total);
			if(!exists($gimme_counter_total{$rel}) || $gimme_counter_total{$rel} < scalar(@sorted)) {
				$gimme_counter_total{$rel} = scalar(@sorted);
			}
		}

		my $timer_key_total = start_timer('total');
		my $bytes_total=0;
		my $errors=0;
		my $i=0;
		my $actual=0;
		for my $filename (@sorted) {
			$actual++;

			# if in spread-mode - but a reset was called -> exit!
			if($spread_mode eq 1) {
				if	($doingspread eq 0){
					last;
				}
			}

			if(1) {
				lock(%current_fxps);
				if($new_name eq '') {
					$current_fxps{sprintf('%s:%s:%s:%d:%d',$site1[1],$site2[1],$filename,$actual,scalar(@sorted))}=1;
				}
				else {
					$current_fxps{sprintf('%s:%s:%s:%d:%d',$site1[1],$site2[1],$new_name,$actual,scalar(@sorted))}=1;
				}
			}

			$found_siz=$files{$filename};
			my $code1=0;
			my $code2=0;
			$last_speed = 0;
			my $timer_key_local = start_timer();
			if($new_name eq '') {
				$s1[0]->pasv_xfer($filename, $s2[0], $filename);
			}
			else {
				$s1[0]->pasv_xfer($filename, $s2[0], $new_name);
				$filename = $new_name;
			}
			my $secs_end=stop_timer($timer_key_local, 1);
			$code1=$s1[0]->code();
			$code2=$s2[0]->code();
			if($code1 > 299 || $code2 > 299) {
				debug_msg(sprintf('fxp: %s->%s:%s:%s | %s : %s',$site1[1],$site2[1],$filename,$secs_end, $code1, $code2));
				$errors++;
				$last_speed = 0;
				my $errormsg=get_message($code1>299?$s1[0]:$s2[0]);
				if(($code1 eq $CODE_ERROR) || ($code2 eq $CODE_ERROR) || ($code2 eq $CODE_CONNECTION_CLOSED) || 
					($code1 eq $CODE_CONNECTION_CLOSED) || ($code1 eq $CODE_CANNOT_READ) || ($code2 eq $CODE_OUT_OF_SPACE)) {
					if(1) {
						lock(%current_fxps);
						delete $current_fxps{sprintf('%s:%s:%s:%d:%d',$site1[1],$site2[1],$filename,$actual,scalar(@sorted))};
					}
					my $secs_total_end=stop_timer($timer_key_total, 1);
					my ($sbytes,$sform)=format_bytes_line($bytes_total);
					if($directory eq 1) {
						if($no_start_end_msgs eq 0) {
							irc_msg($irc_msgs,sprintf('[%s->%s] total transfered %s files, %s %s in %s secs, (%i kb/s), %s files failed to transfer, stopped transfer due to major error (%s)',
								$site1[1],$site2[1],$i,$sbytes,$sform,$secs_total_end, ($bytes_total / 1024) / $secs_total_end, $errors, $errormsg));
						}
					}
					else {
						if($no_start_end_msgs eq 0) {
							irc_msg($irc_msgs,sprintf('[%s->%s] error transfering file %s (%s)',$site1[1],$site2[1],$filename,$errormsg));
						}
					}
					update_speeds($site1[1],$site2[1],$bytes_total,$bytes_total / $secs_total_end);
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0 && $dump_mode eq 0)?$use_irc_conn:0);
					return 0;
				}
				if($silent_mode ne 1) {
					if( (($dump_mode eq 1) && ($code2 ne $CODE_FILE_EXISTS) && ($code2 ne $CODE_FILE_EXISTS2) && ($code2 ne $CODE_CANNOT_CREATE)) || ($dump_mode ne 1)) {
						irc_msg($irc_msgs,sprintf('[%s->%s] error transfering file %s (%s)',$site1[1],$site2[1],$filename,$errormsg));
					}
				}
			}
			else {
				debug_msg(sprintf('fxp: %s->%s:%s:%s | %s : %s',$site1[1],$site2[1],$filename,$secs_end, $code1, $code2));
				$i++;
				$bytes_total+=$found_siz;
				$last_speed = ($found_siz / 1024) / $secs_end;
				if($silent_mode ne 1) {
					if($ftp_use_progress eq 0 || $dump_mode eq 0) {
						my ($sbytes,$sform)=format_bytes_line($found_siz);
						irc_msg($irc_msgs,sprintf('[%s->%s] transfered file %i of %i: %s (%s %s, %s secs, %i kb/s)',$site1[1],$site2[1],$actual,scalar(@sorted),$filename,$sbytes,$sform,$secs_end, ($found_siz / 1024) / $secs_end ));
					}
					else {
						lock(%gimme_counter_total);
						lock(%gimme_counter_done);
						$gimme_counter_done{$rel}++;
						if(!exists($gimme_counter_total{$rel}) || $gimme_counter_total{$rel} eq 0) {
							$gimme_counter_total{$rel}=1;
						}
						my $num = sprintf('%i',(($gimme_counter_done{$rel} * 20) / $gimme_counter_total{$rel}));
						my $out = '';
						for(my $i=1;$i<=20;$i++) {
							if($i<=$num) {
								$out.='#';
							}
							else {
								$out.='.';
							}
						}
						irc_msg($irc_msgs,sprintf('[%s->%s] [%s] (%s/%s) %i kb/s', $site1[1],$site2[1],$out,$gimme_counter_done{$rel},$gimme_counter_total{$rel}, ($found_siz / 1024) / $secs_end));
					}
				}
			}

			if(1) {
				lock(%current_fxps);
				delete $current_fxps{sprintf('%s:%s:%s:%d:%d',$site1[1],$site2[1],$filename,$actual,scalar(@sorted))};
			}

		}

		my $secs_total_end=stop_timer($timer_key_total, 1);
		my ($sbytes,$sform)=format_bytes_line($bytes_total);
		if($directory eq 1) {
			if($no_start_end_msgs eq 0) {
				if($dump_mode eq 0) {
					irc_msg($irc_msgs,sprintf('[%s->%s] total transfered %s files, %s %s in %s secs, (%i kb/s), %s files failed to transfer',
						$site1[1],$site2[1],$i,$sbytes,$sform,$secs_total_end, ($bytes_total / 1024) / $secs_total_end, $errors ));
				}
			}
		}
		else {
			if($errors eq 0) {
				if($no_start_end_msgs eq 0) {
					irc_msg($irc_msgs,sprintf('[%s->%s] transfered %s file, %s %s in %s secs, (%i kb/s)',
						$site1[1],$site2[1],$i,$sbytes,$sform,$secs_total_end, ($bytes_total / 1024) / $secs_total_end));
				}
			}
			else {
				if($no_start_end_msgs eq 0) {
					irc_msg($irc_msgs,sprintf('[%s->%s] failed to transfer 1 file', $site1[1],$site2[1]));
				}
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
				return 0;
			}
		}
		update_speeds($site1[1],$site2[1],$bytes_total,$bytes_total / $secs_total_end);

	}

	# if in gimme-mode - and we're not the last fxp-process - then we simply dont need to check the destination site - only the last fxp process should do that

	if(1) {
		lock(%gimme_counter_total);
		lock(%gimme_counter_done);
		if(exists($gimme_counter_done{$rel}) && exists($gimme_counter_total{$rel}) && $gimme_counter_done{$rel} < $gimme_counter_total{$rel}) {
			# skip check, simply disconnect
			disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0 && $dump_mode eq 0)?$use_irc_conn:0);
			return 0;
		}
	}


	#################################################################################################
	# reconnect if site is ssl encrypted - change to crypted data channel for checks
	#################################################################################################

	if ($ssl2 eq 1) {
		disconnect($s2[0],$site2[1],0,0,0);
		sleep(1);
		@s2=connect_to_site($site2[0],$site2[1],$site2[2],$site2[3],$site2[4],$site2[5],0,0);
		if($s2[0] eq 0) {
			irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site2[1],$s2[1]));
				if($s1[0] ne 0) {
					disconnect($s1[0],$site1[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
				}
			return $site2;
		}
		else {
			if($dump_mode eq 1) {
				if($to_dir ne '') {
					if(!$s2[0]->cwd($to_dir) || ($s2[0]->code ne $CODE_CMD_OK)) {
						irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$to_dir,get_message($s2[0])));
						disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
						return 0;
					}
				}
			}

			debug_msg(sprintf('[%s] switching encrytion on for checks',$site2[1]));

			if($directory eq 1) {
				if(!$s2[0]->cwd($found_rel) || ($s2[0]->code ne $CODE_CMD_OK)) {
					irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$found_rel,get_message($s2[0])));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return $site2;
				}
			}
		}
	}

	#wait for site tag to be created
	sleep(1);

	# check if destination is completed after fxp
	if($directory eq 1) {
		my @list2=dirlist($s2[0]) or $newerr=1;
		if($newerr) {
			irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site2[1],$site2[3],get_message($s2[0])));
			disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
			return $site2;
		}

		my $completed=0;
		my $missing_files=0;
		my $site_tag='';
		my $sfv_here=0;
		my $nfo_here=0;
		my $anzahl=0;
		my $anzahl_total=0;
		my $sum=0;

		# directory einlesen
		for my $line (@list2) {
			if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+)$/i) {
				my $sub_dir=$1;
				my $sub_siz=$2;
				my $sub_fil=$3;
				if($sub_fil=~/\.mp3$/i || $sub_fil=~/\.sfv$/i ||  $sub_fil=~/\.zip$/i ||  $sub_fil=~/\.jpg$/i ||  $sub_fil=~/\.gif$/i ||  $sub_fil=~/\.nfo$/i || $sub_fil=~/\.cue$/i) {
					if($sub_dir=~/^\-/i && $sub_siz>0 and $sub_fil=~/^[^\.]/i) {
						$files{$sub_fil}=$sub_siz;
						$anzahl_total++;
					}
					if($sub_fil=~/\.mp3$/i) {
						$anzahl++;
						$sum+=$sub_siz;
					}
				}
				if($sub_fil=~/mp3-missing/i) {
					$missing_files++;
					$completed=0;
				}
				if($sub_fil=~/\.sfv$/i) {
					$sfv_here=1;
				}
				if($sub_fil=~/\.nfo$/i) {
					$nfo_here=1;
				}
			}
			if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+(.+)$/i) {
				my $sub_fil=$3;
				for my $reg_arr (@complet_tags) {
					my ($reg1,$reg2) = @$reg_arr;
					if($sub_fil=~/$reg1/ && $sub_fil=~/$reg2/) {
						$completed=1;
						$site_tag=$sub_fil;
					}
					last if($completed eq 1);
				}
			}
		}

		if($completed eq 0 || $missing_files ne 0 || $site_tag eq '' || $sfv_here eq 0 || $nfo_here eq 0 || $anzahl eq 0 || $sum eq 0)
		{
			if($site_tag ne '') {
				$site_tag='found';
			}
			else {
				$site_tag='not found';
			}
			irc_msg($irc_msgs, sprintf('[%s] %s is incomplete (mp3\'s: %s, size: %s, missing: %s, site_tag: %s, sfv: %s, nfo: %s) - aborting',
				 $site2[1],$found_rel, $anzahl, $sum, $missing_files, $site_tag, $sfv_here, $nfo_here));
			disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0 && $dump_mode eq 0)?$use_irc_conn:0);
			return 0;
		}
	}

	disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0 && $dump_mode eq 0)?$use_irc_conn:0);
	return 1;
}

# ------------------------------------------------------------------

sub force_fxp_rel {
debug_msg('i am in sub force_fxp_rel');
	my $site1 = shift;
	my $site2 = shift;
	my $rel = shift;
	my $use_irc_conn = shift;
	my $silent_mode=shift;
	my $from_dir=shift;
	my $to_dir=shift;
	my $spread_mode = shift || 0;
	my $no_start_end_msgs = shift || 0;
	my $ignore_incomplete = shift || 0;

	if($silent_mode eq 0) {
		$no_start_end_msgs = 0;
	}

	if(length($rel)<=10) {
		irc_msg($irc_msgs,sprintf('[FXP] release %s seems to not match releasing/naming-rules (too short)',$rel));
		return 0;
	}


	my $new_name = '';
	if($rel=~/^([^:]+):([^:]+)$/i) {
		$rel = $1;
		$new_name = $2;
		debug_msg('renaming mode: '.$rel.' should be renamed to '.$new_name.' on destination site');
	}

	my %files;
	my @sorted;
	my $ssl1 = 0;
	my $ssl2 = 0;

	my $dump_mode=0;
	if(length($from_dir)>0 && length($to_dir)>1) {
		$dump_mode=1;
		debug_msg(sprintf('dump_mode %s, from: %s/%s, to: %s/%s',$dump_mode,$site1,$from_dir,$site2,$to_dir));
	}

	# if in spread-mode - but a reset was called -> exit!
	if($spread_mode eq 1) {
		if	($doingspread eq 0){
			return 0;
		}
	}

	my $key1 = start_timer('fxp_rel'.$site1.$site2);

	my $error=0;
	my @site1=get_site_data($site1,0,$use_irc_conn,0,$dump_mode) or $error=1;
	if($error || scalar(@site1) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site1));
		return $site1;
	}
	my @site2=get_site_data($site2,0,$use_irc_conn,0,$dump_mode) or $error=1;
	if($error || scalar(@site2) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site2));
		return $site2;
	}

	my @s1=connect_to_site($site1[0],$site1[1],$site1[2],$site1[3],$site1[4],$site1[5],1,0);
	if($s1[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site1[1],$s1[1]));
		return $site1;
	}

	my @s2=connect_to_site($site2[0],$site2[1],$site2[2],$site2[3],$site2[4],$site2[5],1,0);
	if($s2[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site2[1],$s2[1]));
		if($s1[0] ne 0) {
			disconnect($s1[0],$site1[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		}
		return $site2;
	}

	if($silent_mode eq 0 && $dump_mode eq 0) {
		irc_msg($irc_msgs,sprintf('[%s] && [%s] connected (%s secs)',$site1[1],$site2[1], stop_timer($key1, 1)));
	}


	if($dump_mode eq 1) {
		if($from_dir ne '') {
			if(!$s1[0]->cwd($from_dir) || ($s1[0]->code ne $CODE_CMD_OK)) {
				irc_msg($irc_msgs,sprintf('[%s] cannot change to source directory %s (%s)',$site1[1],$from_dir,get_message($s1[0])));
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
				return 0;
			}
		}
		if($to_dir ne '') {
			if(!$s2[0]->cwd($to_dir) || ($s2[0]->code ne $CODE_CMD_OK)) {
				irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$to_dir,get_message($s2[0])));
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
				return 0;
			}
		}
	}

	my $newerr = 0;
	my @list1=dirlist($s1[0]) or $newerr=1;
	if($newerr) {
		$newerr = 0;
		if ($site1[2] ne 'ssl') {
			irc_msg($irc_msgs, sprintf('[%s] cannot list directory! (%s)',$site1[1],get_message($s1[0])));
			disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
			return $site1;
		}

		debug_msg(sprintf('[%s] cannot list directory, switching to ssl',$site1[1]));

		disconnect($s1[0],$site1[1],0,0,0);
		$ssl1 = 1;
		sleep(1);
		@s1=connect_to_site($site1[0],$site1[1],$site1[2],$site1[3],$site1[4],$site1[5],0,0); #verschlüsselt!
		if($s1[0] eq 0) {
			irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site1[1],$s1[1]));
			return $site1;
		}
		if($dump_mode eq 1) {
			if($from_dir ne '') {
				if(!$s1[0]->cwd($from_dir) || ($s1[0]->code ne $CODE_CMD_OK)) {
					irc_msg($irc_msgs,sprintf('[%s] cannot change to source directory %s (%s)',$site1[1],$from_dir,get_message($s1[0])));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return 0;
				}
			}
		}
		@list1=dirlist($s1[0]) or $newerr=1;
		if($newerr) {
			irc_msg($irc_msgs, sprintf('[%s] cannot list directory in either mode! (%s)',$site1[1],get_message($s1[0])));
			disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
			return $site1;
		}
	}

	my $found_dir='';
	my $found_siz='';
	my $found_rel='';
	my $directory=0;

	my $use_rel = $rel;
	$use_rel =~ s/([()]+)/\\$1/g;

	for my $line (@list1) {
		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+($use_rel).*$/i) {
			$found_dir=$1;
			$found_siz=$2;
			$found_rel=$3;
			if($found_dir=~/^d/i || $found_dir=~/^l/i) {
				$directory=1;
				if($dump_mode ne 1 && $no_start_end_msgs eq 0) {
					irc_msg($irc_msgs,sprintf('[%s] transfering release %s to %s',$site1[1],$found_rel,$site2[1]));
				}
				last;
			}
			else {
				$directory=0;
				if($dump_mode ne 1 && $no_start_end_msgs eq 0) {
					my ($sbytes,$sform)=format_bytes_line($found_siz);
					irc_msg($irc_msgs,sprintf('[%s] transfering %s (%s %s) to %s',$site1[1],$found_rel,$sbytes,$sform,$site2[1]));
				}
				last;
			}
		}
	}

	# renaming mode only allowed if a single file is transfered
	if($directory eq 1) {
		$new_name = '';
	}

	if($found_dir eq '') {
		irc_msg($irc_msgs,sprintf('[%s] no release/file matching %s found! (bad named?)',$site1[1],$rel));
		disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
		return $site1;
	}
	else {
		if($directory eq 1) {
			if(!$s1[0]->cwd($found_rel) || ($s1[0]->code ne $CODE_CMD_OK)) {
				irc_msg($irc_msgs,sprintf('[%s] cannot change to source directory %s (%s)',$site1[1],$found_rel,get_message($s1[0])));
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
				return $site1;
			}

			@list1=dirlist($s1[0]) or $newerr=1;
			if($newerr) {
				irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site1[1],$found_rel,get_message($s1[0])));
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
				return $site1;
			}

			my $completed=0;
			my $missing_files=0;
			my $site_tag='';
			my $sfv_here=0;
			my $nfo_here=0;
			my $anzahl=0;
			my $anzahl_total=0;
			my $sum=0;

			# directory einlesen
			for my $line (@list1) {
				if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+)$/i) {
					my $sub_dir=$1;
					my $sub_siz=$2;
					my $sub_fil=$3;
					if($sub_fil=~/\.mp3$/i || $sub_fil=~/\.sfv$/i ||  $sub_fil=~/\.zip$/i ||  $sub_fil=~/\.jpg$/i ||  $sub_fil=~/\.gif$/i ||  $sub_fil=~/\.nfo$/i || $sub_fil=~/\.cue$/i) {
						if($sub_dir=~/^\-/i && $sub_siz>0 and $sub_fil=~/^[^\.]/i) {
							$files{$sub_fil}=$sub_siz;
							$anzahl_total++;
						}
						if($sub_fil=~/\.mp3$/i) {
							$anzahl++;
							$sum+=$sub_siz;
						}
					}
					if($sub_fil=~/mp3-missing/i) {
						$missing_files++;
						$completed=0;
					}
					if($sub_fil=~/\.sfv$/i) {
						$sfv_here=1;
					}
					if($sub_fil=~/\.nfo$/i) {
						$nfo_here=1;
					}
				}
				if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+(.+)$/i) {
					my $sub_fil=$3;
					for my $reg_arr (@complet_tags) {
						my ($reg1,$reg2) = @$reg_arr;
						if($sub_fil=~/$reg1/ && $sub_fil=~/$reg2/) {
							$completed=1;
							$site_tag=$sub_fil;
						}
						last if($completed eq 1);
					}
				}
			}

			if($ignore_incomplete eq 0) {
				if($nfo_here eq 0)
				{
					irc_msg($irc_msgs, sprintf('[%s] %s is incomplete (nfo: %s) - aborting',
						 $site1[1],$found_rel, $nfo_here));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return 0;
				}
			}

			if(!$s2[0]->cwd($found_rel) || ($s2[0]->code ne $CODE_CMD_OK)) {
				if(!$s2[0]->mkdir($found_rel)) {
					my $error_msg=get_message($s2[0]);
					if($silent_mode ne 1) {
						# unknown error
						if(!( ($s2[0]->code eq $CODE_FILE_EXISTS) || ($s2[0]->code eq $CODE_CANNOT_CREATE)) ) {
							irc_msg($irc_msgs,sprintf('[%s] cannot create destination directory %s (%s)',$site2[1],$found_rel,$error_msg));
						}
					}
					# global error
					if(($s2[0]->code eq $CODE_OUT_OF_SPACE)) {
						irc_msg($irc_msgs,sprintf('[%s] cannot create destination directory %s (%s)',$site2[1],$found_rel,$error_msg));
						disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
						return $site2;
					}
				}
				if(!$s2[0]->cwd($found_rel) || ($s2[0]->code ne $CODE_CMD_OK)) {
					irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$found_rel,get_message($s2[0])));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return $site2;
				}
			}

			$newerr = 0;
			my @list2=dirlist($s2[0]) or $newerr=1;

			if($newerr) {
				$newerr = 0;
				if ($site2[2] ne 'ssl') {
					irc_msg($irc_msgs, sprintf('[%s] cannot list directory! %s (%s)',$site2[1],$found_rel,get_message($s2[0])));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return $site2;
				}

				debug_msg(sprintf('[%s] cannot list directory, switching to ssl',$site2[1]));

				disconnect($s2[0],$site2[1],0,0,0);
				$ssl2 = 1;
				sleep(1);
				@s2=connect_to_site($site2[0],$site2[1],$site2[2],$site2[3],$site2[4],$site2[5],0,0); #verschlüsselt!
				if($s2[0] eq 0) {
					irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site2[1],$s2[1]));
					return $site2;
				}
				if($dump_mode eq 1) {
					if($to_dir ne '') {
						if(!$s2[0]->cwd($to_dir) || ($s2[0]->code ne $CODE_CMD_OK)) {
							irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$to_dir,get_message($s2[0])));
							disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
							return 0;
						}
					}
				}
				if(!$s2[0]->cwd($found_rel) || ($s2[0]->code ne $CODE_CMD_OK)) {
					irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$found_rel,get_message($s2[0])));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return $site2;
				}
				@list2=dirlist($s2[0]) or $newerr=1;
				if($newerr) {
					irc_msg($irc_msgs, sprintf('[%s] cannot list directory in either mode! %s (%s)',$site2[1],$found_rel,get_message($s2[0])));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return $site2;
				}
			}

			my $missing_files2=0;
			my $anzahl2=0;
			my $anzahl_total2=0;
			my $sum2=0;
			my $skipping=0;

			for my $line2 (@list2) {
				if($line2=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+)$/i) {
					my $sub_dir2=$1;
					my $sub_siz2=$2;
					my $sub_fil2=$3;
					if($sub_fil2=~/\.mp3$/i || $sub_fil2=~/\.sfv$/i ||  $sub_fil2=~/\.zip$/i ||  $sub_fil2=~/\.jpg$/i ||  $sub_fil2=~/\.gif$/i ||  $sub_fil2=~/\.nfo$/i || $sub_fil2=~/\.cue$/i) {
						$anzahl_total2++;

						# skip files that are already there - NO!!! resume!!!
						if(exists($files{$sub_fil2})) {
							$skipping++;
							delete($files{$sub_fil2});
						}

						if($sub_fil2=~/\.mp3$/i) {
							$anzahl2++;
							$sum2+=$sub_siz2;
						}
					}
					if($sub_fil2=~/mp3-missing/i) {
						$missing_files2++;
					}
				}
			}

			if(($anzahl eq $anzahl2 and $anzahl_total eq $anzahl_total2 and $missing_files2 eq 0 and $sum eq $sum2)) {
				irc_msg($irc_msgs, sprintf('[%s->%s] nothing to transfer, directory is up to date',$site1[1],$site2[1]));
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0 && $dump_mode eq 0)?$use_irc_conn:0);
				return 1;
			}
			if(scalar(keys(%files)) eq 0) {
				irc_msg($irc_msgs, sprintf('[%s->%s] nothing to transfer, but upload still incomplete',$site1[1],$site2[1]));
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0 && $dump_mode eq 0)?$use_irc_conn:0);
				return 0;
			}

			if($skipping>0) {
				if($silent_mode eq 0 && $dump_mode eq 0) {
					irc_msg($irc_msgs, sprintf('[%s->%s] skipping %s files',$site1[1],$site2[1],$skipping));
				}
			}

		}
		else {
			$files{$found_rel}=$found_siz;
		}

		@sorted = sort keys %files;

		my @tmp_arr = ();
		# first the sorted list of sfv's (hopefully only one)
		for my $tmp_val (@sorted) {
			if($tmp_val=~/^.*\.sfv$/i) {
				push(@tmp_arr, $tmp_val);
			}
		}
		# then the sorted list of other files
		for my $tmp_val (@sorted) {
			if(!($tmp_val=~/^.*\.sfv$/i)) {
				push(@tmp_arr, $tmp_val);
			}
		}
		@sorted = @tmp_arr;

		#################################################################################################
		# reconnect if site is ssl encrypted - change to uncrypted data channel
		#################################################################################################

		if ($ssl1 eq 1) {

			disconnect($s1[0],$site1[1],0,0,0);
			sleep(1);
			@s1=connect_to_site($site1[0],$site1[1],$site1[2],$site1[3],$site1[4],$site1[5],1,0);
			if($s1[0] eq 0) {
				irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site1[1],$s1[1]));
				return $site1;
			}
			else {
				if($dump_mode eq 1) {
					if($from_dir ne '') {
						if(!$s1[0]->cwd($from_dir) || ($s1[0]->code ne $CODE_CMD_OK)) {
							irc_msg($irc_msgs,sprintf('[%s] cannot change to source directory %s (%s)',$site1[1],$from_dir,get_message($s1[0])));
							disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
							return 0;
						}
					}
				}

				debug_msg(sprintf('[%s] switching off encrytion for fxp',$site1[1]));

				if($directory eq 1) {
					if(!$s1[0]->cwd($found_rel) || ($s1[0]->code ne $CODE_CMD_OK)) {
						irc_msg($irc_msgs,sprintf('[%s] cannot change to source directory %s (%s)',$site1[1],$found_rel,get_message($s1[0])));
						disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
						return $site1;
					}
				}
			}
		}

		if ($ssl2 eq 1) {

			disconnect($s2[0],$site2[1],0,0,0);
			sleep(1);
			@s2=connect_to_site($site2[0],$site2[1],$site2[2],$site2[3],$site2[4],$site2[5],1,0);
			if($s2[0] eq 0) {
				irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site2[1],$s2[1]));
					if($s1[0] ne 0) {
						disconnect($s1[0],$site1[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
					}
				return $site2;
			}
			else {
				if($dump_mode eq 1) {
					if($to_dir ne '') {
						if(!$s2[0]->cwd($to_dir) || ($s2[0]->code ne $CODE_CMD_OK)) {
							irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$to_dir,get_message($s2[0])));
							disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
							return 0;
						}
					}
				}

				debug_msg(sprintf('[%s] switching encrytion off for fxp',$site2[1]));

				if($directory eq 1) {
					if(!$s2[0]->cwd($found_rel) || ($s2[0]->code ne $CODE_CMD_OK)) {
						irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$found_rel,get_message($s2[0])));
						disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
						return $site2;
					}
				}
			}
		}

		if($ftp_use_progress eq 1) {
			lock(%gimme_counter_total);
			if(!exists($gimme_counter_total{$rel}) || $gimme_counter_total{$rel} < scalar(@sorted)) {
				$gimme_counter_total{$rel} = scalar(@sorted);
			}
		}

		my $timer_key_total = start_timer('total');
		my $bytes_total=0;
		my $errors=0;
		my $i=0;
		my $actual=0;
		for my $filename (@sorted) {
			$actual++;

			# if in spread-mode - but a reset was called -> exit!
			if($spread_mode eq 1) {
				if	($doingspread eq 0){
					last;
				}
			}

			if(1) {
				lock(%current_fxps);
				if($new_name eq '') {
					$current_fxps{sprintf('%s:%s:%s:%d:%d',$site1[1],$site2[1],$filename,$actual,scalar(@sorted))}=1;
				}
				else {
					$current_fxps{sprintf('%s:%s:%s:%d:%d',$site1[1],$site2[1],$new_name,$actual,scalar(@sorted))}=1;
				}
			}

			$found_siz=$files{$filename};
			my $code1=0;
			my $code2=0;
			$last_speed = 0;
			my $timer_key_local = start_timer();
			if($new_name eq '') {
				$s1[0]->pasv_xfer($filename, $s2[0], $filename);
			}
			else {
				$s1[0]->pasv_xfer($filename, $s2[0], $new_name);
				$filename = $new_name;
			}
			my $secs_end=stop_timer($timer_key_local, 1);
			$code1=$s1[0]->code();
			$code2=$s2[0]->code();
			if($code1 > 299 || $code2 > 299) {
				debug_msg(sprintf('fxp: %s->%s:%s:%s | %s : %s',$site1[1],$site2[1],$filename,$secs_end, $code1, $code2));
				$errors++;
				$last_speed = 0;
				my $errormsg=get_message($code1>299?$s1[0]:$s2[0]);
				if(($code1 eq $CODE_ERROR) || ($code2 eq $CODE_ERROR) || ($code2 eq $CODE_CONNECTION_CLOSED) || 
					($code1 eq $CODE_CONNECTION_CLOSED) || ($code1 eq $CODE_CANNOT_READ) || ($code2 eq $CODE_OUT_OF_SPACE)) {
					if(1) {
						lock(%current_fxps);
						delete $current_fxps{sprintf('%s:%s:%s:%d:%d',$site1[1],$site2[1],$filename,$actual,scalar(@sorted))};
					}
					my $secs_total_end=stop_timer($timer_key_total, 1);
					my ($sbytes,$sform)=format_bytes_line($bytes_total);
					if($directory eq 1) {
						if($no_start_end_msgs eq 0) {
							irc_msg($irc_msgs,sprintf('[%s->%s] total transfered %s files, %s %s in %s secs, (%i kb/s), %s files failed to transfer, stopped transfer due to major error (%s)',
								$site1[1],$site2[1],$i,$sbytes,$sform,$secs_total_end, ($bytes_total / 1024) / $secs_total_end, $errors, $errormsg));
						}
					}
					else {
						if($no_start_end_msgs eq 0) {
							irc_msg($irc_msgs,sprintf('[%s->%s] error transfering file %s (%s)',$site1[1],$site2[1],$filename,$errormsg));
						}
					}
					update_speeds($site1[1],$site2[1],$bytes_total,$bytes_total / $secs_total_end);
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0 && $dump_mode eq 0)?$use_irc_conn:0);
					return 0;
				}
				if($silent_mode ne 1) {
					if( (($dump_mode eq 1) && ($code2 ne $CODE_FILE_EXISTS) && ($code2 ne $CODE_FILE_EXISTS2) && ($code2 ne $CODE_CANNOT_CREATE)) || ($dump_mode ne 1)) {
						irc_msg($irc_msgs,sprintf('[%s->%s] error transfering file %s (%s)',$site1[1],$site2[1],$filename,$errormsg));
					}
				}
			}
			else {
				debug_msg(sprintf('fxp: %s->%s:%s:%s | %s : %s',$site1[1],$site2[1],$filename,$secs_end, $code1, $code2));
				$i++;
				$bytes_total+=$found_siz;
				$last_speed = ($found_siz / 1024) / $secs_end;
				if($silent_mode ne 1) {
					if($ftp_use_progress eq 0 || $dump_mode eq 0) {
						my ($sbytes,$sform)=format_bytes_line($found_siz);
						irc_msg($irc_msgs,sprintf('[%s->%s] transfered file %i of %i: %s (%s %s, %s secs, %i kb/s)',$site1[1],$site2[1],$actual,scalar(@sorted),$filename,$sbytes,$sform,$secs_end, ($found_siz / 1024) / $secs_end ));
					}
					else {
						lock(%gimme_counter_total);
						lock(%gimme_counter_done);
						$gimme_counter_done{$rel}++;
						if(!exists($gimme_counter_total{$rel}) || $gimme_counter_total{$rel} eq 0) {
							$gimme_counter_total{$rel}=1;
						}
						my $num = sprintf('%i',(($gimme_counter_done{$rel} * 20) / $gimme_counter_total{$rel}));
						my $out = '';
						for(my $i=1;$i<=20;$i++) {
							if($i<=$num) {
								$out.='#';
							}
							else {
								$out.='.';
							}
						}
						irc_msg($irc_msgs,sprintf('[%s->%s] [%s] (%s/%s) %i kb/s', $site1[1],$site2[1],$out,$gimme_counter_done{$rel},$gimme_counter_total{$rel}, ($found_siz / 1024) / $secs_end));
					}
				}
			}

			if(1) {
				lock(%current_fxps);
				delete $current_fxps{sprintf('%s:%s:%s:%d:%d',$site1[1],$site2[1],$filename,$actual,scalar(@sorted))};
			}

		}

		my $secs_total_end=stop_timer($timer_key_total, 1);
		my ($sbytes,$sform)=format_bytes_line($bytes_total);
		if($directory eq 1) {
			if($no_start_end_msgs eq 0) {
				if($dump_mode eq 0) {
					irc_msg($irc_msgs,sprintf('[%s->%s] total transfered %s files, %s %s in %s secs, (%i kb/s), %s files failed to transfer',
						$site1[1],$site2[1],$i,$sbytes,$sform,$secs_total_end, ($bytes_total / 1024) / $secs_total_end, $errors ));
				}
			}
		}
		else {
			if($errors eq 0) {
				if($no_start_end_msgs eq 0) {
					irc_msg($irc_msgs,sprintf('[%s->%s] transfered %s file, %s %s in %s secs, (%i kb/s)',
						$site1[1],$site2[1],$i,$sbytes,$sform,$secs_total_end, ($bytes_total / 1024) / $secs_total_end));
				}
			}
			else {
				if($no_start_end_msgs eq 0) {
					irc_msg($irc_msgs,sprintf('[%s->%s] failed to transfer 1 file', $site1[1],$site2[1]));
				}
				disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
				return 0;
			}
		}
		update_speeds($site1[1],$site2[1],$bytes_total,$bytes_total / $secs_total_end);

	}

	# if in gimme-mode - and we're not the last fxp-process - then we simply dont need to check the destination site - only the last fxp process should do that

	if(1) {
		lock(%gimme_counter_total);
		lock(%gimme_counter_done);
		if(exists($gimme_counter_done{$rel}) && exists($gimme_counter_total{$rel}) && $gimme_counter_done{$rel} < $gimme_counter_total{$rel}) {
			# skip check, simply disconnect
			disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0 && $dump_mode eq 0)?$use_irc_conn:0);
			return 0;
		}
	}


	#################################################################################################
	# reconnect if site is ssl encrypted - change to crypted data channel for checks
	#################################################################################################

	if ($ssl2 eq 1) {
		disconnect($s2[0],$site2[1],0,0,0);
		sleep(1);
		@s2=connect_to_site($site2[0],$site2[1],$site2[2],$site2[3],$site2[4],$site2[5],0,0);
		if($s2[0] eq 0) {
			irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site2[1],$s2[1]));
				if($s1[0] ne 0) {
					disconnect($s1[0],$site1[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
				}
			return $site2;
		}
		else {
			if($dump_mode eq 1) {
				if($to_dir ne '') {
					if(!$s2[0]->cwd($to_dir) || ($s2[0]->code ne $CODE_CMD_OK)) {
						irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$to_dir,get_message($s2[0])));
						disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
						return 0;
					}
				}
			}

			debug_msg(sprintf('[%s] switching encrytion on for checks',$site2[1]));

			if($directory eq 1) {
				if(!$s2[0]->cwd($found_rel) || ($s2[0]->code ne $CODE_CMD_OK)) {
					irc_msg($irc_msgs,sprintf('[%s] cannot change to destination directory %s (%s)',$site2[1],$found_rel,get_message($s2[0])));
					disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
					return $site2;
				}
			}
		}
	}

	#wait for site tag to be created
	sleep(1);

	# check if destination is completed after fxp
	if($directory eq 1) {
		my @list2=dirlist($s2[0]) or $newerr=1;
		if($newerr) {
			irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site2[1],$site2[3],get_message($s2[0])));
			disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0)?$use_irc_conn:0);
			return $site2;
		}

		my $completed=0;
		my $missing_files=0;
		my $site_tag='';
		my $sfv_here=0;
		my $nfo_here=0;
		my $anzahl=0;
		my $anzahl_total=0;
		my $sum=0;

		# directory einlesen
		for my $line (@list2) {
			if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+([^ ]+)$/i) {
				my $sub_dir=$1;
				my $sub_siz=$2;
				my $sub_fil=$3;
				if($sub_fil=~/\.mp3$/i || $sub_fil=~/\.sfv$/i ||  $sub_fil=~/\.zip$/i ||  $sub_fil=~/\.jpg$/i ||  $sub_fil=~/\.gif$/i ||  $sub_fil=~/\.nfo$/i || $sub_fil=~/\.cue$/i) {
					if($sub_dir=~/^\-/i && $sub_siz>0 and $sub_fil=~/^[^\.]/i) {
						$files{$sub_fil}=$sub_siz;
						$anzahl_total++;
					}
					if($sub_fil=~/\.mp3$/i) {
						$anzahl++;
						$sum+=$sub_siz;
					}
				}
				if($sub_fil=~/mp3-missing/i) {
					$missing_files++;
					$completed=0;
				}
				if($sub_fil=~/\.sfv$/i) {
					$sfv_here=1;
				}
				if($sub_fil=~/\.nfo$/i) {
					$nfo_here=1;
				}
			}
			if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+(.+)$/i) {
				my $sub_fil=$3;
				for my $reg_arr (@complet_tags) {
					my ($reg1,$reg2) = @$reg_arr;
					if($sub_fil=~/$reg1/ && $sub_fil=~/$reg2/) {
						$completed=1;
						$site_tag=$sub_fil;
					}
					last if($completed eq 1);
				}
			}
		}

		if($nfo_here eq 0)
		{
			irc_msg($irc_msgs, sprintf('[%s] %s is incomplete (nfo: %s) - aborting',
				 $site2[1],$found_rel, $nfo_here));
			disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0 && $dump_mode eq 0)?$use_irc_conn:0);
			return 0;
		}
	}

	disconnect($s1[0],$site1[1],$s2[0],$site2[1],($silent_mode eq 0 && $dump_mode eq 0)?$use_irc_conn:0);
	return 1;
}

# ------------------------------------------------------------------

# delete a nfo file on a site
sub delete_nfo {
	my $site=shift;
	my $rel=shift;
	my $use_irc_conn=shift;
	my $silent_mode=shift;

	my $error=0;
	my @s;
	my @site=get_site_data($site,0,$use_irc_conn,0,0) or $error=1;
	if($error || scalar(@site) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site));
		return 0;
	}
	@s=connect_to_site($site[0],$site[1],$site[2],$site[3],$site[4],$site[5],0,0);
	if($s[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site[1],$s[1]));
		return 0;
	}
	if(!$s[0]->cwd($rel) || ($s[0]->code ne $CODE_CMD_OK)) {
		if($silent_mode eq 0) {
			irc_msg($irc_msgs,sprintf('[%s] nope, release %s isnt here (%s)',$site[1],$rel,get_message($s[0])));
		}
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return 1;
	}

	my $newerr=0;
	my @list=dirlist($s[0]) or $newerr=1;
	if($newerr) {
		if($silent_mode eq 0) {
			irc_msg($irc_msgs, sprintf('[%s] cannot list directory %s (%s)',$site[1],$rel,get_message($s[0])));
		}
		disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
		return 0;
	}

	for my $line (@list) {
		if($line=~ /^([ldrwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+(.+)$/i) {
			my $sub_dir=$1;
			my $sub_siz=$2;
			my $sub_fil=$3;
			
			if($sub_fil=~/\.nfo/i) {
				irc_msg($irc_msgs,sprintf('[%s] found nfo: %s',$site[1],$sub_fil));
				$s[0]->delete($sub_fil);
				$error=$s[0]->code();
				if($error>$CODE_CMD_OK) {
					irc_msg($irc_msgs,sprintf('[%s] cannot delete %s (%s)',$site[1],$sub_fil,get_message($s[0])));
				}
				else {
					if($silent_mode eq 0) {
						irc_msg($irc_msgs,sprintf('[%s] deleted %s',$site[1],$sub_fil));
					}
				}
			}
		}
	}
	disconnect($s[0],$site[1],0,0,($silent_mode eq 0)?$use_irc_conn:0);
	return 1;
}

# ------------------------------------------------------------------

# delete nfo files on all sites
sub delete_all_nfo {
	my $rel=shift;
	my $use_irc_conn=shift;

	if(length($rel)<=10) {
		irc_msg($irc_msgs,sprintf('[DEL] release %s seems to not match releasing/naming-rules (too short)',$rel));
		return 0;
	}

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(status)='UP' and presite=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[DEL] no sites found');
		return 0;
	}

	my $key1 = start_timer('delete_all_nfo');
	irc_msg($irc_msgs,'[DEL] started, checking sites');

	my %threads;
	for my $out (@rows) {
		my $thread  = threads->create('delete_nfo',@$out[0], $rel, $use_irc_conn,1);
		$threads{@$out[0]}=$thread;
	}

	my @done=();
	my @failed=();

	sleep(3);
	for my $sitename (keys %threads) {
		my $result=$threads{$sitename}->join();
		if($result eq 0) {
			push @failed,$sitename;
		}
		else {
			push @done,$sitename;
		}
	}

	irc_msg($irc_msgs,sprintf('[DEL] Done (%s secs) Sites done: %s - Sites failed: %s',stop_timer($key1, 1), join(', ',@done),join(', ',@failed)));
	return 1;
}

# ------------------------------------------------------------------

# takes a file on a site and sends it to every other presite/dumpsite - then fxps back - simply a speed-test
sub speedtest {
	my $site = shift;
	my $file = shift;
	my $use_irc_conn = shift;

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(status)='UP' and presite=1 and logins>0 and upper(site)=upper('$site')");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[SPEEDTEST] site is down or not a presite or simply doesnt exist');
		return 0;
	}

	# select all presites
	($res, $msg, @rows)= conquery_db("select upper(site) from sites where upper(status)='UP' and presite=1 and logins>0 and upper(site)!=upper('$site') order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg->errstr);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[SPEEDTEST] no destination sites found that are up');
		return 0;
	}

	my @presites;
	for my $out (@rows) {
		push(@presites, @$out[0]);
	}

	# check if file exists and matches minimal requirements
	my $error=0;
	my @s;
	my @site=get_site_data($site,0,$use_irc_conn,0,0) or $error=1;
	if($error || scalar(@site) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site));
		return 0;
	}
	@s=connect_to_site($site[0],$site[1],$site[2],$site[3],$site[4],$site[5],0,0);
	if($s[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site[1],$s[1]));
		return 0;
	}
	my $newerr=0;
	my @list=dirlist($s[0]) or $newerr=1;
	if($newerr) {
		irc_msg($irc_msgs, sprintf('[%s] cannot list directory (%s)',$site[1],get_message($s[0])));
		disconnect($s[0],$site[1],0,0,$use_irc_conn);
		return 0;
	}

	my $found = 0;
	for my $line (@list) {
		if($line=~ /^([rwx\-]{10})[ ]+[0-9]+[ ]+[^ ]+[ ]+[^ ]+[ ]+([0-9]+)[ ]+[a-z]+[ ]+[0-9]{1,2}[ ]+[0-9]{1,2}:?[0-9]{1,2}[ ]+(.+)$/i) {
			my $sub_dir=$1;
			my $sub_siz=$2;
			my $sub_fil=$3;
			
			if($sub_fil=~/^$file$/i) {
				$file=$sub_fil;
				$found=$sub_siz;
				last;
			}
		}
	}
	disconnect($s[0],$site[1],0,0,0);

	my ($sbytes,$sform) = format_bytes_line($found);

	if($found eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] file %s not found',$site, $file));
		return 0;
	}
	if($found < (5 * 1024 * 1024)) {
		irc_msg($irc_msgs, sprintf('[%s] file %s must be at least 5mb for a speedtest (current: %s %s)',$site, $file, $sbytes,$sform));
		return 0;
	}

	my $key0 = start_timer('speed_test_fun');

	my %speeds;
	if(scalar(@presites)>0) {
		irc_msg($irc_msgs,sprintf('[SPEEDTEST] %s: Testing %s presites with %s (%s %s)', $site, scalar(@presites), $file, $sbytes,$sform));
		for my $sitename (@presites) {
			$speeds{$sitename} = single_speedtest($site,$sitename,'',$file,$found,$use_irc_conn);
		}
	}

	my @sorted = reverse sort { $speeds{$a} cmp $speeds{$b} } keys %speeds;
	irc_msg($irc_msgs,'[SPEEDTEST] Recommended source_sites list: '.join(', ', @sorted));

	irc_msg($irc_msgs,sprintf('[SPEEDTEST] Done (%s secs)', stop_timer($key0, 1)));
	return 1;
}

# ------------------------------------------------------------------

# does the speed-test for a single site
sub single_speedtest {
	my $site1 = shift;
	my $site2 = shift;
	my $path = shift;
	my $file = shift;
	my $size = shift;
	my $use_irc_conn = shift;

	my ($s1,$s2) = gettimeofday();
	my $new_filename = $file.$s2.'.jpg';

	my $speed1 = '';
	my $speed2 = '';
	my $ok1='kb/s';
	my $ok2='kb/s';


	# transfer the file as orig filename -> filename + timestamp
	my $result1 = fxp_rel($site1, $site2, $file.':'.$new_filename, $use_irc_conn, 1, '', $path, 0, 1, 0);
	if($result1 eq 1) {
		$speed1 = $last_speed;
		$ok1=sprintf('%i kb/s', $speed1);
	}
	else {
		$ok1='FAILED';
	}

	# transfer the file back as filename + timestamp -> filename + timestamp
	my $result2 = fxp_rel($site2, $site1, $new_filename, $use_irc_conn, 1, $path, '', 0, 1, 0);
	if($result2 eq 1) {
		$speed2 = $last_speed;
		$ok2=sprintf('%i kb/s', $speed2);
	}
	else {
		$ok2='FAILED';
	}

	# now delete the file '$filename + timestamp' on booth sites
	delete_release($site1, $new_filename, $use_irc_conn, 1);
	delete_release($site2, $new_filename, $use_irc_conn, 1);

	irc_msg($irc_msgs,sprintf('[SPEEDTEST] %s to %s: %s - %s to %s: %s', $site1, $site2, $ok1, $site2, $site1, $ok2));
	return ($speed2>0 && $speed2!='') ? $speed2 : 0;
}

# ------------------------------------------------------------------

# search a rel on all sites - try to deliver it to a dump site
sub gimme {
	my $site = shift;
	my $rel = shift;
	my $source_site = shift;
	my $use_irc_conn = shift;

	my $dump_path='';
	my $source_sites='';
	my $logins=0;

	if(length($rel)<=10) {
		irc_msg($irc_msgs,sprintf('[GIMME] release %s seems to not match releasing/naming-rules (too short)',$rel));
		return 0;
	}

	my ($res, $msg, @rows) = conquery_db("select upper(site),dump_path,source_sites,logins from sites where upper(status)='UP' and dump=1 and logins>0 and upper(site)=upper('$site')");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[GIMME] no sitename given or given sitename isnt a dump-site, try !pre gimmehelp');
		return 0;
	}

	for my $out (@rows) {
		($site, $dump_path, $source_sites, $logins) = @$out;
	}

	# use only ONE site as source
	if($source_site ne '') {
		($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(status)='UP' and logins>0 and upper(site)=upper('$source_site')");
		if(!$res) {
			irc_msg($irc_msgs,'[SQL] Error: '.$msg);
			return 0;
		}
		if(!scalar(@rows)) {
			irc_msg($irc_msgs,'[GIMME] given source-site ' . $source_site . ' is wrong or not up - try !pre gimmehelp');
			return 0;
		}

		for my $out (@rows) {
			$source_site=@$out[0];
		}
	}

	if($site eq '' or $dump_path eq '' or $source_sites eq '' or !$logins) {
		irc_msg($irc_msgs,'[GIMME] error getting site-data for dump');
		return 0;
	}

	my $key1 = start_timer('gimme');

	my @sites=split(/,/,$source_sites);
	my %final_sites;
	my %output;

	# to block a new gimme process while its searching the rel
	if(1) {
		lock(%gimme_counter_total);
		$gimme_counter_total{$rel}=0;
	}

	my %result = search_rel($rel,$source_site,$use_irc_conn,$site,1);

	# delete old rel - as the real one can differ (case etc)
	if(1) {
		lock(%gimme_counter_total);
		delete($gimme_counter_total{$rel});
	}

	if(scalar(keys(%result))>1) {

		if((scalar(keys(%result))-1) > $logins) {
			my $filtered=0;
			for my $temp_site (@sites) {
				if(exists($result{$temp_site}) && $filtered<$logins) {
					$final_sites{$temp_site}=$result{$temp_site};
					$output{$temp_site}=$result{$temp_site};
					$filtered++;
				}
			}
			if(scalar(keys(%final_sites))>0) {
				$final_sites{'first_rel'}=$result{'first_rel'};
				%result=%final_sites;
			} else {
				irc_msg($irc_msgs,'[GIMME] error filtering source-sites for dump, misconfiguration?');
				return 0;
			}
			irc_msg($irc_msgs,sprintf('[GIMME] more sources than max-logins on dump-site, keeping %s fastest ones (%s)',$logins,join(', ',keys(%output))));
		}

		irc_msg($irc_msgs,sprintf('[GIMME] prepare to send rel %s from %s sources to %s:%s',$result{'first_rel'},scalar(keys(%result))-1,$site,$dump_path));

		if(1) {
			lock(%gimme_counter_total);
			lock(%gimme_counter_done);
			$gimme_counter_done{$result{'first_rel'}}=0;
			$gimme_counter_total{$result{'first_rel'}}=0;
		}

		my %threads;
		for my $source_site (keys %result) {
			if($source_site ne 'first_rel') {
				my $source_dir=$result{$source_site};
				my $use_rel = $result{'first_rel'};
				$use_rel =~ s/([()]+)/\\$1/g;
				if($source_dir=~/^(.+)$use_rel$/i) {
					$source_dir=$1;
				}
				my $thread  = threads->create('fxp_rel',$source_site,$site, $result{'first_rel'}, $use_irc_conn,0, $source_dir, $dump_path,0,0,1);
				$threads{$source_site}=$thread;
			}
		}

		my @done=();
		my @failed=();

		sleep(3);
		for my $sitename (keys %threads) {
			my $result=$threads{$sitename}->join();
			if($result ne 1) {
				push @failed,$sitename;
			}
			else {
				push @done,$sitename;
			}
		}

		if(scalar(@done)>0) {
			irc_msg($irc_msgs,sprintf('[GIMME] Done (%s secs)', stop_timer($key1, 1)));
		} else {
			irc_msg($irc_msgs,sprintf('[GIMME] Failed (%s secs)', stop_timer($key1, 1)));
		}

		if(1) {
			lock(%gimme_counter_total);
			lock(%gimme_counter_done);
			delete($gimme_counter_total{$result{'first_rel'}});
			delete($gimme_counter_done{$result{'first_rel'}});
		}
		return 1;

	}

	irc_msg($irc_msgs,sprintf('[GIMME] Done (%s secs)', stop_timer($key1, 1)));
	return 1;
}

# ------------------------------------------------------------------

# show added dump-sites and available source-sites
sub gimmehelp {
	my $use_irc_conn = shift;

	my ($res, $msg, @rows) = conquery_db("select upper(site),dump_path from sites where upper(status)='UP' and dump=1 and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[GIMME] no sites found, all sites down or misconfigured .)');
		return 0;
	}

	irc_msg($irc_msgs,'[GIMME] Available destination-sites for GIMME:');

	for my $out (@rows) {
		irc_msg($irc_msgs,sprintf('[GIMME] Site: %s, Path: %s',@$out[0],@$out[1]));
	}

	($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(status)='UP' and logins>0 order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[GIMME] no sites found, all sites down or misconfigured .)');
		return 0;
	}

	my @source=();
	for my $out (@rows) {
		push @source,@$out[0];
	}

	irc_msg($irc_msgs,sprintf('[GIMME] Available source-sites for GIMME (%s): %s',scalar(@source),join(', ',@source)));

	irc_msg($irc_msgs,'[GIMME] Done');
	return 1;
}

# ------------------------------------------------------------------

# call ginfo on site (if bot is gadmin) - check each user for creds + lastlogin
sub ginfo {
	my $site = uc(shift);
	my $use_irc_conn = shift;

	my $key1 = start_timer('ginfo');

	my $error=0;
	my @site=get_site_data($site,0,$use_irc_conn,0,0) or $error=1;
	if($error || scalar(@site) eq 1) {
		irc_msg($irc_msgs, sprintf('[%s] an error occured',$site));
		return 0;
	}
	my @s=connect_to_site($site[0],$site[1],$site[2],$site[3],$site[4],$site[5],0,0);
	if($s[0] eq 0) {
		irc_msg($irc_msgs, sprintf('[%s] cannot login (%s)',$site[1],$s[1]));
		return 0;
	}

	my $result=$s[0]->site('ginfo');
	my @out=$s[0]->message();
	if( (join('',@out)=~/not have access/i) || (join('',@out)=~/command disabled/i)) {
		disconnect($s[0],$site[1],0,0,0);
		irc_msg($irc_msgs,'[GINFO] no gadmin!');
		irc_msg($irc_msgs,'[GINFO] Done');
		return 1;
	}
	irc_msg($irc_msgs, '[GINFO]  User     |     Credits |          Up |        Down | Ratio |    Weekly | LastSeen');

	for my $line (@out) {

		my $user='';
		my $up='';
		my $down='';
		my $ratio='';
		my $weekly='';
		my $credits='';
		my $last='';

		my @data=split(/\|/,$line);
		if(scalar(@data) eq 9 && !($data[1]=~/Username/i)) {
			$user=trim($data[1]);
			$up=trim($data[3]);
			$down=trim($data[5]);
			$ratio=trim($data[6]);
			$weekly=trim($data[7]);

			my $tuser=trim($user);
			$tuser=~s/\+//i;

			my $result2=$s[0]->site(sprintf('user %s',$tuser));
			my @out2=$s[0]->message();
			for my $line2 (@out2) {
				if($line2=~/Credits: (.+) MB/i) {
					$credits=trim($1);
				}
				if($line2=~/Last seen:(.+)\|/i) {
					my @dates=split(/ /,trim($1));
					$last=sprintf('% 3s % 2s % 4s',$dates[2],$dates[3],$dates[5]);
				}
			}

			irc_msg($irc_msgs,sprintf('[GINFO] % 9s | % 8s MB | % 8s MB | % 8s MB | % 5s | % 6s MB | % 10s',$user,$credits,$up,$down,$ratio,$weekly,$last));
		}
	}

	disconnect($s[0],$site[1],0,0,0);
	irc_msg($irc_msgs,sprintf('[GINFO] Done (%s secs)', stop_timer($key1, 1)));
	return 1;
}

# ------------------------------------------------------------------

# call a custom command on a site
sub command {
	my $site = uc(shift);
	my $cmd = shift;
	my $use_irc_conn = shift;
	my $params = join(' ',@_);

	if($params ne '') {
		$params = ' '.$params;
	}

	my $allowed=0;
	for my $command (@allowed_commands) {
		if(uc($cmd) eq uc($command)) {
			$allowed=1;
			last if($allowed eq 1);
		}
	}

	if($allowed ne 1) {
		irc_msg($irc_msgs,sprintf('[CMD] unallowed command, must be one of %s',join(', ',@allowed_commands)));
		return 0;
	}

	my $key1 = start_timer('command');

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(status)='UP' and presite=1 and upper(site)=upper('$site') order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[CMD] site seems to be down or sending raw commands isnt allowed for that site .)');
	} else {

		for my $out (@rows) {
			$site=@$out[0];
		}

		my $error=0;
		my @s;
		my @site=get_site_data($site,0,$use_irc_conn,0,1) or $error=1;
		if($error || scalar(@site) eq 1) {
			irc_msg($irc_msgs, '[CMD] an error occured');
		} else {
			@s=connect_to_site($site[0],$site[1],$site[2],$site[3],$site[4],$site[5],0,0);
			if($s[0] eq 0) {
				irc_msg($irc_msgs, sprintf('[CMD] cannot login (%s)',$s[1]));
			} else {
				irc_msg($irc_msgs,sprintf('[CMD] %s: send \'%s%s\'',$site,$cmd,$params));
				my $result=$s[0]->site(sprintf("$cmd%s",$params));
				my @out=$s[0]->message();
				for my $line (@out) {
					if(!($line=~/Command Successful./i))
					{
						irc_msg($irc_msgs,sprintf('[CMD] %s',$line));
					}
				}
			}
		}
		disconnect($s[0],$site[1],0,0,0);
	}

	irc_msg($irc_msgs,sprintf('[CMD] Done (%s secs)', stop_timer($key1, 1)));
	return 1;
}

# ------------------------------------------------------------------

# show speeds + transfered volume for given site
sub show_speeds {
	my $site = shift;
	my $silent_mode = shift;
	my $use_irc_conn = shift;

	if($site ne '') {
		$silent_mode = 0;
	}

	# sitename given
	if($site ne '') {

		my ($res, $msg, @rows) = conquery_db("select upper(site),fxp_speeds_from,fxp_speeds_to from sites where site='$site' order by site");
		if(!$res) {
			irc_msg($irc_msgs,'[SQL] Error: '.$msg);
			return 0;
		}
		if(!scalar(@rows)) {
			irc_msg($irc_msgs,'[SPEEDS] sitename not found');
		} else {
			my $speeds_from = '';
			my $speeds_to = '';
			for my $out (@rows) {
				$site=@$out[0];
				$speeds_from=@$out[1];
				$speeds_to=@$out[2];
			}

			my @sites_from_arr = ($speeds_from ne '') ? split(/,/,$speeds_from) : ();
			my @sites_to_arr = ($speeds_to ne '') ? split(/,/,$speeds_to) : ();

			show_speeds_sub($site,'from',$use_irc_conn,@sites_from_arr);
			show_speeds_sub($site,'to',$use_irc_conn,@sites_to_arr);

		}
	}
	# total
	else {
		my ($res, $msg, @rows) = conquery_db("select fxp_speeds_from,fxp_speeds_to from sites order by site");
		if(!$res) {
			if($silent_mode eq 0) {
				irc_msg($irc_msgs,'[SQL] Error: '.$msg);
			}
			return 0;
		}
		if(!scalar(@rows)) {
			if($silent_mode eq 0) {
				irc_msg($irc_msgs,'[SPEEDS] no sites');
			}
		} else {
			my $total = 0;
			my $str = '';
			for my $out (@rows) {
				$str=@$out[0].((@$out[0] ne '' && @$out[1] ne '')?',':'').@$out[1];
				my @arr = ($str ne '') ? split(/,/,$str) : ();
				for my $row (@arr) {
					if($row=~/^([^ ]+):([0-9]+):([0-9\.]+)$/i) {
						$total+=$2;
					}
				}
			}

			my ($bytes,$size) = format_bytes_line($total);
			if($silent_mode eq 0) {
				irc_msg($irc_msgs,sprintf('[SPEEDS] total transfered %s %s since last reset',$bytes,$size));
			}
			else {
				return ($bytes, $size);
			}
		}
	}
	irc_msg($irc_msgs,'[SPEEDS] done');
	return 1;
}

# ------------------------------------------------------------------

# show speeds/volume for a single site
sub show_speeds_sub {
	my $site = shift;
	my $mode = shift;
	my $use_irc_conn = shift;
	my @data = @_;

	irc_msg($irc_msgs,sprintf('[SPEEDS] statistics for site %s, transferes \'%s\'',$site,$mode));
	if(scalar(@data) eq 0) {
		irc_msg($irc_msgs,'[SPEEDS] no data collected');
		return 0;
	}

	my $found=0;
	$site='';
	my $bytes='';
	my $speed='';
	my $size='';
	my $size2='';

	my $bytes_total=0;
	my $speed_total=0;
	my $first = 1;

	my %sorted;

	for my $row (@data) {
		if($row=~/^([^ ]+):([0-9]+):([0-9\.]+)$/i) {
			$found=1;
			$site =$1;
			$bytes=$2;
			$speed=$3;
			$size='Bytes';
			$size2='Bytes';

			if($first eq 0) {
				$speed_total = ($bytes_total + $bytes) / ((($bytes_total * $speed) + ($bytes * $speed_total)) / ($speed * $speed_total));
				$bytes_total = $bytes_total + $bytes;
			}
			else {
				$speed_total = $speed;
				$bytes_total = $bytes;
			}

			($bytes,$size) = format_bytes_line($bytes);
			($speed,$size2) = format_bytes_line($speed);

			irc_msg($irc_msgs,sprintf('[SPEEDS] %s (%s %s / %s %s/s avg)', $site,$bytes,$size,$speed,$size2));

			$first = 0;
		}
	}
	if($found eq 0) {
		irc_msg($irc_msgs,'[SPEEDS] no data collected');
		return 0;
	}
	else {
		($bytes_total,$size) = format_bytes_line($bytes_total);
		($speed_total,$size2) = format_bytes_line($speed_total);
		irc_msg($irc_msgs,sprintf('[SPEEDS] TOTAL: %s %s / %s %s/s avg',$bytes_total,$size,$speed_total,$size2));
	}
	return 1;
}

# ------------------------------------------------------------------

# update the stored speed/volume information for 2 sites
sub update_speeds {
	my $site_from = shift;
	my $site_to = shift;
	my $bytes = shift;
	my $speed = shift;

	if($bytes eq 0) {
		$bytes+=1;
	}
	if($speed eq 0) {
		$speed+=1;
	}

	my $speeds_from = '';
	my $speeds_to = '';

	# round 1, site_from moved to site_to, to_mode
	my ($res, $msg, @rows) = conquery_db("select upper(site),fxp_speeds_to from sites where site='$site_from' order by site");
	if(!$res) {
		return 0;
	}
	if(scalar(@rows)) {
		for my $out (@rows) {
			$site_from=@$out[0];
			$speeds_to=@$out[1];
		}
	}

	my @sites_to_arr_new = ();
	if($speeds_to eq '') {
		push(@sites_to_arr_new,sprintf('%s:%s:%s',$site_to,$bytes,$speed));
	}
	else {
		my @sites_to_arr = split(/,/,$speeds_to);
		my $found = 0;
		for my $row (@sites_to_arr) {
			if($row=~/^([^ ]+):([0-9]+):([0-9\.]+)$/i) {
				my $site = $1;
				my $total = $2;
				my $old_speed = $3;
				if($total eq 0) {
					$total+=1;
				}
				if($old_speed eq 0) {
					$old_speed+=1;
				}
				if(uc($site) eq uc($site_to)) {
					$found = 1;
					my $new_speed = ($total + $bytes) / ((($total * $speed) + ($bytes * $old_speed)) / ($speed * $old_speed));
					push(@sites_to_arr_new,sprintf('%s:%s:%s',$site,$total + $bytes,int($new_speed)));
				}
				else {
					push(@sites_to_arr_new,sprintf('%s:%s:%s',$site,$total,$old_speed));
				}
			}
			else {
				debug_msg(sprintf('malformed line: %s',$row));
			}
		}
		if($found eq 0) {
			push(@sites_to_arr_new,sprintf('%s:%s:%s',$site_to,$bytes,$speed));
		}
	}

	my $sites_to_string = join(',',@sites_to_arr_new);
	condo_db(sprintf("update sites set fxp_speeds_to='%s' where upper(site)='%s'",$sites_to_string,$site_from));


	# round 2, site_to received from site_from, from_mode
	($res, $msg, @rows) = conquery_db("select upper(site),fxp_speeds_from from sites where site='$site_to' order by site");
	if(!$res) {
		return 0;
	}
	if(scalar(@rows)) {
		for my $out (@rows) {
			$site_to=@$out[0];
			$speeds_from=@$out[1];
		}
	}
	my @sites_from_arr_new = ();
	if($speeds_from eq '') {
		push(@sites_from_arr_new,sprintf('%s:%s:%s',$site_from,$bytes,$speed));
	}
	else {
		my @sites_from_arr = split(/,/,$speeds_from);
		my $found = 0;
		for my $row (@sites_from_arr) {
			if($row=~/^([^ ]+):([0-9]+):([0-9\.]+)$/i) {
				my $site = $1;
				my $total = $2;
				my $old_speed = $3;
				if($total eq 0) {
					$total+=1;
				}
				if($old_speed eq 0) {
					$old_speed+=1;
				}
				if(uc($site) eq uc($site_from)) {
					$found = 1;
					my $new_speed = ($total + $bytes) / ((($total * $speed) + ($bytes * $old_speed)) / ($speed * $old_speed));
					push(@sites_from_arr_new,sprintf('%s:%s:%s',$site,$total + $bytes,int($new_speed)));
				}
				else {
					push(@sites_from_arr_new,sprintf('%s:%s:%s',$site,$total,$old_speed));
				}
			}
			else {
				debug_msg(sprintf('malformed line: %s',$row));
			}
		}
		if($found eq 0) {
			push(@sites_from_arr_new,sprintf('%s:%s:%s',$site_from,$bytes,$speed));
		}
	}

	my $sites_from_string = join(',',@sites_from_arr_new);
	condo_db(sprintf("update sites set fxp_speeds_from='%s' where upper(site)='%s'",$sites_from_string,$site_to));

	return 1;
}

# ------------------------------------------------------------------

# show currently running fxp processes
sub show_fxps {
	my $use_irc_conn = shift;

	if(1) {
		lock(%current_fxps);
		if(scalar(keys %current_fxps) eq 0) {
			irc_msg($irc_msgs,'[FXPS] there are no fxp processes running at the moment');
		}
		else {
			for my $current (keys %current_fxps) {
				my @line = split(/:/,$current);
				irc_msg($irc_msgs,sprintf('[FXPS] %s to %s, file: %s, position %i of %i',$line[0],$line[1],$line[2],$line[3],$line[4]));
			}
		}
		irc_msg($irc_msgs,'[FXPS] done');
	}
	return 1;
}

# ------------------------------------------------------------------

# auto trade a rel to another site - check against rules
sub auto_trade {
	my $rel = shift;
	my $genre1 = shift;
	my $genre2 = shift;
	my $use_irc_conn = shift;

	if($enable_trading ne 1) {
		irc_msg($irc_msgs,'[TRADING] disabled!');
		return 0;
	}

	my $key1 = start_timer('auto_trade');

	my %running;
	my $index = 0;
	for my $line (@trading_rules) {
		$index++;
		my @arr = @$line;
		my $site1='';
		my $daydir1='';
		my $site2='';
		my $daydir2='';

		if(!exists($running{$arr[0]})) {

			my ($res, $msg, @rows) = conquery_db(sprintf("select upper(site),today_dir from sites where upper(site)=upper('%s') and upper(status)=('UP') and today_dir != ''",$arr[0]));
			if(!$res) {
				return 0;
			}
			if(scalar(@rows)) {
				($site1, $daydir1) = @{$rows[0]};
			}

			($res, $msg, @rows) = conquery_db(sprintf("select upper(site),today_dir from sites where upper(site)=upper('%s') and upper(status)=('UP') and today_dir != ''",$arr[1]));
			if(!$res) {
				return 0;
			}
			if(scalar(@rows)) {
				($site2, $daydir2) = @{$rows[0]};
			}

			if($site1 eq '' ||$site2 eq '' or $daydir1 eq '' or $daydir2 eq '') {
				irc_msg($irc_msgs,sprintf('[TRADING] no trading for thread %s, sites down or misconfigured',$index));
			}
			else {
				my $genre = $arr[2];
				my $rules_ok = $arr[3];
				my $rules_false = $arr[4];
				my $matched = 1;

				# genres
				if(!($genre1.$genre2 =~ /^$genre$/i)) {
					debug_msg(sprintf('genre false: %s: %s',$genre1.$genre2,$genre));
					$matched = 0;
				}
				# ok rules
				if($matched eq 1) {
					for my $rule (@$rules_ok) {
						if(!($rel=~/$rule/i)) {
							debug_msg(sprintf('rules_ok false: %s: %s',$rel,$rule));
							$matched = 0;
						}
					}
				}
				# false rules
				if($matched eq 1) {
					for my $rule (@$rules_false) {
						if($rel=~/$rule/i) {
							debug_msg(sprintf('rules_false true: %s: %s',$rel,$rule));
							$matched = 0;
						}
					}
				}

				if($matched eq 1) {
					my $thread = threads->create('fxp_rel',$site2,$site1,$rel,$use_irc_conn,1,$daydir2,$daydir1,0,0,0);
					$running{$site1}=$thread;
				}
				else {
					irc_msg($irc_msgs,sprintf('[TRADING] no trading to site %s, release doesnt match the ruleset %s',$site1,$index));
				}
			}
		}
	}

	sleep(3);

	for my $site (keys %running) {
		my $res=$running{$site}->join();
	}

	irc_msg($irc_msgs,sprintf('[TRADING] done (%s secs)', stop_timer($key1, 1)));
	return 1;
}

# ------------------------------------------------------------------

# add a new site - create empty record
sub add_site {
	my $site = uc(shift);
	my $use_irc_conn = shift;

	if(!($site=~/^([0-9a-z]+)$/i)) {
		irc_msg($irc_msgs,'[ADD] sitename doesnt match the rules, only chars 0-9/A-Z can be used!');
		return 0;
	}

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(site)='$site' order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(scalar(@rows)) {
		irc_msg($irc_msgs,'[ADD] site already added!');
		return 0;
	} else {
		condo_db(sprintf("insert into sites (site,fxp_speeds_from,fxp_speeds_to,speed_index,%s) values('%s',%s)",join(',', @db_fields), $site,"'','','','','','','','','','','','','','','','','','','','','','','','',''"));
		irc_msg($irc_msgs,'[ADD] done');
		return 1;
	}
}

# ------------------------------------------------------------------

# delete an added site
sub del_site {
	my $site = shift;
	my $use_irc_conn = shift;

	if(!($site=~/^([0-9a-z]+)$/i)) {
		irc_msg($irc_msgs,'[ADD] sitename doesnt match the rules, only chars 0-9/A-Z can be used!');
		return 0;
	}

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(site)='$site' order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[DEL] site doesnt exist!');
		return 0;
	} else {
#		condo_db(sprintf("update sites set status='down',presite=0,dump=0,logins=0 where upper(site)='%s'",$site));
		condo_db(sprintf("delete from sites where upper(site)='%s'",$site));
		irc_msg($irc_msgs,'[DEL] done (Yes, it is REALLY deleted now)');
#		irc_msg($irc_msgs,'[DEL] done (ok, not really deleted - but set some flags to 0 - so the site cannot be used anymore)');
		return 1;
	}
}

# ------------------------------------------------------------------

# set a value for site-details
sub set_site {
	my $site = shift;
	my $use_irc_conn = shift;
	my $param = shift;

	my $val = join(' ', @_);

	if(!($site=~/^([0-9a-z]+)$/i)) {
		irc_msg($irc_msgs,'[SET] sitename doesnt match the rules, only chars 0-9/A-Z can be used!');
		return 0;
	}

	if(exists_in_arr($param, @db_fields) eq 0) {
		irc_msg($irc_msgs,sprintf('[SET] unknown parameter, must be one of: %s',join(', ',@db_fields)));
		return 0;
	}

	if((exists_in_arr($param, @db_binary_fields) eq 1) && ($val ne '0' && $val ne '1')) {
		irc_msg($irc_msgs,sprintf('[SET] value for %s must be binary',$param));
		return 0;
	}

	if($param eq 'ssl_status') {
		if(exists_in_arr($val, @db_ssl_values) eq 0) {
			irc_msg($irc_msgs,sprintf('[SET] value for ssl_status must be one of: %s',join(', ', @db_ssl_values)));
			return 0;
		}
	}

	my ($res, $msg, @rows) = conquery_db("select upper(site) from sites where upper(site)='$site' order by site");
	if(!$res) {
		irc_msg($irc_msgs,'[SQL] Error: '.$msg);
		return 0;
	}
	if(!scalar(@rows)) {
		irc_msg($irc_msgs,'[SET] site doesnt exist!');
		return 0;
	} else {
		condo_db(sprintf("update sites set %s = '%s' where upper(site)='%s'",$param,$val,$site));
		irc_msg($irc_msgs,'[SET] done');
		return 1;
	}
}
