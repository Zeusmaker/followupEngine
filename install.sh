#!/bin/bash

echo "followUp Engine Installer"

sh install_libraries.sh -f

echo "installing tables on first run"
perl bin/followupEngine.pl

echo "put the following in your cron"
echo "# #####################
# # Followup Engine, runs every 5 minutes, between 8am, and 5pm
# #####################
* 5-20 * * * /opt/followupEngine/bin/followupEngine.pl >/dev/null 2>&1"
