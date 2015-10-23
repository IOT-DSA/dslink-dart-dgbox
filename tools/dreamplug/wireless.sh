#!/bin/bash
SELF=${0}

# Note: this script isn't very clean in that it doesn't check the current state before doing, e.g., rmmod and such.
# Still, it works, and since this is called from MA the output can be suppressed, and no one will be the wiser.

case "${1:-''}" in
  'off')
        echo Turning wireless off
        ifdown mlan0
        ifconfig uap0 down
        rmmod sd8xxx
        rmmod mlan
        killall wpa_supplicant
        echo 0 > `eval ls /sys/class/leds/guruplug\:green\:wmode/brightness`
        echo 0 > `eval ls /sys/class/leds/guruplug\:red\:wmode/brightness`
        ;;

  'base')
        echo Turning on base station
        bash $SELF off
        /root/init_setup8787.sh
        /etc/init.d/udhcpd restart
        ;;

  'client')
        echo Starting wireless client
        bash $SELF off
        wlan.sh
        /sbin/wpa_supplicant -i mlan0 -c /root/.mlan.conf -B
        ifup mlan0
        ;;

  'scan')
        echo Scanning for wireless networks
        iwlist mlan0 scanning
        ;;

  *)
        echo "Usage: $SELF off|base|client|scan"
        exit 1
        ;;
esac
