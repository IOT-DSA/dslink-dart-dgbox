import "dart:async";
import "dart:convert";
import "dart:io";

import "package:dslink/dslink.dart" hide Link;
import "package:dslink/nodes.dart";

import "package:dslink_host/utils.dart";

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
    "dnsmasq"
  ];

  if (!(await isProbablyDGBox())) {
    tools.add("hostapd");
  }

  for (var tool in tools) {
    if (await findExecutable(tool) == null) {
      await installPackage(tool);
    }
  }

  if (await isProbablyDGBox()) {
    var mf = new File("/usr/bin/python2");
    if (!(await mf.exists())) {
      var link = new Link("/usr/bin/python2");
      await link.create("/usr/bin/python");
    }
  }

  if (await findExecutable("hotspotd") == null && !(await isProbablyDGBox())) {
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

  if (await fileExists("/etc/rpi-issue")) {
    var nf = new File("tools/hostapd_pi");
    await nf.copy("/usr/sbin/hostapd");
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
      print("This link should be ran as the superuser.");
    } else {
      await verifyDependencies();
    }
  }

  if (await isProbablyDGBox()) {
    try {
      await getAccessPointConfig();
    } catch (e) {
      await setAccessPointConfig("DGBox", "dg13ox11", "192.168.1.");
    }
  }

  var accessPointConfig = await getAccessPointConfig();

  var map = {
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
    "Current_Time": {
      r"$name": "Current Time",
      r"$type": "string",
      "?value": new DateTime.now().toIso8601String()
    },
    "Set_Current_Time": {
      r"$name": "Set Current Time",
      r"$invokable": "write",
      r"$is": "setDateTime",
      r"$params": [
        {
          "name": "time",
          "type": "string"
        }
      ],
      r"$columns": [
        {
          "name": "success",
          "type": "bool"
        },
        {
          "name": "message",
          "type": "string"
        }
      ],
      r"$result": "values"
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
    "Name_Servers": {
      r"$name": "Nameservers",
      r"$type": "string",
      "?value": (await getCurrentNameServers()).join(",")
    },
    "Access_Point": {
      r"$name": "Access Point",
      "Start": {
        r"$name": "Start",
        r"$is": "startAccessPoint",
        r"$invokable": "write",
        r"$result": "values"
      },
      "Stop": {
        r"$name": "Stop",
        r"$is": "stopAccessPoint",
        r"$invokable": "write",
        r"$result": "values"
      },
      "Restart": {
        r"$name": "Restart",
        r"$is": "restartAccessPoint",
        r"$invokable": "write",
        r"$result": "values"
      },
      "Status": {
        r"$type": "bool",
        "?value": await isAccessPointOn()
      },
      "IP": {
        r"$type": "string",
        "?value": accessPointConfig["ip"],
        r"$writable": "write"
      },
      "SSID": {
        r"$type": "string",
        "?value": accessPointConfig["ssid"],
        r"$writable": "write"
      },
      "Password": {
        r"$type": "string",
        "?value": accessPointConfig["password"],
        r"$writable": "write",
        r"$editor": "password"
      },
      "Subnet": {
        r"$type": "string",
        "?value": accessPointConfig["netmask"]
      }
    },
    "Ethernet": {},
    "Wireless": {}
  };

  if (!(await isProbablyDGBox())) {
    map["Access_Point"].addAll({
      "Interface": {
        r"$type": "enum[]",
        "?value": (await getAccessPointConfig())["wlan"],
        r"$writable": "write"
      },
      "Internet": {
        r"$type": "enum[]",
        "?value": (await getAccessPointConfig())["inet"],
        r"$writable": "write"
      }
    });
  }

  link = new LinkProvider(args, "Host-",
    defaultNodes: map, profiles: {
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
      await new Future.delayed(const Duration(seconds: 5));
      await startAccessPoint();
    }),
    "shutdown": addAction((Map<String, dynamic> params) {
      System.shutdown();
    }),
    "configureNetworkManual": addAction((Path path, Map<String, dynamic> params) async {
      var name = new Path(path.parentPath).name;
      var result = await configureNetworkManual(name, params["ip"], params["subnet"], params["router"]);

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
    "getSubnetIp": addAction((Path path, Map<String, dynamic> params) async {
      var name = new Path(path.parentPath).name;
      return {
        "subnet": await getSubnetIp(name)
      };
    }),
    "getGatewayIp": addAction((Path path, Map<String, dynamic> params) async {
      var name = new Path(path.parentPath).name;
      return {
        "gateway": await getGatewayIp(name)
      };
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
    "setDateTime": addAction((Map<String, dynamic> params) async {
      try {
        var time = DateTime.parse(params["time"]);
        var result = await Process.run("date", [createSystemTime(time)]);
        return {
          "success": result.exitCode == 0,
          "message": ""
        };
      } catch (e) {
        return {
          "success": false,
          "message": e.toString()
        };
      }
    }),
    "enableCaptivePortal": addAction((Map<String, dynamic> params) async {
      var conf = await readCaptivePortalConfig();
      conf = removeCaptivePortalConfig(conf);
      var cpn = await getAccessPointConfig();
      if (cpn != null && cpn.containsKey("ip")) {
        conf += "\n" + getDnsMasqCaptivePortal(cpn["ip"]);
      }
      await writeCaptivePortalConfig(conf);
      await restartDnsMasq();

      return {
        "success": true
      };
    }),
    "disableCaptivePortal": addAction((Map<String, dynamic> params) async {
      var conf = await readCaptivePortalConfig();
      conf = removeCaptivePortalConfig(conf);
      await writeCaptivePortalConfig(conf);
      await restartDnsMasq();

      return {
        "success": true
      };
    })
  }, autoInitialize: false);

  link.init();
  link.connect();

  timer = new Timer.periodic(const Duration(seconds: 5), (_) async {
    await synchronize();
  });

  await synchronize();

  SimpleNode currentTimeNode = link.getNode("/Current_Time");

  Scheduler.every(Interval.HALF_SECOND, () {
    if (currentTimeNode.hasSubscriber) {
      currentTimeNode.updateValue(new DateTime.now().toIso8601String());
    }
  });

  link["/Access_Point/IP"].subscribe(updateAccessPointSettings);
  link["/Access_Point/SSID"].subscribe(updateAccessPointSettings);
  link["/Access_Point/Password"].subscribe(updateAccessPointSettings);

  if (!(await isProbablyDGBox())) {
    link["/Access_Point/Internet"].subscribe(updateAccessPointSettings);
    link["/Access_Point/Interface"].subscribe(updateAccessPointSettings);
  }
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

synchronize() async {
  var nameservers = (await getCurrentNameServers()).join(",");

  if (nameservers.isNotEmpty) {
    link.updateValue("/Name_Servers", nameservers);
  }

  List<String> ifaces = await listNetworkInterfaces();
  SimpleNode ethernetNode = link["/Ethernet"];
  SimpleNode wirelessNode = link["/Wireless"];

  for (SimpleNode child in ethernetNode.children.values) {
    if (child.configs[r"$host_network"] != null && !ifaces.contains(child.configs[r"$host_network"])) {
      ethernetNode.removeChild(child);
    }
  }

  for (SimpleNode child in wirelessNode.children.values) {
    if (child.configs[r"$host_network"] != null && !ifaces.contains(child.configs[r"$host_network"])) {
      wirelessNode.removeChild(child);
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

    var addrs = await getNetworkAddresses(iface);

    m["Addresses"] = {
      r"$type": "string",
      "?value": addrs.join(",")
    };

    m["Subnet"] = {
      r"$type": "string",
      "?value": await getSubnetIp(iface)
    };

    m["Gateway"] = {
      r"$type": "string",
      "?value": await getGatewayIp(iface)
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
          "name": "subnet",
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

      if (wirelessNode.children.containsKey(iface)) {
        var n = link.getNode("/Wireless/${iface}");
        n.load(m);
      } else {
        link.addNode("/Wireless/${iface}", m);
      }
    } else {
      if (ethernetNode.children.containsKey(iface)) {
        var n = link.getNode("/Ethernet/${iface}");
        n.load(m);
      } else {
        link.addNode("/Ethernet/${iface}", m);
      }
    }
  }

  link.val("/Access_Point/Status", await isAccessPointOn());

  if (!(await isProbablyDGBox())) {
    link["/Access_Point/Internet"].configs[r"$type"] = buildEnumType(ifaces);
    link["/Access_Point/Interface"].configs[r"$type"] = buildEnumType(ifaces);
  }
}

Future updateAccessPointSettings([ValueUpdate update]) async {
  var ip = link.val("/Access_Point/IP");
  var ssid = link.val("/Access_Point/SSID");
  var password = link.val("/Access_Point/Password");

  if (await isProbablyDGBox()) {
    await setAccessPointConfig(ssid, password, ip);
  } else {
    var internet = link.val("/Access_Point/Internet");
    var interface = link.val("/Access_Point/Interface");
    await setAccessPointConfig(ssid, password, ip, interface, internet);
  }
}

Future<String> getPythonModuleDirectory() async {
  var result = await exec("python2", args: ["-"], stdin: [
  "import hotspotd.main",
  "x = hotspotd.main.__file__.split('/')",
  "print('/'.join(x[0:len(x) - 1]))"
  ].join("\n"), writeToBuffer: true);

  return result.stdout.trim();
}

Future updateTimezone() async {
  link.updateValue("/Timezone", await getCurrentTimezone());
}

Future<Map<String, dynamic>> getAccessPointConfig() async {
  if (await isProbablyDGBox()) {
    var file = new File("/root/.uap0.conf");
    var content = await file.readAsString();
    var lines = content.split("\n");
    var map = {};
    for (var line in lines) {
      line = line.trim();

      if (line.isEmpty) {
        continue;
      }

      var parts = line.split("=");
      var key = parts[0];
      var value = parts.skip(1).join("=");
      if (value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }

      map[key] = value;
    }

    return {
      "ip": map["ADDRESS"],
      "ssid": map["SSID"],
      "password": map["PASSKEY"],
      "netmask": "255.255.255.0"
    };
  }

  var file = new File("${await getPythonModuleDirectory()}/hotspotd.json");
  if (!(await file.exists())) {
    return {};
  }

  var json  = JSON.decode(await file.readAsString());

  return {
    "ssid": json["SSID"],
    "ip": json["ip"],
    "password": json["password"],
    "netmask": json["netmask"]
  };
}

Future setAccessPointConfig(String ssid, String password, String ip, [String wifi, String internet]) async {
  if (await isProbablyDGBox()) {
    var uapConfig = [
      "ADDRESS=${ip}",
      "SSID=\"${ssid}\"",
      "PASSKEY=\"${password}\""
    ];

    var uapFile = new File("/root/.uap0.conf");
    await uapFile.writeAsString(uapConfig.join("\n"));
    var ml = ip.split(".").take(3).join(".");
    var dhcpConfig = [
      "start\t${ml}.100",
      "end\t${ml}.200",
      "interface\tuap0",
      "opt\tlease\t86400",
      "opt\trouter\t${ml}.1",
      "opt\tsubnet\t255.255.255.0",
      "opt\tdns\t${ml}.1",
      "opt\tdomain\tlocaldomain",
      "max_leases\t101",
      "lease_file\t/var/lib/udhcpd.leases",
      "auto_time\t5"
    ];
    var dhcpFile = new File("/etc/udhcpd.conf");
    await dhcpFile.writeAsString(dhcpConfig.join("\n"));
    return;
  }

  if (wifi == internet) {
    return;
  }

  var config = generateHotspotDaemonConfig(wifi, internet, ssid, ip, "255.255.255.0", password);

  var file = new File("${await getPythonModuleDirectory()}/hotspotd.json");
  if (!(await file.exists())) {
    await file.create(recursive: true);
  }

  await file.writeAsString(config);
}

Future<List<String>> getNetworkAddresses(String name) async {
  var interfaces = await NetworkInterface.list();
  var interface = interfaces.firstWhere((x) => x.name == name, orElse: () => null);

  if (interface == null) {
    return [];
  }

  return interface.addresses.map((x) => x.address).toList();
}
