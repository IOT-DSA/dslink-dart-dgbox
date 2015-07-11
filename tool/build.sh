#!/usr/bin/env bash
git submodule update --init
[ -d build ] && rm -rf build
mkdir -p build
pub upgrade
dart2js bin/run.dart -o build/bin/run.dart --output-type=dart --categories=Server -m
cp dslink.json build/dslink.json
cp -R tools build/tools
cd build/
zip -r cp ../../../files/host.zip .
