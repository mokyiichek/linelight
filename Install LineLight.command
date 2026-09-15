#!/bin/bash
# Double-click this file in Finder to build and install LineLight.
cd "$(dirname "$0")"
exec > >(tee "install.log") 2>&1
chmod +x ./build.sh
./build.sh --install
echo
echo "Done. You can close this window."
