#!/usr/bin/env bash
DIR=`dirname "$0"`
chmod 600 ${DIR}/id_dgboxsupport_rsa
autossh -i $DIR/id_dgboxsupport_rsa -R 0:localhost:22 dgboxsupport@dgboxsupport.dglogik.com -N -T > $DIR/dgboxsupport.info 2>&1 &
