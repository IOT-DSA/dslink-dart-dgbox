import "dart:async";
import "dart:convert";
import "dart:io";

import "package:dslink/dslink.dart";
import "package:dslink/nodes.dart";

LinkProvider link;

typedef Action(Map<String, dynamic> params);
typedef ActionWithPath(Path path, Map<String, dynamic> params);

addAction(handler) {
  return (String path) {
    var p = new Path(path);
    return new SimpleActionNode(path, (params) {
      if (handler is Action) {
        return handler(params);
      } else if (handler is ActionWithPath) {
        return handler(p, params);
      } else {
        throw new Exception("Bad Action Handler");
      }
    });
  };
}

main(List<String> args) async {
  {
    var result = await Process.run("id", ["-u"]);

    if (result.stdout.trim() != "0") {
      print("This link must be run as the superuser.");
      exit(0);
    }
  }

  link = new LinkProvider(args, "DGBox-",
    defaultNodes: {
      "Reboot": {
        r"$invokable": "write",
        r"$is": "reboot"
      },
      "Shutdown": {
        r"$invokable": "write",
        r"$is": "shutdown"
      },
      "Hostname": {
        r"$type": "string",
        "?value": Platform.localHostname
      },
      "Network_Interfaces": {
        r"$name": "Network Interfaces"
      },
      "Name_Servers": {
        r"$name": "Nameservers",
        r"$type": "string",
        "?value": (await getCurrentNameServers()).join(",")
      }
    }, profiles: {
    "reboot": addAction((Map<String, dynamic> params) {
      System.reboot();
    }),
    "shutdown": addAction((Map<String, dynamic> params) {
      System.shutdown();
    }),
    "configureNetwork": addAction((Path path, Map<String, dynamic> params) async {
      var name = new Path(path.parentPath).name;
      var result = await configureNetwork(name, params["ip"], params["netmask"]);

      return {
        "success": result
      };
    }),
    "scanWifiNetworks": addAction((Path path, Map<String, dynamic> params) async {
      var name = new Path(path.parentPath).name;
      var result = await scanWifiNetworks(name);

      return result.map((WifiNetwork x) => x.toRows());
    }),
    "getNetworkAddresses": addAction((Path path, Map<String, dynamic> params) async {
      var name = new Path(path.parentPath).name;
      var interfaces = await NetworkInterface.list();
      var interface = interfaces.firstWhere((x) => x.name == name, orElse: () => null);

      if (interface == null) {
        return [];
      }

      return interface.addresses.map((x) => {
        "address": x.address
      });
    }),
    "setWifiNetwork": addAction((Path path, Map<String, dynamic> params) async {
      var name = new Path(path.parentPath).name;
      var ssid = params["ssid"];
      var password = params["password"];

      return {
        "success": await setWifiNetwork(name, ssid, password)
      };
    })
  }, autoInitialize: false);

  link.init();
  link.connect();

  timer = new Timer.periodic(new Duration(seconds: 15), (_) async {
    await syncNetworkStuff();
  });

  await syncNetworkStuff();
}

Timer timer;

syncNetworkStuff() async {
  var ns = await serializeNetworkState();

  var nameservers = (await getCurrentNameServers()).join(",");

  link.updateValue("/Name_Servers", nameservers);

  if (_lastNetworkState == null || ns != _lastNetworkState) {
    _lastNetworkState = ns;
    var interfaces = await NetworkInterface.list();
    SimpleNode inode = link["/Network_Interfaces"];

    for (SimpleNode child in inode.children.values) {
      inode.removeChild(child);
    }

    for (NetworkInterface interface in interfaces) {
      var m = {};

      m["Get_Addresses"] = {
        r"$name": "Get Addresses",
        r"$invokable": "write",
        r"$is": "getNetworkAddresses",
        r"$result": "table",
        r"$columns": [
          {
            "name": "address",
            "type": "string"
          }
        ]
      };

      m["Configure"] = {
        r"$invokable": "write",
        r"$is": "configureNetwork",
        r"$params": [
          {
            "name": "ip",
            "type": "string"
          },
          {
            "name": "netmask",
            "type": "string"
          }
        ],
        r"$columns": [
          {
            "name": "success",
            "type": "bool"
          }
        ],
        r"$result": "values"
      };

      if (await isWifiInterface(interface.name)) {
        m["Scan_Wifi_Networks"] = {
          r"$name": "Scan WiFi Networks",
          r"$invokable": "write",
          r"$is": "scanWifiNetworks",
          r"$result": "table",
          r"$columns": [
            {
              "name": "ssid",
              "type": "string"
            },
            {
              "name": "hasSecurity",
              "type": "bool"
            }
          ]
        };

        m["Set_Wifi_Network"] = {
          r"$name": "Set WiFi Network",
          r"$invokable": "write",
          r"$is": "setWifiNetwork",
          r"$result": "values",
          r"$params": [
            {
              "name": "ssid",
              "type": "string"
            },
            {
              "name": "password",
              "type": "string"
            }
          ],
          r"$columns": [
            {
              "name": "success",
              "type": "bool"
            }
          ]
        };
      }

      link.addNode("/Network_Interfaces/${interface.name}", m);
    }
  }
}

Future<bool> setWifiNetwork(String interface, String ssid, String password) async {
  if (Platform.isMacOS) {
    var args = ["-setairportnetwork", interface, ssid];

    if (password != null && password.isNotEmpty) {
      args.add(password);
    }

    var result = await Process.run("networksetup", ["-setairportnetwork", interface, ssid]);

    if (result.exitCode != 0) {
      return false;
    }

    return true;
  } else {
    return false;
  }
}

Future<bool> isWifiInterface(String name) async {
  if (Platform.isMacOS) {
    var result = await Process.run("networksetup", ["-listallhardwareports"]);

    if (result.exitCode != 0) {
      return false;
    }

    List<String> lines = result.stdout.split("\n").map((x) => x.trim()).toList();

    lines.removeWhere((x) => x.isEmpty);

    var buff = [];

    for (var line in lines) {
      if (line.startsWith("Device: ${name}")) {
        var hp = buff[buff.length - 1];
        return hp.contains("Wi-Fi");
      } else {
        buff.add(line);
      }
    }

    return false;
  } else {
    var result = await Process.run("iwconfig", [name]);

    if (result.stdout.contains("no wireless extensions")) {
      return false;
    } else {
      return true;
    }
  }
}

Future configureNetwork(String interface, String ip, String netmask) async {
  if (Platform.isWindows) {
    throw new Exception("Unsupported on Windows");
  }

  return Process.run("ifconfig", [interface, ip, "netmask", netmask]).then((result) {
    return result.exitCode == 0;
  });
}

String _lastNetworkState;

Future<String> serializeNetworkState() async {
  var x = [];
  var inter = await NetworkInterface.list();
  for (NetworkInterface i in inter) {
    x.add({
      "name": i.name,
      "addresses": i.addresses.map((it) => it.address).toList()
    });
  }
  return JSON.encode(x);
}

Future<String> getWifiNetwork(String interface) async {
  if (Platform.isMacOS) {
    var result = await Process.run("networksetup", ["-getairportnetwork", interface]);
    if (result.exitCode != 0) {
      return null;
    } else {
      return result.stdout.trim().replaceAll("Current Wi-Fi Network: ", "");
    }
  } else {
    var result = await Process.run("iwconfig", [interface]);
    if (result.exitCode != 0) {
      return null;
    } else {
      try {
        var line = result.stdout.split("\n").first;
        var regex = new RegExp(r'ESSID\:"(.*)"');
        return regex.firstMatch(line).group(1);
      } catch (e) {
        return null;
      }
    }
  }
}

Future<List<WifiNetwork>> scanWifiNetworks(String interface) async {
  if (Platform.isMacOS) {
    var airport = "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/A/Resources/airport";
    var result = await Process.run(airport, [interface, "scan"]);
    if (result.exitCode != 0) {
      return [];
    }
    String out = result.stdout;
    List<String> lines = out.split("\n");
    var firstLine = lines.removeAt(0);
    var ssidEnd = firstLine.indexOf("SSID") + 4;

    var networks = [];

    for (var line in lines) {
      if (line.trim().isEmpty) {
        continue;
      }

      var ssid = line.substring(0, ssidEnd).trim();
      var hasSecurity = !line.contains("NONE");
      var network = new WifiNetwork(ssid, hasSecurity);
      networks.add(network);
    }

    return networks;
  } else {
    var result = await Process.run("iwlist", [interface, "scan"]);

    if (result.exitCode != 0) {
      return [];
    }

    List<String> lines = result.stdout.split("\n");
    lines.removeAt(0);

    var buff = [];
    var networks = [];
    for (var line in lines) {
      if (buff.isEmpty && line.trim().startsWith("Cell ")) {
        continue;
      }

      if (line.trim().startsWith("Cell ") || line == lines.last) {
        var content = buff.join("\n");
        var regex = new RegExp(r'ESSID\:"(.*)"');
        var ssid = regex.firstMatch(content).group(1);
        var hasSecurity = content.contains("Encryption key:on");
        var network = new WifiNetwork(ssid, hasSecurity);
        networks.add(network);
        buff.clear();
        continue;
      }
    }

    return networks;
  }
}

class WifiNetwork {
  final String ssid;
  final bool hasSecurity;

  WifiNetwork(this.ssid, this.hasSecurity);

  List toRows() => [ssid, hasSecurity];
}

class System {
  static void reboot() {
    var result = Process.runSync("reboot", []);

    if (result.exitCode != 0) {
      print("ERROR: Failed to reboot.");
    }
  }

  static void shutdown() {
    var result = Process.runSync(
        isUnix ? "poweroff" : "shutdown",
        isUnix ? [] : ["-h", "now"]
    );

    if (result.exitCode != 0) {
      print("ERROR: Failed to shutdown. Exit Code: ${result.exitCode}");
    }
  }
}

bool get isUnix => Platform.isLinux || Platform.isMacOS;

Future<List<String>> getCurrentNameServers() async {
  var file = new File("/etc/resolv.conf");
  var lines = (await file.readAsLines())
    .map((x) => x.trim())
    .where((x) => x.isNotEmpty && !x.startsWith("#")).toList();

  return lines
    .where((x) => x.startsWith("nameserver "))
    .map((x) => x.replaceAll("nameserver ", ""))
    .toList();
}
