#!/bin/sh
############################################################################
# REOBack - run_reoback.sh
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
# This script is provided to conveniently run REOBack with one command
# or for use in a "crontab" when scheduling nightly backups.
#
# If you want to schedule this to run nightly via a cron job, do the
# following:
#
# 1. Edit your crontab by typing "crontab -e" (read the cron docs for
#    for detailed instructions.
#
# 2. Add the following line if you want to run the backups every
#    1:45 AM.  Change the time and path where necesary.
#    45 1 * * * /usr/reoback/run_reoback.sh
#
# 3. Make sure the path definitions below are correct.
#
# 4. That's it!

# Location of the configuration file.
config="/home/sforge/reoback/settings.conf"

# Change to reflect where REOBack is installed
reoback="/home/sforge/reoback/reoback.pl" 

# Do not modify this line.
$reoback $config


