#!/usr/bin/perl -w
############################################################################
# REOBack - reoback.pl
# $Id$
############################################################################
#
# REOBack Simple Backup Solution
# http://sourceforge.net/projects/reoback/
#
# Copyright (c) 2001 Randy Oyarzabal (techno91@users.sourceforge.net)
#
# Other developers and contributors:
#    Richard Griswold
#    Nate Steffenhagen (frankspikoli@users.sourceforge.net)
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

my $VERSION	= "1.0 Release 2";
my $DATESTAMP   = `date +%Y%m%d`;  #Current date in format: 04092001
my $DATESTAMPD  = `date +%Y-%m-%d`;#Current date in format: 04092001
my $TIMESTAMP   = `date +%I%M%p`;  #Current time in format: 0945PM
my $TARCMD      = "tar cpfz";
my $NFSCMD	= "mount -o rw,soft,intr,wsize=8192,rsize=8192";
my $EXT         = "\.tgz";

# GLOBAL VARIABLES
###########################################################################
my %config;

my $fstat;				# Counter and last full backup time.
my $archFiles;				# Used for auto deletions.
my $startTime = time();			# Current time in seconds.
my $endTime;    # Time progam completed in seconds.
my $xferTime=0;	# Time it took to transfer files.
my $lastFull;   # Last full backup in seconds.
my $backupType; # Type of backup, "full" or "incremental".
my $bCounter;   # Backup counter.
my $localPath;	# Local path for archives.
my $remotePath;	# Remote path for archives.
my $nfsPath;	# NFS path for archives.
my $ftp;        # Object for FTP connection.
my @skipDirs;	# Global for directories to skip per archive.
my $foundFiles; # Global for determining if files are found for backup.

# Determine what type of backup to perform
&backupType;

$localPath = $config{"localbackup"}.$DATESTAMPD."\/";
$remotePath = $config{"remotepath"}.$DATESTAMPD."\/";
$nfsPath = $config{"localmount"}.$DATESTAMPD."\/";

# Create local archive location if needed.
if (!-e $localPath){
   mkdir ($localPath, 0700);
}

# Mount NFS volume if necessary.
if ($config{"remotebackup"}){
   if ($config{"rbackuptype"} eq "NFS"){
      print "Mounting NFS volume in progress...";
      use File::Copy;  # We only need this if NFS backups are performed.
      my $tmpCMD = $NFSCMD." ".$config{"remotehost"}.":".$config{"remotepath"}." ".$config{"localmount"};
      if (system ($tmpCMD)) {
         print "Failed!\n\n";
         die ("Aborting backups...\n");
      }
      # Create NFS archive location if needed.
      if (!-e $nfsPath){
         mkdir ($nfsPath, 0700);
      }
      print "done.\n\n";
   }
   else {
     use Net::FTP;
   }
}

# Start backup process
print "Archiving in progress...\n\n";
# &backupDir($config{"mysqldbs"}, "MySQL", 0);
&processFiles();
# &backupDir("/home/sforge/reoback", "Reoback",    1);

&processDeletions();

# Close NFS volume if necessary
if ($config{"remotebackup"}){
   if ($config{"rbackuptype"} eq "NFS"){
      system ("umount ".$config{"localmount"});
   }
}

# Record new status values
open (FILESTATUS, ">$fstat");
print FILESTATUS $bCounter . "," . $lastFull;
close FILESTATUS;

if ($config{"keeplocalcopy"}){
   print "All local archives were saved in $localPath\n";
}
else {
   rmdir ($localPath) or
      print "  Unable to remove local directory: ".$!."!\n\n";
   print "All local archives were removed.\n";
}

$endTime = time() - $startTime;

print "Total transfer time: ".timeCalc($xferTime)."\.\n";
print "Overall backup time: ".timeCalc($endTime)."\.\n\n";
exit;

# END MAIN #############################

# Description:  Routine for directory backups.  Given a directory, a
#               tar file is created for it and transferred if necessary.
# Parameter(s): "directory to backup", "name to call this backup",
#               "create separate archives for subdirectories if non-zero"
sub backupDir{
   my $fileName; # File name of backup to make.
   my $bDir     = $_[0];   # Directory to backup.
   my $bName    = $_[1];   # Name to call this backup.
   my $subdirs  = $_[2];   # Create separate archives for subdirs if non-zero
   my @fileList;           # List of text file that contain files to backup.
   my $fullPath;	   # Full file path of archive.

   print "  Working on $bName...\n";

   # Scan directory for all files for backup depending on type of backup.
   @fileList = &preBackupDir ($bDir, $bName, $subdirs);

   # Back up only if there are files that need to be backed up
   if ( !@fileList ){
      print "    No new or changed files since last full backup for ".
         $bName.".\n\n";
   }
   else {
      foreach ( @fileList ) {
        $fileName = $config{"host"}."-".$_."-".$backupType."-".
            $DATESTAMP."-".$TIMESTAMP."\.".$bCounter.$EXT;

        $fullPath = $localPath.$fileName;

        # Tar backup files
        print "    Archiving ".$_."...\n";
        &archiveFile($fullPath, 1, $config{"tmpdir"}.$_, $fileName);

        # Transfer if needed.
        if ($config{"remotebackup"}){
          transferFile($fullPath, $fileName);
        }

        # Delete if needed.
        if (!$config{"keeplocalcopy"}){
          unlink ($fullPath);
        }

        # Remove temporary file
        unlink ($_);
      }
   }
}

# Description:  Routine for file backups.  Given a file, a
#               tar file is created for it and transferred if necessary.
# Parameter(s): "file to backup", "name to call this backup"
sub backupFile{
   my $lastmod;         # File's last modified time
   my $fileName;        # File name to call backup.
   my $file = $_[0];    # File to backup.
   my $bName = $_[1];   # Name of backup.
   my $fullPath;	# Full path of archive.

   $fileName = $config{"host"}."-".$bName."-".$backupType."-".
       $DATESTAMP."-".$TIMESTAMP."\.".$bCounter.$EXT;

   $fullPath = $localPath.$fileName;

   # Only backup file if it is new or changed
   $lastmod = ( stat( $file ) )[10];
   if ( $lastmod > $lastFull ){
      # Tar backup files
      print "    Archiving ".$bName."...\n";
      &archiveFile($fullPath, 0, $file, $fileName);
   }

   # Transfer if needed.
   if ($config{"remotebackup"}){
     transferFile($fullPath, $fileName);
   }

   # Delete if needed.
   if (!$config{"keeplocalcopy"}){
     unlink ($fullPath);
   }
}

# Description:  Routine for selecting which files to backup.  Upon
#               completion, a text file containing all the files
#               within the directory is created depending on the
#               backup type (inc, or full).
# Parameter(s): "directory to scan", "name for backup",
#               "create separate archives for subdirectories if non-zero"
sub preBackupDir{
   my $temp;              # Temporary holder for joined files.
   my $dir      = $_[0];  # Directory to scan.
   my $name     = $_[1];  # Name for this backup.
   my $subdirs  = $_[2];  # Create separate archives for subdirs if non-zero
   my @tmpFiles;          # List of file names.

   # Scan contents of directory
   if ( $backupType eq "incremental" ) {
      &scanDir( $dir, $name, 1, $subdirs, \@tmpFiles );
   } else {
      &scanDir( $dir, $name, 0, $subdirs, \@tmpFiles );
   }

   return @tmpFiles;
}

# Description:  Routine for creating the tar archive.
# Parameter(s): "filename", "archive type", "filename of list of files", "file"
sub archiveFile{
     my $fileName = $_[0];      # Filename (full path) of archive to create.
     my $archType = $_[1];      # 1 = MultiTar, 0 = SingleTar
     my $tmpName = $_[2];       # List of files or file to archive.
     my $file = $_[3];		# File name by itself.

     my $readfrom = $tmpName;
     $readfrom =~ s/\.list$/\.tmp/;

     # Create the tar archive
     if ($archType){
        system("$TARCMD $fileName -T $readfrom -X $tmpName");
     }
     else {
        system($TARCMD." ".$fileName." ".$tmpName);
     }

     &recordArchive($file);
}

# Description:  Routine for transferring a file to the remote backup
#               location.
# Parameter(s): "filename to transfer"
sub transferFile{
     my $fullPath = $_[0];      # Full path of local archive.
     my $fileName = $_[1];	# Filename to transfer.
     my $ftp;			# FTP connection object.
     my $startTime = time();
     my $endTime;
     my $errFlag = 0;

     print "    Transferring archive: ".$fileName."...";
     if ($config{"rbackuptype"} eq "FTP"){
        $ftp = Net::FTP->new($config{"remotehost"}, Debug => 0) or
           die ("Unable to connect to remote host! : $!\n");
        $ftp->login($config{"ftpuser"},$config{"ftppasswd"}) or
           die ("Unable to login to remote host! : $!\n");
        $ftp->binary;
        $ftp->mkdir($remotePath);
        $ftp->cwd($remotePath) or
           die ("Unable to change to remote directory! : $!\n");

        # Transfer tar file to remote location
        $ftp->put($fullPath) or $errFlag = 1;
        $ftp->quit;
     }
     else {
        copy($fullPath,$nfsPath.$fileName) or $errFlag = 1;
     }
     $endTime = time() - $startTime;
     $xferTime = $xferTime + $endTime;
     if ($errFlag) {
        print "FAILED! : $!\n\n";
     }
     else {
        print "done.\n\n";
     }
}

# Description:  Routine for recursively traversing a directory
#               and all of its subdirectories in order to build
#               a list of files to do a incremental or full backup.
# Parameter(s): "directory to traverse",
#               "name for backup files",
#               "type: 0=full, 1=inc",
#               "create separate archives for subdirectories if non-zero",
#               "List ref to return file names in",
#               "filename to write files to"
# Note:  Last parameter should only be used for recursive calls
sub scanDir{
  my $curdir   = $_[0]; # Name of current directory
  my $bname    = $_[1]; # Name for backup files
  my $btype    = $_[2]; # Backup type: 0 = FULL, 1 = INCREMENTAL
  my $subdirs  = $_[3]; # Create separate archives for subdirs if non-zero
  my $fileList = $_[4]; # List of file names
  my $fileName = $_[5]; # Filename of file that contains list of files to tar
  my $name;             # Name of an entry in current directory
  my $fname;            # Fully qualified name of an entry in current directory
  my @dirs;             # List of directories in this directory
  my $tmp;              # Temporary variable for full file path
  my $lastmod;          # Last modified date
  my $top;              # Non-zero if top of recursive calls
  my $skipFlag = 0;     # Non-zero if we are skipping a file
  my $checkDir;         # Check this name against array of directories to skip
  my $haveFile = 0;     # Non-zero if we are backing up a file in this dir
  my $subHaveFile = 0;  # Non-zero directory has a file
  my $rc;               # Return code

  if ( not $fileName ) {
    $fileName = $bname;
    $top = 1;
  }

  # Check all entries in this directory
  opendir RT, $curdir or die "opendir \"$curdir\": $!\n";
  while ( $name = readdir RT ) {
    # Ignore this filename if it is '.' or '..'.
    if ( ( $name eq "\." ) or ( $name eq "\.\." ) ) {
      next;
    }

    # Fully qualify the filenamename, and remove redundant slashes.
    $fname = $curdir."/".$name;
    $fname =~ s/\/+\//\//g; # Added to remove extra "/" if backing up "/"

    # Check if we should skip this filename.
    foreach ( @skipDirs ) {
      if ( $fname eq $_ ) {
        &addToExclude( $fname, $fileName, $fileList );
        $skipFlag = 1;
        last;
      }
    }
    if ( $skipFlag ) {
      # Reset skip flag
      $skipFlag = 0;
    }

    # If this filename is a directory, add it to the list of directories.
    elsif ( ( -d $fname ) and ( not -l $fname ) ) {
      # Don't push the fully qualified name
      push @dirs, $name;
    }

    # If this filename is a file or symlink, check if it should be excluded
    # from an incremental backup.
    elsif ( ( -f $fname ) or ( -l $fname ) ) {
      if ( ( $btype ) and ( &excludeFile( $fname ) ) ) {
        &addToExclude( $fname, $fileName, $fileList );
      } else {
        $haveFile = 1;
	$foundFiles = 1;
      }
    }

    # Exclude anything else.
    else {
      &addToExclude( $fname, $fileName, $fileList );
    }
  }

  closedir RT;

  # Recursively call this function on each directory in this directory
  foreach ( @dirs ) {
    # Make a new dirlist for each subdirectory
    if ( ( $top ) and ( $subdirs ) ) {
      if ( fileno DIRLIST ) {
        close DIRLIST;
      }
      $fileName = $bname.".".$_;
    }
    $rc = &scanDir( $curdir."/".$_, $bname, $btype, $subdirs, $fileList,
      $fileName );

    # Exclude sub directory if it doesn't have any files to back up
    if ( ( $rc == 0 ) and ( $btype ) ) {
      &addToExclude( $curdir."/".$_, $fileName, $fileList );
    } else {
      $subHaveFile = 1;
    }
  }

  # If this directory is new since last full backup, indicate we have files
  # even if we don't
  if ( ( $btype ) and ( not &excludeFile( $curdir ) ) ) {
    $haveFile = 1;
    $foundFiles = 1;
  }

  # Close last directory list before exiting
  if ( $top ) {
    if ( $subHaveFile+$haveFile == 0 ) {
      &addToExclude( $curdir, $fileName, $fileList );
    }
    if ( fileno DIRLIST ) { close DIRLIST; }
  }

  # Return non-zero if we or our sub dirs have a file to back up
  return $subHaveFile+$haveFile;
}

# Description:  Routine for parsing the configuration file into
#               a key-value associative array.
# Parameter(s): none.
sub parseConfig
{
    my $cfgFile;
    my $argNum = @ARGV;
    if ( ($argNum == 0 ) || ( $argNum > 1 ) ) {
       &usage;
       exit;
    }
    if ($argNum == 1) {
       my $arg = $ARGV[0];
       if ($arg =~ /^-h$|^--help$|^--usage$/) {
          &usage;
          exit;
       }
       elsif ($arg =~ /^-v$|^--version$/) {
          &version;
          exit;
       }
       elsif (-f $arg) {
          $cfgFile = $arg;
       }
       else {
          &usage;
          exit;
       }
    }

    my ($var, $val);
    open(CONF, "<$cfgFile") || die "Cannot find config file: $!\n";
    while (<CONF>) {
        chomp;                      # no newline
        s/#.*//;                    # no comments
        s/^\s+//;                   # no leading white
        s/\s+$//;                   # no trailing white
        next unless length;         # anything left?
        ($var, $val) = split(/\s*=\s*/, $_, 2);
        $config{$var} = $val;       # load config value into the hash
    }
    close(CONF);
}

# Description:  Routine for for determining what type of backup to
#               perform.
# Parameter(s): none.
sub backupType
{
    # Parse configuration and load variables to the hash table
    &parseConfig;

    $fstat = $config{"datadir"}."status.dat";
    $archFiles = $config{"datadir"}."archives.dat";

    my $backupDays;     # Number of days to keep backups.
    my @bstatus;        # Array containing counter and last full backup time.
        # Key:
        # 0 = Backup counter, 1 = Last full backup
    my $lTime;          # Temporary variable for time conversion.

    # Prepare date and time stamps
    chomp($DATESTAMP);
    chomp($DATESTAMPD);
    chomp($TIMESTAMP);

    $backupDays = $config{"backupdays"};

    # Initialize default values
    $bCounter = 1;
    $backupType = "full";
    $lastFull = $startTime;

    if ( -e $fstat ){
      # Status file exists, check to see what type of backup to
      # perform.
      open (FILESTATUS, "<$fstat");
      @bstatus = split (",",`cat $fstat`);

      # Increment backup counter
      $bCounter = $bstatus[0] + 1;
      $lastFull = $bstatus[1];

      # For EXAMPLE backupDays = 7
      ####################################################################
      # 1 = FULL 			8  = FULL
      # 2 = INCREMENTAL  		9  = INCREMENTAL
      # 3 = INCREMENTAL  		10 = INCREMENTAL
      # 4 = INCREMENTAL  		11 = INCREMENTAL
      # 5 = INCREMENTAL  		12 = INCREMENTAL
      # 6 = INCREMENTAL  		13 = INCREMENTAL
      # 7 = INCREMENTAL (DELETE 8-14)  	14 = INCREMENTAL (DELETE 1-7)
      ####################################################################
      if ( ( $bCounter - 1 ) % $backupDays ) {
        $backupType = "incremental";
      }

      # Reached the end of backup cycle (backup days * 2)
      # reset counter and do FULL backup.
      elsif ($bCounter > ($backupDays * 2)) {
         $bCounter = 1;
         $lastFull = $startTime;
      }
      # Counter is equal to backup days + 1
      else {
        $lastFull = $startTime;
      }
    }

    $lTime = localtime($lastFull);
    print "\nRunning backup on ".$config{"host"}.".\n";
    print "Backup number $bCounter of ".($backupDays*2).
       " \(backup days x 2\)\n";
    print qq/Performing $backupType backup via $config{"rbackuptype"}\n/;
    print qq/Last full backup: $lTime\n\n/;
}

sub processFiles {
  my $tmpExt = ".tmp";
  my $tmpStr;
  my $tmpFile;
  my $realStr;
  my $archFile;
  my $skipFile;
  my $skipLine;
  my @skipItems;
  my @archFiles;
  my $misc = $config{"files"};

  open FILE, "<$misc" or
     die "Cannot open \"$misc\": $!\n";

  foreach ( <FILE> ) {
     if ( ( $_ !~ /^#/ ) and ( $_ !~ /^[ \t]*$/ ) ) { # Skip comments and blanks
        chop $_;                                      # Remove trailing newline

        if (/^file:/i) {
           # Close previously opened file if any.
           if ( fileno ARCHFILE ) {
              close ARCHFILE;
           }
           if ( fileno SKIPFILE ) {
              close SKIPFILE;
           }
           $tmpFile = $'; # Grab right end of the match.
           $tmpFile =~ s/\s+//g;
           $archFile = $config{"tmpdir"} . $tmpFile . $tmpExt;
           $skipFile = $config{"tmpdir"} . $tmpFile . "_SKIP" . $tmpExt;
           push @archFiles, $tmpFile;
           open ARCHFILE, ">$archFile" or
              die "open \"$archFile\": $!\n";
        }
        elsif (/^skip:/i) {
           $skipLine = $'; # Grab right end of the match.
           $skipLine =~ s/\s+//g;
           @skipItems = split (",",$skipLine);
           if ( not fileno SKIPFILE ) {
              open SKIPFILE, ">$skipFile" or
                 die "open \"$skipFile\": $!\n";
           }
           foreach (@skipItems){
              print SKIPFILE "$_\n";
           }
        }
        else {
           print ARCHFILE "$_\n";
        }
     }
  }
  if ( fileno SKIPFILE ) {
     close SKIPFILE;
  }
  if ( fileno ARCHFILE ) {
     close ARCHFILE;
  }

  foreach (@archFiles) {
     my $fullSkipFile = $config{"tmpdir"}.$_."_SKIP".$tmpExt;
     my $fullArchFile = $config{"tmpdir"}.$_.$tmpExt;
     if ( -e $fullSkipFile ){
        open (SKIPDIRS, "<$fullSkipFile");
        @skipDirs = <SKIPDIRS>;
        chomp(@skipDirs);
        # Remove temporary file
        unlink ( $fullSkipFile );
     }
     backupMisc($_, $fullArchFile);

     # Remove temporary file
     unlink ( $fullArchFile );
  }

}

# Description:  Routine to back up files in files.cfg
# Parameter(s): none.
sub backupMisc {
  my $fileName;
  my $tarName;
  my $gotfiles = 0;
  my $btype;
  my $lastmod;
  my $fullPath;
  my $bName = $_[0];
  my $misc = $_[1];

  $foundFiles = 0; #Reset for each archive.

  print "  Working on $bName...\n";

  open FILE, "<$misc" or
     die "Cannot open \"$misc\": $!\n";

  $btype = $backupType eq "incremental" ? 1 : 0;
  $fileName = $config{"tmpdir"}.$bName.".list";

  foreach ( <FILE> ) {
    if ( ( $_ !~ /^#/ ) and ( $_ !~ /^[ \t]*$/ ) ) { # Skip comments and blanks
      chop $_;                                       # Remove trailing newline
      if ( ( -d $_ ) and ( not -l $_ ) ) {
        if ( &preBackupDir( $_, $fileName, 0 ) ) {
          $gotfiles = 1;
        }
      } elsif ( ( -f $_ ) or ( -l $_ ) ) {
        if ($btype){
          # Only back up file if it is new or changed
          $lastmod = ( stat( $_ ) )[10];
          if ( ( $lastmod ) and ( $lastmod <= $lastFull ) ) {
            next;
          }
        }
        # Open list of files if not already open
        if ( not fileno DIRLIST ) {
          open DIRLIST, ">>$fileName" or
            die "open \"$fileName\": $!\n";
          $gotfiles = 1;
        }
        # Collapse multiple slashes into one before writting file name to file
        $_ =~ s/\/+\//\//g;
        print DIRLIST "$_\n";
      }
    }
  }

  close FILE;
  close DIRLIST;

#  if ( $gotfiles ) {   # Commenting this line because of new way of backups to preserve
			# permissions.
  if ( $foundFiles ) {
    $tarName = $config{"host"}."-".$bName."-".$backupType."-".
        $DATESTAMP."-".$TIMESTAMP."\.".$bCounter.$EXT;

    $fullPath = $localPath.$tarName;

    # Tar backup files
    print "    Archiving ".$bName."...\n";
    &archiveFile($fullPath, 1, $fileName, $tarName);

    # Transfer if needed.
    if ($config{"remotebackup"}){
      transferFile($fullPath, $tarName);
    }

    # Delete if needed.
    if (!$config{"keeplocalcopy"}){
      unlink ($fullPath);
    }
  }
  else {
      print "    No new or changed files since last full backup for ".
         $bName.".\n\n";
  }

  # Remove temporary file
  unlink ( $fileName );
}

# Description:  Routine to check if a file should be excluded from an
#               incremental backup.
# Parameter(s): "file to check"
# Returns:      0 if file should not be excluded.
#               1 if file should be excluded.
sub excludeFile {
  my $file     = $_[0]; # File to check
  my $lastmod;          # Last modified date

  $lastmod = ( stat( $file ) )[10];
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
#               "list ref to return exclude file names in"
# Returns:      Nothing.
sub addToExclude {
  my $file     = $_[0]; # File to check
  my $fileName = $_[1]; # Filename to write files to
  my $fileList = $_[2]; # List of file names

  # Open exclude file if it isn't already open, and push the name on
  # the list of exclude file names.
  if ( not fileno DIRLIST ) {
    push @{ $fileList }, $fileName;
    open DIRLIST, ">>$fileName" or die "open \"$fileName\": $!\n";
  }

  # Collapse multiple slashes into one before writting file name to file
  $file =~ s/\/+\//\//g;

  # Write the name of the file to exclude.
  print DIRLIST "$file\n";
}

# Description:  Routine to check if a file should be included in
#               the backup.  Writes the file (or directory) name to
#               a file to be used by tar later on.
# Parameter(s): "file to check",
#               "filename to write files to"
#               "type: 0=full, 1=inc",
#               "List ref to return file names in",
sub addToFile {
  my $file     = $_[0]; # File to check
  my $fileName = $_[1]; # Filename to write files to
  my $btype    = $_[2]; # Backup type: 0 = FULL, 1 = INCREMENTAL
  my $fileList = $_[3]; # List of file names
  my $subdirs  = $_[4]; # If true, then $fileName is already complete.
  my $lastmod;          # Last modified date
  my $fullPath;

  if ($subdirs) {
     $fullPath = $config{"tmpdir"}.$fileName;
  }
  else {
     $fullPath = $fileName;
  }

  if ( ( $file ne "\." ) and ( $file ne "\.\." ) ) {  # Ignore . and ..
    if ($btype){
      $lastmod = ( stat( $file ) )[10];
      if ( ( not $lastmod ) or ( $lastmod > $lastFull ) ) {
        if ( not fileno DIRLIST ) {
          push @{ $fileList }, $fileName;

          open DIRLIST, ">>$fullPath" or die "open \"$fullPath\": $!\n";
        }
        # Collapse multiple slashes into one before writting file name to file
        $file =~ s/\/+\//\//g;
        print DIRLIST "$file\n";
      }
    } else {
      if ( not fileno DIRLIST ) {
        push @{ $fileList }, $fileName;
        open DIRLIST, ">>$fullPath" or die "open \"$fullPath\": $!\n";
      }
      # Collapse multiple slashes into one before writting file name to file
      $file =~ s/\/+\//\//g;
      print DIRLIST "$file\n";
    }
  }
}


sub recordArchive{
   my $file = $_[0];	# Tar file to record

   # Record archives
   open (ARCHIVES, ">>$archFiles");
   if ($config{"rbackuptype"} eq "FTP"){
      print ARCHIVES $bCounter.",".$localPath.",".$remotePath.",".$file."\n";
   }
   else {
      print ARCHIVES $bCounter.",".$localPath.",".$config{"localmount"}.$DATESTAMPD."\/".",".$file."\n";
   }
   close ARCHIVES;
}

sub timeCalc{
  my $endTime = $_[0];

  if ($endTime > 3600){
     $endTime = ($endTime / 3600);
     $endTime = sprintf "%.2f", $endTime;
     $endTime = $endTime." hour(s)";
  }
  elsif ($endTime > 60){
     $endTime = ($endTime / 60);
     $endTime = sprintf "%.2f", $endTime;
     $endTime = $endTime." minute(s)";
  }
  else {
     $endTime = sprintf "%.2f", $endTime;
     $endTime = $endTime." seconds(s)";
  }
  return $endTime;
}

sub processDeletions{
   my $ftp;             # Object for FTP connection.
   my @records; 	# Tar files to process.
   my @record;		# A single tar file.
   my $backupDays;     	# Number of days to keep backups.
   my $firstDel;
   my $secondDel;
   my $file;
   my $ldir;
   my $rdir;
   my $tmpFile = $config{"tmpdir"}."archives.tmp";
   my ($upper, $lower, $buNum);

   $backupDays = $config{"backupdays"};
   $firstDel = $backupDays+1;
   $secondDel = $backupDays*2;

   if ( ($bCounter == $backupDays) or
        ($bCounter == $secondDel) ){

      print "Deletions of old back-ups in progress...";

      open (TARS, $archFiles);
      @records = <TARS>;
      close TARS;

      open (TMPFILE, ">$tmpFile");

      # i.e. if counter is 7, delete 8-14
      if ($bCounter == $backupDays){
         $lower = $firstDel;
         $upper = $secondDel;
      }
      # otherwise delete 1-7
      else {
         $lower = 1;
         $upper = $backupDays;
      }
      # Login to remote host if necessary
      if ($config{"remotebackup"}){
         if ($config{"rbackuptype"} eq "FTP"){
            $ftp = Net::FTP->new($config{"remotehost"}, Debug => 0) or
               warn ("  Unable to connect to remote host! : $!\n");
            $ftp->login($config{"ftpuser"},$config{"ftppasswd"}) or
               warn ("  Unable to login to remote host! : $!\n");
	 }
      }
      foreach ( @records ){
         chomp;
         @record = split (",",$_);
	 $buNum = $record[0];
         $ldir = $record[1];
         $rdir = $record[2];
         $file = $record[3];

         if ( ( $buNum >= $lower ) and ( $buNum <= $upper ) ) {

            # Delete local backup.
            if ($config{"keeplocalcopy"}){
               unlink ($ldir.$file) or
                  warn ("    Unable to delete local file! : $!\n");
               rmdir ($ldir);
            }

            # Delete from remote host.
            if ($config{"remotebackup"}){
               if ($config{"rbackuptype"} eq "FTP"){
                  $ftp->cwd($rdir) or
                     warn ("    Unable to change to remote directory! : $!\n");
                  $ftp->delete($file) or
                     warn ("    Unable to delete remote file! : $!\n");
	          $ftp->rmdir($rdir);
	       }
	       else {
	          unlink ($rdir.$file) or
                     warn ("    Unable to delete remote file! : $!\n");
		  rmdir ($rdir);
	       }

            }
         }
         else {
            # Write left over entries back to file.
            print TMPFILE $_."\n";
         }
      }
      close TMPFILE;

      unlink($archFiles) or die ("    Unable to delete $archFiles!: $!\n");
      move($tmpFile, $archFiles) or die ("    Unable to rename
         $tmpFile to $archFiles!: $!\n");

      # Close connection if necessary
      if ($config{"remotebackup"}){
         $ftp->quit unless $config{"rbackuptype"} eq "NFS";
      }
      print "done.\n\n";
   }
}

sub version {
  print "REOBack version $VERSION; distributed under the GNU GPL.\n";
}

sub usage {
  print << "END_OF_INFO";

REOBack Simple Backup Solution ver. $VERSION
(c) 2001, Randy Oyarzabal (techno91\@users.sourceforge.net)

Usage: reoback.pl [options] [<configfile>]

Options:
-v, --version		Display version information.
-h, --help, --usage	Display this help information.

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
#

