#!/usr/bin/perl -W
############################################################################
# REOBack - reoback.pl
# $Id$
############################################################################
#
# REOBack Simple Backup Solution
# http://sourceforge.net/projects/reoback/
#
# Copyright (c) 2001, 2002 Randy Oyarzabal (techno91<at>users.sourceforge.net)
#
# Other developers and contributors:
#    Andy Swanner      (andys6276<at>users.sourceforge.net)
#    Richard Griswold  (griswold<at>users.sourceforge.net)
#    Nate Steffenhagen (frankspikoli<at>users.sourceforge.net)
#    Anthony L. Awtrey, SCP Patch
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Library General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
#
###########################################################################
#
#             NO USER SERVICABLE PARTS BEYOND THIS POINT!
#
###########################################################################
#
use strict;

# SET CONSTANTS
###########################################################################

my $VERSION     = "Pre 1.1";  # REOBack version number
my $DATESTAMP   = `date +%Y%m%d`;   # Current date in format: 20010409
my $DATESTAMPD  = `date +%Y-%m-%d`; # Current date in format: 2001-04-09
my $TIMESTAMP   = `date +%I%M%p`;   # Current time in format: 0945PM
my $EXT         = "\.tgz";          # Tar file extension
my @VALID_OPTIONS = qw(host backupdays files tmpdir datadir localbackup 
                    keeplocalcopy remotebackup rbackuptype localmount remotehost 
                    remotepath remoteuser remotepasswd tarcommand tarfileincl 
                    tarfileexcl nfscommand smbcommand uselog4perl consolepriority
                    log4perlconfig screenprintsenabled);

# Since I can't seem to conditionally "use" Log::Log4perl::Level, define
# priorities manually.
my $NONE = 0;
my $TRACE = 5000;
my $DEBUG = 10000;;
my $INFO = 20000;
my $WARN = 30000;
my $ERROR = 40000;
my $FATAL = 50000;

# GLOBAL VARIABLES
###########################################################################
my %config;             # Hash containing REOBack configuration data.
my $cfgFile;            # Config file passed to REOBack
my $fstat;              # Counter and last full backup time.
my $archFiles;          # Used for auto deletions.
my $startTime = time(); # Current time in seconds.
my $endTime;            # Time progam completed in seconds.
my $xferTime = 0;       # Time it took to transfer files.
my $lastFull;           # Last full backup in seconds.
my $backupType;         # Type of backup, "full" or "incremental".
my $bCounter;           # Backup counter.
my $localPath;          # Local path for archives.
my $remotePath;         # Remote path for archives.
my $localMount;         # Local mount path for remote back-ups.
my $forceFull;          # Flag for Full Update
my $logger;             # Log4perl logging instance
my $priority;           # Console logging priority

# Parse configuration and load variables to the hash table
&parseConfig();

&setLoggingPriority($config{"consolepriority"});

if ($config{"uselog4perl"}) {
  if ( findModule( "Log/Log4perl.pm" ) ) {
      require Log::Log4perl;
      Log::Log4perl->init($config{"log4perlconfig"}); 
      $logger = Log::Log4perl->get_logger();
    } else {
      print("Log4Perl is enabled, but not installed. Turning it off now, logging to screen instead...\n");
      $config{"uselog4perl"} = 0;
    }
}

# From this point on, the logger can be called safely.
logger($INFO, "REOBack version $VERSION started.");

# Check to make sure that required options are defined in the setting file
my $configIsComplete = 1;
foreach (@VALID_OPTIONS) {
  if (!exists $config{$_}) {
     $configIsComplete = 0;
     logger($ERROR,"Configuration option: \"$_\" not found in $cfgFile.");
  }
}
if (!$configIsComplete) {
  logDie("Possible cause, you may be using and out-of-date settings file.  Aborting...");
}

# Determine what type of backup to perform
&backupType();

# Make sure that dirs exist (localmount and localbackup are checked below)
if ( not -e $config{"tmpdir"} ) {
  &mkdirp( $config{"tmpdir"}, 0700 ) or
    logDie("Unable to create 'tmpdir' directory '$config{'tmpdir'}': $!");
  logger($INFO, "Created $config{'tmpdir'} directory.");
}
if ( not -e $config{"datadir"} ) {
  &mkdirp( $config{"datadir"}, 0700 ) or
    logDie("Unable to create 'datadir' directory '$config{'datadir'}': $!");
   logger($INFO, "Created $config{'datadir'} directory.");
}

# Setup paths to archives
$localPath  = $config{"localbackup"}."/".$DATESTAMPD."/";
$remotePath = $config{"remotepath"}."/".$DATESTAMPD."/";
$localMount = $config{"localmount"}."/".$DATESTAMPD."/";

# Remove extra slashes in paths
$localPath  =~ s/\/+/\//g;
$remotePath =~ s/\/+/\//g;
$localMount =~ s/\/+/\//g;

logger($DEBUG, "\$localPath = $localPath");
logger($DEBUG, "\$remotePath = $remotePath");
logger($DEBUG, "\$localMount = $localMount");

# Create local archive location if needed.
if ( !-e $localPath ) {
  &mkdirp( $localPath, 0700 ) or
    logDie("Unable to create directory for archives '$localPath': $!");
  logger($INFO, "Created $localPath directory.");
}

# Check for remote backup
if ( $config{"remotebackup"} ) {
  my $tmpCMD; # Full mount command
    # Prepare for NFS or SMB transfers
    if ( ($config{"rbackuptype"} eq "NFS") || ($config{"rbackuptype"} eq "SMB") ) {
      use File::Copy;
      if ( $config{"rbackuptype"} eq "NFS" ) {
        $tmpCMD = $config{"nfscommand"}." ".$config{"remotehost"}.":".
        $config{"remotepath"}." ".$config{"localmount"};  			
     }elsif ( $config{"rbackuptype"} eq "SMB" ){
        $tmpCMD = $config{"smbcommand"}." username=".$config{"remoteuser"}.",password=".
        $config{"remotepassword"}." ".$config{"remothpath"}." ".$config{"localmount"};
     }
     printToScreen("Mounting $config{'rbackuptype'} volume in progress...");
     logger($DEBUG, "Remote backup type: $config{'rbackuptype'}");
     logger($DEBUG, "Mount command: $tmpCMD");
     if ( system ( $tmpCMD ) ) {
       logDie("$config{'rbackuptype'} mount command failed!\n\nAborting backups...");
     }
     # Create remote archive location if needed.
     if ( !-e $localMount ) {
       &mkdirp( $localMount, 0700 ) or
       logDie("Unable to create directory for $remotePath backup '$localMount': $!");
      }
     printToScreen("done.\n\n");
  }
  # Prepare for SCP transfers
  elsif ( $config{"rbackuptype"} eq "SCP" ) {
    if ( findModule( "Net/SCP.pm" ) ) {
      require Net::SCP;
    } else {
      logDie("You must install the Net::SCP to perform a remote backup via SCP.");
    }
  }

  # Prepare for FTP transfers
  elsif ( $config{"rbackuptype"} eq "FTP" ) {
    if ( findModule( "Net/FTP.pm" ) ) {
      use IO::Socket::SSL;
      require Net::FTP;
      Net::FTP->import();
    } else {
      logDie("You must install the Net::FTP to perform a remote backup via FTP.");
    }
  }

  # Invalid remote backup type
  else {
    logger($ERROR, "Invalid remote backup type $config{'rbackuptype'}.  Ignoring.");
  }
}

# Start backup process
printToScreen("Archiving in progress...\n\n");
&processFiles();

# Delete old backups that are no longer need
&processDeletions();

# Close remote volume if necessary
if ( $config{"remotebackup"} ) {
  if ( ($config{"rbackuptype"} eq "NFS") || ($config{"rbackuptype"} eq "SMB") ) {
    logger($INFO, "Unmounting...umount $config{'localmount'}");
    system ( "umount ".$config{"localmount"} );
  }
}

# Record new status values
open  FILESTATUS, ">$fstat";
print FILESTATUS $bCounter . "," . $lastFull;
close FILESTATUS;

if ( $config{"keeplocalcopy"} ) {
  printToScreen("All local archives were saved in $localPath\n");
}
else {
  rmdir ( $localPath ) or
  logWarn("Unable to remove local directory: $!");
  printToScreen("All local archives were removed.\n");
}

$endTime = time() - $startTime;
logger($DEBUG, "\$endTime = $endTime");

printToScreen("Total transfer time: ".timeCalc( $xferTime )."\.\n");
printToScreen( "Overall backup time: ".timeCalc( $endTime )."\.\n\n");
logger($INFO, "REOBack version $VERSION ended.");
exit;

# END MAIN #############################

# Description:  Routine for checking if a module is installed
# Parameter(s): "Module to check for"
# Returns:      Non-zero if module is found
sub findModule {
  my $moduleName = $_[0];

  logger($DEBUG, "findModule() - \$moduleName = $moduleName");

  foreach ( @INC ) {
    if ( -f "$_/$moduleName" ) { return 1; }
  }
  return 0;
}

# Description:  Routine for creating the tar archive.
# Parameter(s): "Filename of archive to create",
#               "Name(s) of include/exclude file(s)",
#               "Non-zero if exclude file"
# Returns:      Nothing
sub archiveFile{
  my $fileName = $_[0];      # Filename (full path) of archive to create.
  my $listName = $_[1];      # Name(s) of include/exclude file(s).
  my $skipFile = $_[2];      # Non-zero if exclude file.
  my $tarCmd;                # Variable to hold tar command

  logger($DEBUG, "archiveFile() - \$fileName = $fileName");
  logger($DEBUG, "archiveFile() - \$listName = $listName");
  logger($DEBUG, "archiveFile() - \$skipFile = $skipFile");

  # Create the tar archive.  Use this method instead of system() so that we
  # can filter out the "Removing leading `/'" messages.  '2>&1' redirects
  # error messages from tar to stdout so we can catch them.
  if ( $skipFile ) {
    $tarCmd = "$config{'tarcommand'} $fileName $config{'tarfileexcl'} $listName.excl $config{'tarfileincl'} $listName.incl";
    open PROC, "$tarCmd 2>&1|";
  }
  else {
    $tarCmd = "$config{'tarcommand'} $fileName $config{'tarfileincl'} $listName.incl";
    open PROC, "$tarCmd 2>&1|";
  }
  foreach ( <PROC> ) {
    if ( $_ !~ /Removing leading `\/'/ ) { print $_; }
  }
  logger($DEBUG, "archiveFile() - Tar command ran: \$tarCmd = $tarCmd");
  close PROC;
}

# Description:  Routine for transferring a file to the remote backup
#               location.
# Parameter(s): "filename to transfer"
# Returns:      Nothing
sub transferFile{
  my $fullPath = $_[0];      # Full path of local archive.
  my $fileName = $_[1];      # Filename to transfer.
  my $startTime = time();
  my $endTime;
  my $errFlag = 0;

  logger($DEBUG, "transferFile() - \$fullPath = $fullPath");
  logger($DEBUG, "transferFile() - \$fileName = $fileName");

  printToScreen("    Transferring archive: ".$fileName."...\n");
  if ( $config{"rbackuptype"} eq "SCP" ) {
     my $scp; # SCP connection object.
     $scp = Net::SCP->new( $config{"remotehost"}, $config{"remoteuser"} ) or
        logDie("Unable to connect to remote host! : $!");
     # Recursively make directory
     $scp->mkdir($remotePath);
     # Transfer tar file to remote location
     $scp->put($fullPath,$remotePath) or $errFlag = 1;
  }
  elsif ( $config{"rbackuptype"} eq "FTP" ) {
    my $ftp; # FTP connection object.
    $ftp = Net::FTP->new( $config{"remotehost"}, Debug => 1, Passive => 1 ) or
      logDie("Unable to connect to remote host! : $!");
    $ftp->login( $config{"remoteuser"},$config{"remotepasswd"} ) or
      logDie("Unable to login to remote host! : $!" );
    $ftp->binary;
    $ftp->mkdir( $remotePath, 1 );  # Create parent directories if necessary
    $ftp->cwd( $remotePath ) or
      logDie("Unable to change to remote directory! : $!\n");

    # Transfer tar file to remote location
    $ftp->put( $fullPath ) or $errFlag = 1;
    $ftp->quit;
  }
  else {
    copy( $fullPath,$localMount.$fileName ) or $errFlag = 1;
  }
  $endTime = time() - $startTime;
  $xferTime = $xferTime + $endTime;
  if ( $errFlag ) {
    printToScreen("FAILED! : $!\n\n");
  }
  else {
    printToScreen("done.\n\n");
  }
}

# Description:  Routine for recursively traversing a directory
#               and all of its subdirectories in order to build
#               a list of files to do a incremental or full backup.
# Parameter(s): "directory to traverse",
#               "Name(s) of include/exclude file(s)",
#               "type: 0=full, 1=inc",
#               "array ref of files/dirs to skip",
# Returns:      0 = no files to backup, 1 = files to backup
#               0 = no files to skip,   1 = files to skip
sub scanDir{
  my $curdir   = $_[0]; # Name of current directory
  my $bname    = $_[1]; # Name(s) of include/exclude file(s)
  my $btype    = $_[2]; # Backup type: 0 = FULL, 1 = INCREMENTAL
  my $skip     = $_[3]; # Array ref for files/dirs to skip

  logger($DEBUG, "scanDir() - \$curdir = $curdir");
  logger($DEBUG, "scanDir() - \$bname = $bname");
  logger($DEBUG, "scanDir() - \$btype = $btype");

  my $name;             # Name of an entry in current directory
  my $fname;            # Fully qualified name of an entry in current directory
  my @dirs;             # List of directories in this directory
  my $skipFlag    = 0;  # Temporary flag to indicate there is a file to skip
  my $haveFile    = 0;  # Non-zero if have file to backup
  my $skipFile    = 0;  # Non-zero if have file to skip
  my $subHaveFile = 0;  # Non-zero if subdirectory has file to backup
  my $subSkipFile = 0;  # Non-zero if subdirectory has file to skip

  # Check all entries in this directory
  opendir RT, $curdir or logDie("opendir \"$curdir\": $!");
  while ( $name = readdir RT ) {
    # Ignore this filename if it is '.' or '..'.
    if ( ( $name eq "\." ) or ( $name eq "\.\." ) ) { next; }

    # Fully qualify the filenamename, and remove redundant slashes.
    $fname = "$curdir/$name";
    $fname =~ s/\/+/\//g; # Added to remove extra "/" if backing up "/"

    # Check if we should skip this filename.
    foreach ( @{ $skip } ) {
      if ( $fname =~ $_ ) {
        &addToExclude( $fname, $bname );
        $skipFile = 1;
        $skipFlag = 1;
        last;
      }
    }

    # Reset skip flag if necessary
    if ( $skipFlag ) { $skipFlag = 0; }

    # If this filename is a directory, add it to the list of directories.
    elsif ( ( -d $fname ) and ( not -l $fname ) ) {
      # Don't push the fully qualified name
      push @dirs, $name;
    }

    # If this filename is a file or symlink, check if it should be excluded
    # from an incremental backup.
    elsif ( ( -f $fname ) or ( -l $fname ) ) {
      if ( ( $btype ) and ( &excludeFile( $fname ) ) ) {
        &addToExclude( $fname, $bname );
        $skipFile = 1;
      } else {
        $haveFile = 1;
      }
    }

    # Exclude anything else.
    else {
      &addToExclude( $fname, $bname );
      $skipFile = 1;
    }
  }
  closedir RT;

  # Recursively call this function on each directory in this directory
  foreach ( @dirs ) {
    ( $subHaveFile, $subSkipFile ) =
      &scanDir( "$curdir/$_", $bname, $btype, $skip );

    # Exclude subdirectory if it doesn't have any files to back up
    # Always include subdirectory on full backup
    if ( ( $subHaveFile == 0 ) and ( $btype ) ) {
      &addToExclude( "$curdir/$_", $bname );
      $skipFile = 1;
    }

    # Otherwise indicate that subdirectories have files
    else {
      if ( $subSkipFile == 1 ) { $skipFile = 1; }
      $haveFile = 1;
    }
  }

  # If this directory is new since last full backup, indicate we have files
  # even if we don't
  if ( ( $btype ) and ( not &excludeFile( $curdir ) ) ) {
    $haveFile = 1;
  }

  # Return non-zero if we or our sub dirs have a file to back up
  return $haveFile, $skipFile;
}

# Description:  Routine for parsing the configuration file into
#               a key-value associative array.
# Parameter(s): none.
# Returns:      Nothing
sub parseConfig {
  my $option;
  my $doReset = 0;
  my $argNum = @ARGV;
  $forceFull = 0;
  if ( ( $argNum == 0 ) || ( $argNum > 2 ) ) {
    &usage;
    exit;
  }
  $option = $ARGV[0];
  if ( $argNum == 1 ) {
    if ( $option =~ /^-./ ){    	
      if ( $option =~ /^-h$|^--help$|^--usage$/ ) {
        &usage;
        exit;
      }
      elsif ( $option =~ /^-v$|^--version$/ ) {
        &version;
        exit;
      }
      else {
        &usage;
        exit;
      }
    }
    elsif ( -f $option ) {
      $cfgFile = $option;
    }
    else {
      &usage;
      exit;
    }    
  }
  if ( $argNum == 2 ) {
    if ( $option =~ /^-f$|^--full$/ ) {
      $forceFull = 1;
      if ( -f $ARGV[1] ) {
        $cfgFile = $ARGV[1];
      }
      else {
        &usage;
        exit;
      }
    }
    elsif ( $option =~ /^-r$|^--reset$/ ) {
      $doReset = 1;
      if ( -f $ARGV[1] ) {
        $cfgFile = $ARGV[1];
      }
      else {
        &usage;
        exit;
      }
    }	
    else {
      &usage;
      exit;
    }
  }

  if ( -e $cfgFile ) {
	chmod ( 0600, $cfgFile);
  }

  my ( $var, $val );
  open( CONF, "<$cfgFile" ) || logDie("Cannot find config file: $!");
  while ( <CONF> ) {
    chomp;                              # no newline
    if ( $_ !~ /^\s*ftppasswd\s*=/ ) {  # don't remove comments in FTP passwords
      s/#.*//;                          # no comments
    }
    s/^\s+//;                           # no leading white
    s/\s+$//;                           # no trailing white
    next unless length;                 # anything left?
    ( $var, $val ) = split( /\s*=\s*/, $_, 2 );
    $config{$var} = $val;               # load config value into the hash
  }
  close( CONF );
  if ($doReset) {
    &resetBackups;
    exit;
  }
}

# Description:  Routine for for determining what type of backup to
#               perform.
# Parameter(s): none.
# Returns:      Nothing
sub backupType {
  $fstat = $config{"datadir"}."status.dat";
  $archFiles = $config{"datadir"}."archives.dat";

  my $backupDays;     # Number of days to keep backups.
  my @bstatus;        # Array containing counter and last full backup time.
                      # Key:
                      # 0 = Backup counter, 1 = Last full backup
  my $lTime;          # Temporary variable for time conversion.

  # Prepare date and time stamps
  chomp( $DATESTAMP );
  chomp( $DATESTAMPD );
  chomp( $TIMESTAMP );

  $backupDays = $config{"backupdays"};

  # Initialize default values
  $bCounter = 1;
  $backupType = "full";
  $lastFull = $startTime;

  if ( -e $fstat ) {
    # Status file exists, check to see what type of backup to
    # perform.
    open ( FILESTATUS, "<$fstat" );
    @bstatus = split ( ",",`cat $fstat` );

    # Increment backup counter
    $bCounter = $bstatus[0] + 1;
    $lastFull = $bstatus[1];

    # For EXAMPLE backupDays = 7
    ####################################################################
    # 1 = FULL                        8  = FULL
    # 2 = INCREMENTAL                 9  = INCREMENTAL
    # 3 = INCREMENTAL                 10 = INCREMENTAL
    # 4 = INCREMENTAL                 11 = INCREMENTAL
    # 5 = INCREMENTAL                 12 = INCREMENTAL
    # 6 = INCREMENTAL                 13 = INCREMENTAL
    # 7 = INCREMENTAL ( DELETE 8-14 )   14 = INCREMENTAL ( DELETE 1-7 )
    ####################################################################
    if ( ( $bCounter - 1 ) % $backupDays ) {
      $backupType = "incremental";
    }

    # Reached the end of backup cycle ( backup days * 2 )
    # reset counter and do FULL backup.
    elsif ( $bCounter > ( $backupDays * 2 ) ) {
      $bCounter = 1;
      $lastFull = $startTime;
    }
    # Counter is equal to backup days + 1
    else {
      $lastFull = $startTime;
    }
  }

  if ($forceFull) {
  		$backupType = "full";
  }
  
  $lTime = localtime( $lastFull );
  &version;
  printToScreen("\nRunning backup on $config{'host'}.\n");
  printToScreen("Backup number $bCounter of ".( $backupDays*2 )." (backup days x 2)\n");
  if ($forceFull){
    printToScreen("Forced FULL backups requested via command-line parameter.\n");
  }
  if ( $config{'remotebackup'} ) {
    printToScreen("Performing $backupType backup via $config{'rbackuptype'}\n");
  } else {
    printToScreen("Performing $backupType backup on local system\n");
  }
  printToScreen("Last full backup: $lTime\n\n");

  logger($DEBUG, "backupType() - \$bCounter = $bCounter");
  logger($DEBUG, "backupType() - \$backupType = $backupType");
  logger($DEBUG, "backupType() - \$lastFull = $lastFull");
}

# Description:  Process file containing definitions of files/directories to
#               backup
# Parameter(s): none.
# Returns:      Nothing
sub processFiles {
  # In the lists below, there is one entry for each "File:" directive.  This
  # entry is the archive name for @arcfile, and a list of files/directories
  # to archive or skip for @arc and @skip.

  my @arcfile;   # List of names of archives to create
  my @arc;       # List of lists of files/directories to archive
  my @skip;      # List of lists of files/directories to skip
  my $fileName;  # Temporary variable to hold a filename
  my $i = -1;    # Index into @arc and @skip lists

  # Open file  containing definitions of files/directories to backup
  open FILE, "<$config{'files'}" or
    logDie("Cannot open \"$config{'files'}\": $!");

  # Process the file
  foreach ( <FILE> ) {
    if ( ( $_ !~ /^#/ ) and ( $_ !~ /^[ \t]*$/ ) ) { # Skip comments and blanks
      chomp $_;                                      # Remove trailing newline

      # File: directive - starts a new archive
      if ( /^file:/i ) {
        $fileName = $';                  # Grab name of file
        $fileName =~ s/\s+//g;           # Strip leading whitespace
        push @arcfile, $fileName;        # Push onto list of archives to create
        $i++;                            # Increment archive counter
      }

      # Skip: directive - file/directory to skip.  Add beginning and end of
      # line characters to file/directory name for later use in scanDir.
      elsif ( /^skip:/i ) {
        $fileName = $';                          # Grab name of file
        $fileName =~ s/\s+//g;                   # Strip leading whitespace
        push @{ $skip[$i] }, '^'.$fileName.'$';  # Push onto current skip list
      }

      # File/directory to archive
      else {
        push @{ $arc[$i] }, $_;             # Push onto current archive list
      }
    }
  }
  close FILE;

  # Backup each archive read from the file
  $i = 0;                                   # Reset index
  foreach ( @arcfile ) {
    backupMisc( $_, $arc[$i], $skip[$i] );  # Pass refs to arc and skip lists
    $i++;                                   # Increment index to next archive
  }
}

# Description:  Routine to back up files in files.cfg
# Parameter(s): "name for backup",
#               "array ref for files/dirs to archive",
#               "array ref for files/dirs to skip"
# Returns:      Nothing
sub backupMisc {
  my $bName = $_[0];    # Name for backup
  my $arc   = $_[1];    # Array ref for files/dirs to archive
  my $skip  = $_[2];    # Array ref for files/dirs to skip

  my $haveFile     = 0; # Non-zero if have file to backup
  my $skipFile     = 0; # Non-zero if have file to skip
  my $tempHaveFile = 0; # Non-zero if scanDir finds file to backup
  my $tempSkipFile = 0; # Non-zero if scanDir finds file to skip
  my $btype;            # Backup type as a number (0 = FULL, 1 = INCREMENTAL)
  my $fileName;         # Name(s) of include/exclude file(s)
  my $fullPath;         # Full path to tar file to create
  my $tarName;          # Nmae of tar file to create

  logger($DEBUG, "backupMisc() - \$bName = $bName");
  logger($DEBUG, "backupMisc() - \$arc = $arc");

  printToScreen("  Working on $bName...\n");

  # Initialize some variables
  $btype    = $backupType eq "incremental" ? 1 : 0; # Backup type as a number.
  $fileName = $config{"tmpdir"}.$bName;

  foreach ( @{ $arc } ) {
    # For a directory, call scanDir to recursively back it up
    if ( ( -d $_ ) and ( not -l $_ ) ) {
      ( $tempHaveFile, $tempSkipFile ) =
        &scanDir( $_, "$fileName.excl", $btype, $skip );

      # If any files to backup, add this directory in include file and set
      # the flag indicating this archive has files to backup
      if ( $tempHaveFile ) {
        # Add this file to list of files to include
        &addToInclude( $_, "$fileName.incl" );
        $haveFile = 1;
      }
      # If any files to backup, set the flag indicating this archive has
      # files to skip
      if ( $tempSkipFile ) { $skipFile = 1; }
    }

    # For a file or symlink, simply add it to the list of files to backup
    # NOTE: if the user includes a file and also includes a skip directive,
    # this will not catch the skip directive!
    elsif ( ( -f $_ ) or ( -l $_ ) ) {
      # Check if we should skip this filename.
      if ( ( $btype ) and ( &excludeFile( $_ ) ) ) {
        # NOTE:  may not have to add to exclude, may just be able to skip
        &addToExclude( $_, "$fileName.excl" );
        $skipFile = 1;
      } else {
        &addToInclude( $_, "$fileName.incl" );
        $haveFile = 1;
      }
    }
  }

  # Close include and exclude files
  close INCLFILE;
  close EXCLFILE;

  # Create archive if there are any files to backup
  if ( $haveFile ) {
    # Create name of tar file and full path to tar file
    $tarName = $config{"host"}."-".$bName."-".$backupType."-".
        $DATESTAMP."-".$TIMESTAMP."\.".$bCounter.$EXT;
    $fullPath = $localPath.$tarName;

    # Tar backup files and record it.  Need to let archiveFile() know if we
    # have a list of files to skip to prevent an error on the tar command.
    printToScreen("    Archiving ".$bName."...\n");
    &archiveFile( $fullPath, $fileName, $skipFile );
    &recordArchive( $tarName );

    # Transfer if needed.
    if ( $config{"remotebackup"} ) { transferFile( $fullPath, $tarName ); }

    # Delete if needed.
    if ( !$config{"keeplocalcopy"} ) {
      truncTar( $fullPath );
      unlink ( $fullPath );
    }
  }
  else {
    printToScreen("    No new or changed files since last full backup for $bName.\n\n");
  }

  # Remove temporary files
  if ( $haveFile ) { unlink ( "$fileName.incl" ); }
  if ( $skipFile ) { unlink ( "$fileName.excl" ); }
}

# Description:  Routine to check if a file should be excluded from an
#               incremental backup.
# Parameter(s): "file to check"
# Returns:      0 if file should not be excluded.
#               1 if file should be excluded.
sub excludeFile {
  my $file     = $_[0]; # File to check
  my $lastmod;          # Last modified date

  # Get last modify time for the file (or symlink)
  $lastmod = ( lstat( $file ) )[9];
  if ( ( not $lastmod ) or ( $lastmod > $lastFull ) ) {
    # File was modified since last full backup.  Do not exclude it.
    return 0;
  }
  # File was not modified since last full backup so exclude it.
  return 1;
}

# Description:  Routine to add a filename to a file that lists all
#               files to exclude from a backup.
# Parameter(s): "name of file to add",
#               "name of file to write to",
# Returns:      Nothing.
sub addToExclude {
  my $file     = $_[0]; # File to check
  my $fileName = $_[1]; # Filename to write files to

  # Open exclude file if it isn't already open, and push the name on
  # the list of exclude file names.
  if ( not fileno EXCLFILE ) {
    open EXCLFILE, ">>$fileName" or logDie("open \"$fileName\": $!");
  }

  # Collapse multiple slashes into one before writting file name to file
  $file =~ s/\/+\//\//g;

  # Write the name of the file to exclude.
  print EXCLFILE "$file\n";
}

# Description:  Routine to add a filename to a file that lists all
#               files to include from a backup.
# Parameter(s): "name of file to add",
#               "name of file to write to",
# Returns:      Nothing.
sub addToInclude {
  my $file     = $_[0]; # File to check
  my $fileName = $_[1]; # Filename to write files to

  # Open exclude file if it isn't already open, and push the name on
  # the list of exclude file names.
  if ( not fileno INCLFILE ) {
    open INCLFILE, ">>$fileName" or logDie("open \"$fileName\": $!\n");
  }

  # Collapse multiple slashes into one before writting file name to file
  $file =~ s/\/+\//\//g;

  # Write the name of the file to exclude.
  print INCLFILE "$file\n";
}

# Description:  Routine to names of archives
# Parameter(s): "name of file to add"
# Returns:      Nothing.
sub recordArchive{
  my $file = $_[0];    # Tar file to record

  # Record archives
  open ARCHIVES, ">>$archFiles" or logDie("Cannot open archive file ".
    "$archFiles (check your 'datadir' configuration setting)");

  if ( $config{"remotebackup"} ) {
    if ( $config{"rbackuptype"} eq "FTP" ) {
      print ARCHIVES "$bCounter,$localPath,$remotePath,$file\n";
    }
    else {
      print ARCHIVES "$bCounter,$localPath,$config{'localmount'}".
        "$DATESTAMPD/,$file\n";
    }
  }
  else {
    print ARCHIVES "$bCounter,$localPath,/,$file\n";
  }
  close ARCHIVES;
}

# Description:  Routine to convert time from a number to a string
# Parameter(s): "Time as a number"
# Returns:      "Time as a string"
sub timeCalc{
  my $endTime = $_[0];

  if ( $endTime > 3600 ) {
    $endTime = ( $endTime / 3600 );
    $endTime = sprintf "%.2f", $endTime;
    $endTime = $endTime." hour(s)";
  }
  elsif ( $endTime > 60 ) {
    $endTime = ( $endTime / 60 );
    $endTime = sprintf "%.2f", $endTime;
    $endTime = $endTime." minute(s)";
  }
  else {
    $endTime = sprintf "%.2f", $endTime;
    $endTime = $endTime." seconds(s)";
  }
  return $endTime;
}

# Description:  Routine to delete old archives
# Parameter(s): None
# Returns:      Nothing
sub processDeletions{
  my $ftp;             # Object for FTP connection.
  my @records;         # Tar files to process.
  my @record;          # A single tar file.
  my $backupDays;      # Number of days to keep backups.
  my $firstDel;
  my $secondDel;
  my $file;
  my $ldir;
  my $rdir;
  my $tmpFile = $config{"tmpdir"}."archives.tmp";
  my ( $upper, $lower, $buNum );

  $backupDays = $config{"backupdays"};
  $firstDel = $backupDays+1;
  $secondDel = $backupDays*2;

  if ( ( $bCounter == $backupDays ) or ( $bCounter == $secondDel ) ) {
    printToScreen("Deletions of old back-ups in progress...");

    open ( TARS, $archFiles );
    @records = <TARS>;
    close TARS;

    open ( TMPFILE, ">$tmpFile" );

    # i.e. if counter is 7, delete 8-14
    if ( $bCounter == $backupDays ) {
      $lower = $firstDel;
      $upper = $secondDel;
    }
    # otherwise delete 1-7
    else {
      $lower = 1;
      $upper = $backupDays;
    }
    # Login to remote host if necessary
    if ( $config{"remotebackup"} ) {
      if ( $config{"rbackuptype"} eq "FTP" ) {
        $ftp = Net::FTP->new( $config{"remotehost"}, Debug => 0 ) or
          logWarn("  Unable to connect to remote host! : $!" );
        $ftp->login( $config{"remoteuser"},$config{"remotepasswd"} ) or
          logWarn("  Unable to login to remote host! : $!" );
      }
    }
    foreach ( @records ) {
      chomp;
      @record = split ( ",",$_ );
      $buNum = $record[0];
      $ldir = $record[1];
      $rdir = $record[2];
      $file = $record[3];

      if ( ( $buNum >= $lower ) and ( $buNum <= $upper ) ) {

        # Delete local backup.
        if ( $config{"keeplocalcopy"} ) {
          truncTar( $ldir.$file );
          logger($INFO, "Deleting local file: ".$ldir.$file);
          unlink ( $ldir.$file ) or
            logWarn("    Unable to delete local file! : $!" );
          rmdir ( $ldir );
        }

        # Delete from remote host.
        if ( $config{"remotebackup"} ) {
          if ( $config{"rbackuptype"} eq "FTP" ) {
            $ftp->cwd( $rdir ) or
              logWarn("    Unable to change to remote directory! : $!" );
            logger($INFO, "Deleting remote file: $file");
            $ftp->delete( $file ) or
              logWarn("    Unable to delete remote file! : $!" );
            $ftp->rmdir( $rdir );
          }
          elsif ( ($config{"rbackuptype"} eq "NFS") || ($config{"rbackuptype"} eq "SMB") ) {
            truncTar( $rdir.$file );
            logger($INFO, "Deleting remote file: ".$rdir.$file);
            unlink ( $rdir.$file ) or
              logWarn("    Unable to delete remote file! : $!" );
            rmdir ( $rdir );
          }
        }
      }
      else {
        # Write left over entries back to file.
        print TMPFILE $_."\n";
      }
    }
    close TMPFILE;

    logger($INFO, "Deleting file: $archFiles");
    unlink( $archFiles ) or logDie ( "    Unable to delete $archFiles!: $!" );
    move( $tmpFile, $archFiles ) or
      logDie ( "    Unable to rename $tmpFile to $archFiles!: $!" );

    # Close connection if necessary
    if ( $config{"remotebackup"} && ($config{"rbackuptype"} eq "FTP") ) {      
      $ftp->quit;
    }
    print "done.\n\n";
    if ( $config{"rbackuptype"} eq "SCP" ) {
    	printToScreen("Files on the SCP host were NOT deleted.\n");
    }	
  }
}

# Description:  Routine to create directory, similar to 'mkdir -p'
# Parameter(s): "path to directory to create"
# Returns:      0 if failed, non-zero if successful.
sub mkdirp {
  my $fullpath;                         # Full path to create
  my @path      = split /\/+/, shift;   # Components of path for new directory
  my $perm      = shift;                # Permission for new directory
  foreach ( @path ) {
    $fullpath .= "$_/";                 # Build up path to directory
    mkdir ( $fullpath, $perm );
  }
  if ( ! -d $fullpath ) { return 0; }   # Fail if directory does not exist
  return 1;                             # Success
}

# Description:  Truncate tar file.  Needed for versions of Perl that do not
#               support large files.  Note that both the filesystem and tar
#               have to support large files in order to create the large
#               archive in the first place.
# Parameter(s): "Archive to truncate"
# Returns:      Nothing
sub truncTar {
  my $fileName = $_[0];

  # Truncate the archive by simply archiving the file containing definitions
  # of files/directories to backup.  This file *should* be less than 2GB.
  open PROC, $config{"tarcommand"} . " $fileName $config{'files'} 2>&1|";
  foreach ( <PROC> ) {
    if ( $_ !~ /Removing leading `\/'/ ) { print $_; }
  }
  close PROC;
}

# Description:  Routine for resetting backups.
# Parameter(s): None
# Returns:      Nothing
sub resetBackups{
  $fstat = $config{"datadir"}."status.dat";
  $archFiles = $config{"datadir"}."archives.dat";
  if (-f $fstat || -f $archFiles) {
    unlink ($fstat) or logDie ("Unable to delete $fstat");
    unlink ($archFiles) or logDie ("Unable to delete $archFiles");
    printToScreen("Backups were sucessfully reset.\n");
  } 
  else {
    printToScreen("Status files not found.  Backups already reset.\n");
  }
}

# Description:  Routine for logging fatal errors.
# Parameter(s): "Message to log"
# Returns:      Nothing
sub logDie{
  my $message = shift;
  if ($config{"uselog4perl"}) {
    $logger->logdie($message);
  } else {
    die($message . "\n");
  }
}

# Description:  Routine for logging warning messages. 
# Parameter(s): "Message to log"
# Returns:      Nothing
sub logWarn{
  my $message = shift;
  if ($config{"uselog4perl"}) {
    $logger->logwarn($message);
  } else {
    warn($message);
  }
}

# Description:  Routine for logging messages.
# Parameter(s): "Priority string",
#               "Message to log"
# Returns:      Nothing
sub logger{
  my $lPriority = $_[0];
  my $message = $_[1];
  if ($config{"uselog4perl"}) {
    $logger->log($lPriority, $message);
  } else {
    if ($lPriority >= $priority) {
     print($message . "\n");
    }
  }
}

# Description:  Routine for printing a message to the scren.
# Parameter(s): "Message to print to screen"
# Returns:      Nothing
sub printToScreen{
  my $message = shift;
  if ($config{"screenprintsenabled"}) {
     print($message);
  }
}

# Description:  Routine for setting the console logging priority
# Parameter(s): "Priority string"
# Returns:      Nothing
sub setLoggingPriority{
  my $priorityString = shift;
  if ($priorityString eq "TRACE") {
    $priority = $TRACE;
  } elsif ($priorityString eq "DEBUG") {
    $priority = $DEBUG;
  } elsif ($priorityString eq "INFO") {
    $priority = $INFO;
  } elsif ($priorityString eq "WARN") {
    $priority = $WARN;
  } elsif ($priorityString eq "ERROR") {
    $priority = $ERROR;
  } elsif ($priorityString eq "FATAL") {
    $priority = $FATAL;
  } else {
    $priority = $NONE;
  }
}

# Description:  Print version information
# Parameter(s): None
# Returns:      Nothing
sub version {
  print "REOBack version $VERSION; distributed under the GNU GPL.\n";
}

# Description:  Print usage information
# Parameter(s): None
# Returns:      Nothing
sub usage {
  print << "END_OF_INFO";

REOBack Simple Backup Solution ver. $VERSION
(c) 2001, 2002 Randy Oyarzabal (techno91<at>users.sourceforge.net)

Usage: reoback.pl [options] [<configfile>]

Options:
-f, --full              Force full backup. (<configfile> required)
-h, --help, --usage     Display this help information.
-r, --reset             Reset backups to start at 1. (<configfile> required)
-v, --version           Display version information.

See http://sourceforge.net/projects/reoback/ for project info.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Library General Public
License for more details.

You should have received a copy of the GNU General Public License along
with this program; if not, write to the Free Software Foundation, Inc., 59
Temple Place - Suite 330, Boston, MA 02111-1307, USA.

END_OF_INFO
}


##############################################################################
# $Id$
###############################################################################
#
# $Log$
# Revision 1.27  2007/11/22 06:31:03  techno91
# - Added optional log4perl support or screen logging by priority
# - Added ability to reset backups from the command-line option
#
# Revision 1.25  2007/11/21 00:00:14  techno91
# - Added existence check for ALL config options
# - Overwriting rev. 1.23 log4perl changes because it need to be
#   configurable so that users are not forced to use it if they don't have the
#   log4perl libraries.
#
# Revision 1.24  2007/11/20 05:12:51  andys6276
# - Added checks for configuration options
# - Added support for log4perl
#
# Revision 1.23  2007/11/17 21:53:09  techno91
# - Samba support added
#
# Revision 1.22  2007/11/17 20:29:58  techno91
# - Streamlined rev. 1.20 changes, force full, and SCP
#
# Revision 1.21  2007/11/16 22:47:10  techno91
# - Prep code for stream-line process of 1.1 release
# - Removed code for features not used yet.
# - Removed config definition from constants.
# - Fixed the commenting of the CVS logs on the bottom.
#
# Revision 1.20  2006/11/15 05:21:46  andys6276
# - Added -f/--full flag to force full backups
# - Added check for Linux/Darwin/OpenBSD/FreeBSD to deal with different versions of tar
# - Added SCP code
#
# Revision 1.19  2002/04/02 05:50:11  griswold
#
# - Check the mtime field (field 9) from lstat instead of the ctime field
#   (field 10), since ctime doesn't seem to be set correctly on SMB mounted
#   filesystems.
#
# Revision 1.18  2002/04/02 02:24:31  griswold
#
# - Fixed bug with exclude file name when excluding individual files.
#
# Revision 1.17  2002/03/24 01:23:14  techno91
# - Added and escape for "@" in @user... in in the END_OF_INFO print lines.
#
# Revision 1.16  2002/03/23 15:30:11  techno91
# - Added 2002 in copyright info.
#
# Revision 1.15  2002/03/23 14:46:43  techno91
# - Release number typo, changed release from 4 to 3.
#
# - Changed tar parameters from "cpfz" to "-cpzf" for compatability with
#   other flavors of UNIX i.e. AIX.
#
# Revision 1.14  2002/03/23 03:28:12  griswold
#
#
# - Check if Net::FTP is installed when doing an FTP remote backup,
#   * Fixes bug 463642
#
# - Automatically create directories from settings.conf if they do not
#   exist.  Parent directories are created if necessary.
#   * First half of fix for bug 482380
#
# - Better error checking and reporting.
#   * Second half of fix for bug 482380
#
# - Removes large (>2GB) archives, even if Perl does not have large file
#   support.  This relies on the tar command having large file support
#   enabled, but both the file system and the tar command have to have
#   large file support to create a file larger than 2GB.
#   * Fixes bug 521843
#
# - Skip removing comments for FTP passwords.  REOBack will now treat
#   everything after 'ftppasswd = ' as a password, except for leading and
#   trailing whitespace.  For example, for the line
#   'ftppasswd   =   my##password   ', REOBack will extract 'my##password'
#   as the FTP password.
#   * Fixes bug 506178
#
# - Correctly handle the case where there are no files to skip.
#
# - Fixed a bug with checking for the last modification time for symbolic
#   links.
#
# - Perl regular expressions (wild cards) for Skip: directives.  For
#   example, to skip all files and directories in your home directory that
#   start with a dot, you can use:
#
#     Skip: /home/myself/\..*
#
#   Wondering what '\..*' does?  The leading backslash, '/', tells REOBack
#   (actually Perl) to treat the next dot, '.', as a literal dot.  The
#   third dot tells Perl to match any character, and the asterisk, '*',
#   tells Perl to perform the match zero or more times.
#
# - Suppress "Removing leading `/'" message from tar.
#
# - Prints correct backup type.
#
# - Prints version each time it is run.
#
# - Creates fewer temporary files.
#
# - General code streamlining and cleanup.
#
# - Removed version reoback.pl 1.14 and 1.15 from SourceForge, since there
#   were minor problems with these versions.
#
# Revision 1.13  2001/11/15 03:49:41  techno91
# - Major bug fix.  Richard applied a fix to preserve directory permissions
#   upon restore by changing the algorithm of tar to take an exclude file.
#
# - I made some changes to prevent creating emty archives upon incremental
#   backups by adding a global boolean $foundFiles.
#
# Revision 1.12  2001/08/24 03:09:22  techno91
# - Richard applied a fix to properly process "Skip:" definitions
#   when backing up the root directory ("/").
#
# Revision 1.11  2001/08/20 20:05:40  techno91
# - Added a check before using Net::FTP to prevent errors.
#
# Revision 1.10  2001/08/20 04:14:54  techno91
# - Changed the version and add disclaimer in "sub usage".
#
# Revision 1.9  2001/08/20 02:30:55  techno91
# - Fixed some typos in preparation for 1st release.
#
# Revision 1.8  2001/08/18 18:58:57  techno91
# - Edited copyright notice headers.
#
# Revision 1.7  2001/08/18 06:43:59  techno91
# - Cleaned code to prevent temporary files from cluttering root directory
#   when program is run from a cron job.
#
# - Removed conf directory and moved files.cfg to files.conf.sample in
#   the docs directory.
#
# Revision 1.6  2001/08/18 06:14:23  techno91
# - Cleaned code to prevent temporary files from cluttering root directory
#   when program is run from a cron job.
#
# - Removed conf directory and moved files.cfg to files.conf.sample in
#   the docs directory.
#
# Revision 1.5  2001/08/17 21:42:13  techno91
# - Configuration file is now passed as a parameter to reoback.pl.  This way
#   it can be used dynamically by many users on one system.
#
# - Added functionality to define individual archives by defining them
#   in a central location. i.e. files.cfg.  See documentation on formatting.
#
# - Depreciated support for individual MySQL and PostGreSQL backups.  All
#   backups are now defined in a user supplied file like "files.cfg".
#
# Revision 1.4  2001/08/08 21:48:30  techno91
# Initial load into CVS.
#
