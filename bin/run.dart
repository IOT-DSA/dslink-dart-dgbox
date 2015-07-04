import "dart:async";
import "dart:convert";
import "dart:io";

import "package:dslink/dslink.dart";
import "package:dslink/nodes.dart";

import "package:dslink_system/utils.dart";

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

verifyDependencies() async {
  if (!Platform.isLinux) {
    return;
  }

  List<String> tools = [
    "hostapd"
  ];

  var missing = false;

  for (var tool in tools) {
    if (await findExecutable(tool) == null) {
      missing = true;
      print("Missing Dependency: ${tool}");
    }
  }

  if (missing) {
    print("Please install these tools before continuing.");
    exit(1);
  }

  if (await findExecutable("hotspotd") == null) {
    var result = await exec("python2", args: [
      "setup.py",
      "install"
    ], workingDirectory: "tools/hotspotd", writeToBuffer: true);
    if (result.exitCode != 0) {
      print("Failed to install hotspotd:");
      stdout.write(result.output);
      exit(1);
    }
  }
}

String generateHotspotDaemonConfig(String wifi, String internet, String ssid, String ip, String netmask, String password) {
  return JSON.encode({
    "wlan": wifi,
    "inet": internet,
    "SSID": ssid,
    "ip": ip,
    "netmask": netmask,
    "password": password
  });
}

main(List<String> args) async {
  {
    var result = await Process.run("id", ["-u"]);

    if (result.stdout.trim() != "0") {
      print("This link must be run as the superuser.");
      exit(0);
    }

    await verifyDependencies();
  }

  link = new LinkProvider(args, "Host-",
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
      },
      "Configure_Hotspot": {
        r"$name": "Configure Hotspot",
        r"$is": "configureHotspot",
        r"$invokable": "write",
        r"$params": [
          {
            "name": "wifi",
            "type": "enum[]"
          },
          {
            "name": "internet",
            "type": "enum[]"
          },
          {
            "name": "ssid",
            "type": "string",
            "default": "DSA"
          },
          {
            "name": "password",
            "type": "string"
          },
          {
            "name": "ip",
            "type": "string",
            "default": "192.168.42.1"
          }
        ],
        r"$result": "values",
        r"$columns": [
          {
            "name": "success",
            "type": "bool"
          },
          {
            "name": "message",
            "type": "string"
          }
        ]
      }
    }, profiles: {
    "reboot": addAction((Map<String, dynamic> params) {
      System.reboot();
    }),
    "shutdown": addAction((Map<String, dynamic> params) {
      System.shutdown();
    }),
    "configureNetworkManual": addAction((Path path, Map<String, dynamic> params) async {
      var name = new Path(path.parentPath).name;
      var result = await configureNetworkManual(name, params["ip"], params["netmask"], params["router"]);

      return {
        "success": result
      };
    }),
    "configureNetworkAutomatic": addAction((Path path, Map<String, dynamic> params) async {
      var name = new Path(path.parentPath).name;
      var result = await configureNetworkAutomatic(name);

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
    }),
    "configureHotspot": addAction((Path path, Map<String, dynamic> params) async {
      var ssid = params["ssid"];
      var password = params["password"];
      var wifi = params["wifi"];
      var internet = params["internet"];
      var ip = params["ip"];

      if (wifi == internet) {
        return {
          "success": false,
          "message": "Hotspot Interface cannot be the same as the Internet Interface"
        };
      }

      var config = generateHotspotDaemonConfig(wifi, internet, ssid, ip, "255.255.255.0", password);

      var file = new File("/usr/local/lib/python2.7/dist-packages/hotspotd/hotspotd.json");
      if (!(await file.exists())) {
        await file.create(recursive: true);
      }

      await file.writeAsString(config);

      return {
        "success": true,
        "message": "Success!"
      };
    }),
    "getHotspotConfiguration": addAction((Path path, Map<String, dynamic> params) async {
      var m = [];
      var file = new File("/usr/local/lib/python2.7/dist-packages/hotspotd/hotspotd.json");
      if (!(await file.exists())) {
        return [];
      }

      var json = JSON.decode(await file.readAsString());
      for (var key in json.keys) {
        m.add({
          "key": key.toLowerCase(),
          "value": json["value"]
        });
      }

      return m;
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

Future<List<String>> listNetworkInterfaces() async {
  var result = await Process.run("ifconfig", []);
  List<String> lines = result.stdout.split("\n");
  var ifaces = [];
  for (var line in lines) {
    if (line.isNotEmpty && line[0] != " ") {
      var iface = line.split(" ")[0];
      ifaces.add(iface);
    }
  }
  return ifaces;
}

syncNetworkStuff() async {
  var ns = await serializeNetworkState();

  var nameservers = (await getCurrentNameServers()).join(",");

  if (nameservers.isNotEmpty) {
    link.updateValue("/Name_Servers", nameservers);
  }

  if (_lastNetworkState == null || ns != _lastNetworkState) {
    _lastNetworkState = ns;
    List<String> ifaces = await listNetworkInterfaces();
    SimpleNode inode = link["/Network_Interfaces"];

    for (SimpleNode child in inode.children.values) {
      inode.removeChild(child);
    }

    var wifis = [];
    var names = [];

    for (String iface in ifaces) {
      var m = {};

      names.add(iface);

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

      m["Configure_Automatically"] = {
        r"$name": "Configure Automatically",
        r"$invokable": "write",
        r"$is": "configureNetworkAutomatic",
        r"$result": "values",
        r"$columns": [
          {
            "name": "success",
            "type": "bool"
          }
        ]
      };

      m["Configure_Manually"] = {
        r"$name": "Configure Manually",
        r"$invokable": "write",
        r"$is": "configureNetworkManual",
        r"$params": [
          {
            "name": "ip",
            "type": "string"
          },
          {
            "name": "netmask",
            "type": "string"
          },
          {
            "name": "gateway",
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

      if (await isWifiInterface(iface)) {
        wifis.add(iface);
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

      link.addNode("/Network_Interfaces/${iface}", m);
    }

    (link["/Configure_Hotspot"].configs[r"$params"] as List)[0]["type"] = buildEnumType(wifis);
    (link["/Configure_Hotspot"].configs[r"$params"] as List)[1]["type"] = buildEnumType(names);
  }
}

Future<bool> setWifiNetwork(String interface, String ssid, String password) async {
  if (Platform.isMacOS) {
    var args = ["-setairportnetwork", interface, ssid];

    if (password != null && password.isNotEmpty) {
      args.add(password);
    }

    var result = await Process.run("networksetup", args);

    if (result.exitCode != 0) {
      return false;
    }

    return true;
  } else {
    var args = [interface, "essid", ssid];

    if (password != null && password.isNotEmpty) {
      args.addAll(["key", password]);
    }

    var result = await Process.run("iwconfig", args);

    if (result.exitCode != 0) {
      return false;
    }

    return true;
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

    if (result.exitCode != 0) {
      return false;
    } else {
      return true;
    }
  }
}

Future configureNetworkAutomatic(String interface) async {
  if (Platform.isMacOS) {
    var service = await getNetworkServiceForInterface(interface);
    var args = ["-setdhcp", service];

    return Process.run("networksetup", args).then((result) {
      return result.exitCode == 0;
    });
  }

  var resultA = await Process.run("ifconfig", [interface, "0.0.0.0", "0.0.0.0"]);
  if (resultA.exitCode != 0) {
    return false;
  }

  await Process.run("dhclient", ["-r", interface]);
  var resultB = await Process.run("dhclient", [interface]);

  return resultB.exitCode == 0;
}

Future configureNetworkManual(String interface, String ip, String netmask, String gateway) async {
  if (Platform.isWindows) {
    throw new Exception("Unsupported on Windows");
  }

  if (Platform.isMacOS) {
    var service = await getNetworkServiceForInterface(interface);
    var args = ["-setmanual", service, ip, netmask, gateway];

    return Process.run("networksetup", args).then((result) {
      return result.exitCode == 0;
    });
  }

  await Process.run("killall", ["dhclient"]);

  var resultA = await Process.run("route", ["add", "default", "gw", gateway, interface]);
  if (resultA.exitCode != 0) {
    return false;
  }

  var resultB = await Process.run("ifconfig", [interface, ip, "netmask", netmask]);

  return resultB.exitCode == 0;
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

Future<String> getNetworkServiceForInterface(String interface) async {
  var result = await Process.run("networksetup", ["-listnetworkserviceorder"]);
  List<String> lines = result.stdout.split("\n");
  var results = {};
  lines.where((x) => x.startsWith("(Hardware Port:")).forEach((x) {
    var mn = x.substring(1, x.length - 1).split(",");
    results[mn[1].split(":")[1].trim()] = mn[0].split(":")[1].trim();
  });
  return results[interface];
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
      if (line.trim().isEmpty) {
        continue;
      }

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

      buff.add(line);
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

  if (!(await file.exists())) {
    return [];
  }

  var lines = (await file.readAsLines())
    .map((x) => x.trim())
    .where((x) => x.isNotEmpty && !x.startsWith("#")).toList();

  return lines
    .where((x) => x.startsWith("nameserver "))
    .map((x) => x.replaceAll("nameserver ", ""))
    .toList();
}
