# -- dont change these lines ---
package prebot_config;
require Exporter;
@ISA = qw(Exporter);
@EXPORT = qw($debug $ftp_timeout $ftp_timeout_high $ftp_debug $ftp_use_statlist @complet_tags $enable_trading 
	@trading_rules $nfo_date_line $nfo_name @allowed_commands $irc_debug $irc_Nick $irc_Server $irc_Ircname 
	$irc_Port $irc_Username $irc_Password $irc_SSL $irc_channel $irc_passwd $help_per_msg @hidden_files 
	@dupecheck_rels @dupecheck_tracks @dupecheck_tracksearch $ftp_use_progress
	$use_blow $blowkey $max_sim_commands $irc_msg_delay $use_register_line $register_line $first_run $max_spreading_threads 
	$yapb_active $yapb_command $yapb_source $yapb_target $yapb_target2 $local_address);

# ------------------------------------------------------------------
# --- SETTINGS
# ------------------------------------------------------------------

# set local listening address in case there are more than one
$local_address = '1.2.3.4';

# creates the database - disable after done
$first_run = 0;


# global debug setting
$debug = 0;

# max sim. executed commands
$max_sim_commands = 20;

# max sim. fxp processes for the auto-spread, 3 to 5 is always a good value
$max_spreading_threads = 5;

# max timeout for ftp connections
$ftp_timeout = 90;
# max timeout for ftp connections with time-expensive commands (site-search / site-dupe etc)
$ftp_timeout_high = 150;
# debug mode for ftp connections - enable at own risk!
$ftp_debug = 0;
# use progressbar or exact filenames/statistics - for gimme-mode only - 
$ftp_use_progress = 1;
# use 'stat -la' or regular dirlist
$ftp_use_statlist = 1;

# ------------------------------------------------------------------
# site-complete-tags
# a mp3 release is complete if:
# - 1x sfv is present
# - 1x nfo is present
# - one or more .mp3 are present
# - none of the files contains the string 'mp3-missing'
# - the site created an site-complete-tag (file/link/subdir) in the releases directory
# if one of these fails - the release is counted as incomplete - spread/pre/gimme/search etc - will not work with that

# regular expressions - 2 regex per entry ....
@complet_tags = (
	['[\[\]]',' COMPLETE '],			# line contains [ or ] + the word ' COMPLETE '
	['[\[\]]',' DONE'],					# line contains [ or ] + the word ' DONE'
	['[\[\]]','100%'],					# line contains [ or ] + the word '100%'
	['[\[\]]','\[COMPLETE'],			# line contains [ or ] + the word '[COMPLETE'
	['[\[\]]','\[.*TESTED_OK'],			# line contains [ or ] + the word '[ TESTED_OK'
	['[\[\]]','\[Release_complete\]'],	# line contains [ or ] + the word '[Release_complete]'
	['[\[\]]','-COMPLETE'],				# line contains [ or ] + the word '-COMPLETE'
	['[\[\]]','--FINISHED--'],			# line contains [ or ] + the word '--FINISHED--'
	['[ ]+'  ,' COMPLETE'],				# line contains spaces + the word ' COMPLETE'
	['[ ]+'  ,'complete!'],				# line contains spaces + the word 'complete!'
	['[ ]+'  ,' - FiNiSHED - '],		# line contains spaces + the word ' - FiNiSHED - '
	['[ ]+'  ,'\[100%\]'],				# line contains spaces + the word '[100%]'
	['[ ]+'  ,'\] - \['],				# line contains spaces + the word '] - ['
	['[ ]+'  ,' complete '],			# line contains spaces + the word ' complete '
	['[ ]+'  ,'\(done!\)'],			# line contains spaces + the word ' complete '
	['[\[\]]',' cOMPLETE '],		#line contains [ or ] + the word ' cOMPLETE '
);

# ------------------------------------------------------------------
# auto-trading section, if enabled - release will be spreaded to sites directly after pre
$enable_trading = 0;

# settings for auto-trading, today_dir must be set on source and destination sites
# 1st = destination site,
# 2nd = source site
# 3rd = genre (regex)
# 4th .. = regex to match releasename (all given regex have to match)
# 5th .. = regex to NOT match releasename (if one matches --> false)

@trading_rules = (
#	['YYY',		'XXX',	'Electronic',	['-2004-AMOK'],	['bootleg','live','CDM','CDS','VLS']],	# electronic rels, 2004 only, no live crap
#	['XXX',		'AAA',	'Pop',			['-2004-KOMA'],	['bootleg','live','CDM','CDS','VLS']],	# electronic rels, 2004 only, no live crap
#	['ZZZZ',	'VV',	'.*',			['.*-2005-AMOK'],	['bootleg','live','VA-','KOMA']],	# all rels, 2005 only, no live, no va
	['TT',		'XX',	'.*',			['.*-AMOK'],	['bootleg','live','VA-','KOMA']],		# all rels, all years, no live, no va, no koma rels
);

# ------------------------------------------------------------------
# the bot is able to update the date in the nfo files on all sites - if it knows the form the date is stored in the nfo
# example - the line in the nfo is:
#     Rel.Date: 12/04/2004        Genre.....: Ambient

#$nfo_date_line = 'Rel.Date: ([^ ]+)[ ]*Genre.....';
$nfo_name = '.nfo';

# ------------------------------------------------------------------
# line to announce the release in the pre-channel, can be used by other bots to register/log the release
# example: '!log {rel} {releaser} {genre}'
$use_register_line = 1;
$register_line = '!dbrelease {rel}';

# ------------------------------------------------------------------
# allowed raw commands, can be sent via !pre cmd COMMAND param1 param2..

@allowed_commands = (
	"dupecheck",
	"dupe",
	"search",
	"locate",
	"stats",
	"vers",
	"mp3dupe",
	"alldupe",
	"dupecheck 0day",
	"vcddupe",
	"dupecheck mp3deep",
	"stat",
	"msg",
	"nukestatus",
	"ginfo",
	"tracks",
	"tagline"
);

# ------------------------------------------------------------------
# hidden files - bot doesnt list hidden files - so configure manually

@hidden_files = (
	'.message',
	'.date',
	'.crc',
	'.speed'
);

# ------------------------------------------------------------------
# IRC module

$irc_debug	=	0;
$irc_Nick	=	'hatebot';			# nickname to use
$irc_Server	=	'irc.efnet.org';		# ircd to use
#$irc_Server	=	'127.0.0.1';			# local ip in case you use stunnel
$irc_Ircname	=	'hatebot';			# ircname/realname to use
$irc_Port	=	6667;				# ircd port
$irc_Username	=	'hatebot';			# ident/username to use
$irc_Password	=	'';			# server passwd
$irc_SSL	=	0;					# leave it to 0 - perl lib doesnt support ssl ircd very well
$irc_passwd	=	"mychankey";			# channel key/passwd
$irc_channel	=	'#mychan';			# channel to join
$help_per_msg	=	1;					# send !sites help / !pre help per msg to requesting user
$irc_msg_delay	=	0;					# secs to wait after each line that gets msged to irc

# ------------------------------------------------------------------
# IRC blowfish

$use_blow		=	1;					# use blowfish for irc
$blowkey		=	'myuniquefishkeywithsixtyfivecharactersnomoreandnoneless!';		# blowkey

# ------------------------------------------------------------------
# dupechecking

# for the 3 main dupecheck commands - simply define a site where its implemented - and the command to use there
@dupecheck_rels			=	("DUPE",	"mp3dupe");
@dupecheck_tracks		=	("DUPE",	"tracks");
@dupecheck_tracksearch	=	("DUPE",	"dupecheck mp3deep");

# configure the outputline for yapb3
# probably not needed anymore since hatebot is able to ssl fxp
$yapb_active	=	0;
$yapb_command	=	'&fxp';
$yapb_source	=	'source';
$yapb_target	=	'target1';
$yapb_target2	=	'target2';

# --- END OF SETTINGS ---
1;
