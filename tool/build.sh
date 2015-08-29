#!/usr/bin/env bash
git submodule update --init
[ -d build ] && rm -rf build
mkdir -p build/bin
pub upgrade
dart2js bin/run.dart -o build/bin/run.dart --output-type=dart --categories=Server
cp dslink.json build/dslink.json
cp -R tools build/tools

if [ "${1}" != "-n" ]
then
  cd build/
  chmod 600 tools/dreamplug/id_dgboxsupport_rsa
  zip -r cp ../../../files/host-dgbox.zip .
fi
