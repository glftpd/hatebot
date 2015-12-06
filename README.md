# HateBot v0.98-24 SQLite - 28.Oct.2005
# (c) Jonas 2003+2004+2005 .)
# multithreaded 100% perl prebot with fxp/pre/dupe/search features ...

 additional perl modules:
 ------------------------
	sudo cpan NET::IRC
	sudo cpan Unix::Time
	sudo cpan Time:HiRes
	sudo cpan DBD::SQLite
	sudo cpan IO::Socket::SSL
	sudo cpan Net::FTP

 additional ssl wrapper to be able to connect to ssl ircd - as perl irc module cannot handle ssl itself properly
 ------------------------
 stunnel -> www.stunnel.org
 winsslwrap -> use google .)

 major change in this release:
 ------------------------
 - removed mysql support - replaced by sqlite - db is now hold in a single file - no mysql-server neccessary
 - additional_searchdirs and sorted_mp3 now supports a koma-separated list of paths
 - lots of bugfixes with error-replies from ftpd (file-exists, out-of-space and so on)
 - and again improvements and bugfixes for !pre gimme/search-routines
 - rewrote !pre showstats
 - first steps to support ssl-fxp ... 

 todo:
 ------------------------
 - support of ssl-fxp

 install
 ------------------------
 - install all needed perl-modules - check if sqlite is installed and running
 - edit the config-file, setup all ip's / ports for ircd
 - start the bot - setup ur sites .. 
 

 all commands:
 ------------------------
!sites help:

	!sites status: shows up/down-status of all sites
	!sites show SITE: shows added details for SITE
	!sites add SITE: adds new (empty) record for a new site - fill data with !sites set SITE parameter values
	!sites del SITE: deletes the site from the database
	!sites set SITE param values: sets the detailed information for the site record:
	 - sitename STRING: real sitename
	 - status STRING: up/down-status of the site
	 - bnc STRING: ip:port,ip:port,ip:port - sets all bncs
	 - presite INT: 0/1 - site is presite (or not)
	 - dump INT: 0/1 - site is dumpsite (or not)
	 - dump_path STRING: full path to the sites incoming/request dir
	 - sorted_mp3 STRING: full path to the sites mp3-sorted-by-artist dir
	 - today_dir STRING: full path to the sites mp3-today dir
	 - prepath STRING: full path to the groups pre-dir
	 - precommand STRING: command to pre there - like 'pre RELEASENAME mp3'
	 - ssl_status STRING: nope/required - sets if ssl is needed or not
	 - login STRING: prebots login
	 - passwd STRING: prebots passwd
	 - source_sites STRING: sites to use as source for spreading/gimme (sorted list like 'SITE1,SITE2...')
	 - logins INT: max logins (with allowed download) - usually 2
	 - speed_index INT: 1-255, the higher the more important for the global spread or gimme process

!pre help:

	!pre test SITE: tests login and predir, tries all bnc's, if no sitename is given, it checks all sites
		- if site is a presite then it checks the predir, if site is a dumpsite then it checks dump-path, if site is external source then only login-test is made

	!pre status: shows up/down-status of all sites
		- sorted by site-categories (presite, dumpsite, sourcesite)

	!pre sysinfo - shows system information / overview
		- pls notice: total fxp amounts are from current database-values, if u delete sites - then the statistic changes .)

	!pre show SITE: shows added details for SITE
		- same command as !sites show SITE
		- login/passwd is never shown
		- bncs are only shown for presites

	!pre speeds SITE: shows avg speeds from/to other sites (gets updated with every fxp process) - or total amound of traffic if no sitename is given
		- this list isnt sorted .)

	!pre showstats SITE: tries to show the bot's stats on SITE, if no sitename is given, it checks all sites
		- tries to collect stats (credits, ratio in predir, section) - matches only on a few standard-statlines

	!pre check SITE RELEASE: checks if RELEASE is complete and ok on SITE
		- a release is complete if it has a sfv + a nfo + one or more mp3 files + a site-complete-tag + no mp3-missing tag

	!pre checkall RELEASE: checks if RELEASE is complete and ok on all sites
		- release has to be complete on all sites + sum of mp3 files (filesizes) must be the same on all sites

	!pre prelist SITE RELEASE: shows releases laying in predir on SITE (or all sites), or content of RELEASE in predir
		- that command only lists the directory - it doesnt check if these rels laying there are completed

	!pre dirlist SITE DIRECTORY SEARCHPHRASE: shows files and folders matching searchphrase (if given)
		- just a basic dirlist, but you can filter the output --> !pre dirlist XXX /today NUKED-

	!pre fxp SITE1 SITE2 RELEASE: fxp's a release from SITE1 to SITE2 (from predir to predir)
		- only works for files / releases that are laying in the predirs
		- can fxp a release or a file, if its a release - then it must be complete

	!pre chainfxp SITE1 SITE2 .. SITEx RELEASE: fxp's a release chained from SITE1 to SITE2, SITE2 to SITE3 and so on (from predir to predir, if no RELEASE given, it transfers complete predir
		- can fxp a release or a file or if none given it simply fxps all releases found in the predirs
		- works like a chain - from site1 to site2 to site3 to sitex

	!pre spreadfxp SITE1 SITE2 .. SITEx RELEASE: fxp\'s a release from SITE1 to SITE2, SITE1 to SITE3 and so on (from predir to predir, if no RELEASE given, it transfers complete predir
		- can fxp a release or a file or if none given it simply fxps all releases found in the predirs
		- uses site1 as source for all other sites, so it fxps from site1 to site2, then from site1 to site3 .. 

	!pre spread RELEASE: spreads the release automatically to all sites to prepare a pre
		- checks all sites and searches the ones where the release is laying and is complete
		- uses source_sites and speed_index and num_logins to calculate speed-paths to fxp the release from all available sites to all sites missing the release

	!pre trade RELEASE GENRE: tries to trade RELEASE from current daydir to all sites that match the rulesets
		- can be used to fxp a release directly after the pre to other sites and/or archives/dumps, u can define several filters - check the config-file

	!pre speedtest SITE FILE: takes a FILE from SITE and fxps to all presites to test speeds (removes after fxp)
		- place mp3 file (at least 5mb) in the predir of SITE, it will take it and checks all speeds from/to all other sites

	!pre fxps: shows all currently running fxp processes (spread, gimme, fxp and so on)
		- list isnt sorted nor is there any ETA shown .. 

	!pre reset: stops spread and resets the bot
		- kills fxps and spreads

	!pre kill SITE: kills an existing connection to SITE
		- works only with glftpd

	!pre pre RELEASE RELEASERNAME GENRE: finally pre's the release on all sites that are up, registers for user 'releasername'
		- connects to all presites, checks if release is complete, sends all sites on wait, then it sends a broadcast that pre's on all sites exactly at the same time (the site-pre-command is sent to all sites within very few millisecs)

	!pre del SITE RELEASE: tries to delete the RELEASE on SITE
	!pre delall RELEASE: tries to delete the RELEASE on all sites
	!pre delnfo SITE RELEASE: tries to delete the RELEASE on SITE
	!pre delallnfo RELEASE: tries to delete the RELEASE on all sites

	!pre updnfo SITE RELEASE: tries update nfo for RELEASE on all sites (updates release-date in nfo + takes nfo from source SITE if given)
		- checks all sites (alphabetical list) - searches nfo file for the release - downloads it - replaces the date in the nfo file - and uses that new nfo as source for all sites to replace the old nfo file

	!pre search SITENAME RELEASE: searches the release on SITE (or all sites if no sitename given), checks if its really there (max 10 results per site)
		- tries to find the release on the site using following methods:
			- uses site-search
			- uses site-dupe
			- uses sorted-by-artist dirs
			- uses sorted-by-artist/various dirs
			- uses today-dir

	!pre gimme SOURCE DESTINATION RELEASE: searches for RELEASE on SOURCE or all added sites and delivers to SITE (use !pre gimmeHELP first
		- tries to find the release on all sites - keeps the fastest source-sites for the destination site, then it fxps from max number of sites at the same to destination

	!pre gimmeHELP: shows available source-sites and destination-sites for GIMME
		- short info what sites/dumps/sources are up

	!pre dupe keyword1 keyword2 ... keyword5 : makes a dupecheck
		- see config file

	!pre tracks RELEASE : lists all tracks in RELEASE
		- see config file

	!pre tracksearch TRACK : lists all releases containing TRACK
		- see config file

	!pre ginfo SITE: checks creds (ginfo+user) for all added users in your group on SITE
		- works only if prebot-slot is gadmin .)

	!pre cmd SITE command param1 param2.. : sends raw command to site
		- u can define the allowed raw-commands in the config-file



!archive help:
	!archive status: shows up/down-status of all sites
		- sorted by site-categories (presite, dumpsite, sourcesite)

	!archive scan site startdir: scans the archive, creates new index file
		- scans a site, creates a new index file - that gets used for advanced archive search

	!archive search keyword1 keyword2 .. keywordx: searches index-files for releases matching the keywords, u can get the rels with the !pre gimme command
		- searches in all index-files for a release matching your keywords

	!archive stopscan: stops a currently running scan
		- aborts a scan, writes the index file for all rels found so far



bugs:
	- not all commands work properly with other ftpd's than glftpd -> dont use such crap ftpd's
