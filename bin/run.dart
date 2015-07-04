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

  for (var tool in tools) {
    if (await findExecutable(tool) == null) {
      await installPackage(tool);
    }
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
      "Execute_Command": {
        r"$invokable": "write",
        r"$is": "executeCommand",
        r"$name": "Execute Command",
        r"$params": [
          {
            "name": "command",
            "type": "string"
          }
        ],
        r"$result": "values",
        r"$columns": [
          {
            "name": "output",
            "type": "string",
            "editor": "textarea"
          },
          {
            "name": "exitCode",
            "type": "int"
          }
        ]
      },
      "Hostname": {
        r"$type": "string",
        "?value": Platform.localHostname
      },
      "Timezone": {
        r"$type": "string",
        r"?value": await getCurrentTimezone(),
        "Set": {
          r"$invokable": "write",
          r"$is": "setCurrentTimezone",
          r"$params": [
            {
              "name": "timezone",
              "type": buildEnumType(await getAllTimezones())
            }
          ]
        }
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
        "Start_Access_Point": {
          r"$name": "Start Access Point",
          r"$is": "startAccessPoint",
          r"$invokable": "write",
          r"$result": "values"
        },
        "Stop_Access_Point": {
          r"$name": "Stop Access Point",
          r"$is": "stopAccessPoint",
          r"$invokable": "write",
          r"$result": "values"
        },
        "Restart_Access_Point": {
          r"$name": "Restart Access Point",
          r"$is": "restartAccessPoint",
          r"$invokable": "write",
          r"$result": "values"
        },
        "Get_Access_Point_Status": {
          r"$name": "Get Access Point Status",
          r"$is": "getAccessPointStatus",
          r"$invokable": "write",
          r"$result": "values",
          r"$columns": [
            {
              "name": "up",
              "type": "bool"
            }
          ]
        },
        "Get_Access_Point_Settings": {
          r"$name": "Get Access Point Settings",
          r"$is": "getAccessPointConfiguration",
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
        "Configure_Access_Point": {
          r"$name": "Configure Access Point",
          r"$is": "configureAccessPoint",
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
        }
      }
    }, profiles: {
    "reboot": addAction((Map<String, dynamic> params) {
      System.reboot();
    }),
    "startAccessPoint": addAction((Map<String, dynamic> params) async {
      await startAccessPoint();
    }),
    "stopAccessPoint": addAction((Map<String, dynamic> params) async {
      await stopAccessPoint();
    }),
    "restartAccessPoint": addAction((Map<String, dynamic> params) async {
      await stopAccessPoint();
      await startAccessPoint();
    }),
    "getAccessPointStatus": addAction((Map<String, dynamic> params) async {
      return {
        "up": await isAccessPointOn()
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
    "setCurrentTimezone": addAction((Map<String, dynamic> params) async {
      await setCurrentTimezone(params["timezone"]);
      await updateTimezone();
    }),
    "configureAccessPoint": addAction((Path path, Map<String, dynamic> params) async {
      var ssid = params["ssid"];
      var password = params["password"];
      var wifi = params["wifi"];
      var internet = params["internet"];
      var ip = params["ip"];

      if (wifi == internet) {
        return {
          "success": false,
          "message": "Access Point Interface cannot be the same as the Internet Interface"
        };
      }

      var config = generateHotspotDaemonConfig(wifi, internet, ssid, ip, "255.255.255.0", password);

      var file = new File("${await getPythonModuleDirectory()}/hotspotd.json");
      if (!(await file.exists())) {
        await file.create(recursive: true);
      }

      await file.writeAsString(config);

      return {
        "success": true,
        "message": "Success!"
      };
    }),
    "executeCommand": addAction((Map<String, dynamic> params) async {
      var cmd = params["command"];
      var result = await exec("bash", args: ["-c", cmd], writeToBuffer: true);

      return {
        "output": result.output,
        "exitCode": result.exitCode
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
    "getAccessPointConfiguration": addAction((Path path, Map<String, dynamic> params) async {
      var m = [];
      var file = new File("${await getPythonModuleDirectory()}/hotspotd.json");
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
    if (iface == "lo") {
      continue;
    }

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

  (link["/Network/Configure_Access_Point"].configs[r"$params"] as List)[0]["type"] = buildEnumType(wifis);
  (link["/Network/Configure_Access_Point"].configs[r"$params"] as List)[1]["type"] = buildEnumType(names);
}

Future<String> getPythonModuleDirectory() async {
  var result = await exec("python2", args: ["-"], stdin: [
  "import hostapd.main",
  "x = hotspotd.main.__file__.split('/')",
  "print('/'.join(x[0:len(x) - 1]))"
  ].join("\n"));

  return result.output.trim();
}

Future updateTimezone() async {
  link.updateValue("/Timezone", await getCurrentTimezone());
}
