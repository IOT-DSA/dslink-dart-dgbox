import "package:dslink_host/utils.dart";

const String INPUT = """
# Written by DGBox config module of Mango Automation

auto lo
iface lo inet loopback

iface eth1 inet dhcp

iface eth0 inet static
	address 192.168.2.93
	netmask 255.255.255.0
	gateway 192.168.2.1

iface mlan0 inet dhcp
""";

main() async {
  var script = NetworkInterfaceScript.parse(INPUT);
  print(script.build());
}