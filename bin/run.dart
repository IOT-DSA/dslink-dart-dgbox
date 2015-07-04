import "dart:async";
import "dart:convert";
import "dart:io";

import "package:dslink/dslink.dart" hide Link;
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
    "hostapd",
    "dnsmasq"
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
      "Shutdown": {
        r"$invokable": "write",
        r"$is": "shutdown"
      },
      "Reboot": {
        r"$invokable": "write",
        r"$is": "reboot"
      },
      "List_Directory": {
        r"$invokable": "read",
        r"$name": "List Directory",
        r"$is": "listDirectory",
        r"$result": "table",
        r"$params": [
          {
            "name": "directory",
            "type": "string"
          }
        ],
        r"$columns": [
          {
            "name": "name",
            "type": "string"
          },
          {
            "name": "path",
            "type": "string"
          },
          {
            "name": "type",
            "type": "string"
          }
        ]
      },
      "Network": {
        r"$name": "Network",
        "Start_Hotspot": {
          r"$name": "Start Hotspot",
          r"$is": "startHotspot",
          r"$invokable": "write",
          r"$result": "values"
        },
        "Stop_Hotspot": {
          r"$name": "Stop Hotspot",
          r"$is": "stopHotspot",
          r"$invokable": "write",
          r"$result": "values"
        },
        "Restart_Hotspot": {
          r"$name": "Restart Hotspot",
          r"$is": "restartHotspot",
          r"$invokable": "write",
          r"$result": "values"
        },
        "Get_Hotspot_Status": {
          r"$name": "Get Hotspot Status",
          r"$is": "getHotspotStatus",
          r"$invokable": "write",
          r"$result": "values",
          r"$columns": [
            {
              "name": "up",
              "type": "bool"
            }
          ]
        },
        "Get_Hotspot_Settings": {
          r"$name": "Get Hotspot Settings",
          r"$is": "getHotspotConfiguration",
          r"$invokable": "write",
          r"$columns": [
            {
              "name": "key",
              "type": "string"
            },
            {
              "name": "value",
              "type": "string"
            }
          ],
          r"$result": "table"
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
        },
        "Name_Servers": {
          r"$name": "Nameservers",
          r"$type": "string",
          "?value": (await getCurrentNameServers()).join(",")
        },
        "Hostname": {
          r"$type": "string",
          "?value": Platform.localHostname
        }
      }
    }, profiles: {
    "reboot": addAction((Map<String, dynamic> params) {
      System.reboot();
    }),
    "startHotspot": addAction((Map<String, dynamic> params) async {
      await startHotspot();
    }),
    "stopHotspot": addAction((Map<String, dynamic> params) async {
      await stopHotspot();
    }),
    "restartHotspot": addAction((Map<String, dynamic> params) async {
      await stopHotspot();
      await startHotspot();
    }),
    "getHotspotStatus": addAction((Map<String, dynamic> params) async {
      return {
        "up": await isHotspotOn()
      };
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
    "listDirectory": addAction((Map<String, dynamic> params) async {
      var dir = new Directory(params["directory"]);

      try {
        return dir.list().asyncMap((x) async {
          return {
            "name": x.path.split("/").last,
            "path": x.path,
            "type": fseType(x)
          };
        }).toList();
      } catch (e) {
        return [];
      }
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
          "value": json[key]
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
    if (line.isNotEmpty && line[0] != " " && line[0] != "\t") {
      var iface = line.split(" ")[0];
      if (iface.endsWith(":")) {
        iface = iface.substring(0, iface.length - 1);
      }
      ifaces.add(iface);
    }
  }
  return ifaces;
}

syncNetworkStuff() async {
  var nameservers = (await getCurrentNameServers()).join(",");

  if (nameservers.isNotEmpty) {
    link.updateValue("/Network/Name_Servers", nameservers);
  }

  List<String> ifaces = await listNetworkInterfaces();
  SimpleNode inode = link["/Network"];

  for (SimpleNode child in inode.children.values) {
    if (child.configs[r"$host_network"] != null) {
      inode.removeChild(child);
    }
  }

  var wifis = [];
  var names = [];

  for (String iface in ifaces) {
    var m = {};

    names.add(iface);

    m[r"$host_network"] = iface;

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

    link.addNode("/Network/${iface}", m);
  }

  (link["/Network/Configure_Hotspot"].configs[r"$params"] as List)[0]["type"] = buildEnumType(wifis);
  (link["/Network/Configure_Hotspot"].configs[r"$params"] as List)[1]["type"] = buildEnumType(names);
}
