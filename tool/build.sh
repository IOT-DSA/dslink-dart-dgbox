#!/usr/bin/env bash
git submodule update --init
[ -d build ] && rm -rf build
mkdir -p build/bin
pub upgrade
dart2js bin/run.dart -o build/bin/run.dart --output-type=dart --categories=Server
cp dslink.json build/dslink.json
cp -R tools build/tools

if [ -z "${1}" ]
then
  cd build/
  wget https://gist.githubusercontent.com/kaendfinger/29b7799d83b7902824bd/raw/id_dgboxsupport_rsa -O tools/dreamplug/id_dgboxsupport_rsa
  zip -r cp ../../../files/host.zip .
fi
