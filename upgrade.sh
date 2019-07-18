#!/bin/bash

echo "upgrading"
cd /opt/followupEngine/
git checkout .
git pull


echo "updating libraries"
sh install_libraries.sh

echo "complete"
