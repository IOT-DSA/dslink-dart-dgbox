import "dart:async";
import "dart:convert";
import "dart:io";

import "package:dslink/client.dart";
import "package:dslink/responder.dart";

LinkProvider link;

main(List<String> args) async {
  link = new LinkProvider(args, "Platform-");

  link.registerFunctions({
    "system.reboot": (path, params) {
      System.reboot();
    },
    "system.shutdown": (path, params) {
      System.shutdown();
    }
  });

  link.provider.init({
    "Reboot": {
      r"$invokable": "write",
      r"$function": "system.reboot"
    },
    "Shutdown": {
      r"$invokable": "write",
      r"$function": "system.shutdown"
    },
    "Hostname": {
      r"$type": "string",
      "?value": Platform.localHostname
    },
    "Network Interfaces": {
    }
  });

  link.connect();

  timer = new Timer.periodic(new Duration(seconds: 15), (_) async {
    await syncNetworkStuff();
  });

  await syncNetworkStuff();
}

Timer timer;

syncNetworkStuff() async {
  var ns = await serializeNetworkState();
  if (_lastNetworkState == null || ns != _lastNetworkState) {
    _lastNetworkState = ns;
    var interfaces = await NetworkInterface.list();
    SimpleNode inode = link.provider.getNode("/Network Interfaces");

    for (SimpleNode child in inode.children.values) {
      inode.removeChild(child);
    }

    for (NetworkInterface interface in interfaces) {
      var m = {};

      for (var a in interface.addresses) {
        m[a.address] = {
          "IPv4": {
            r"$type": "bool",
            "?value": a.type == InternetAddressType.IP_V4
          },
          "IPv6": {
            r"$type": "bool",
            "?value": a.type == InternetAddressType.IP_V6
          }
        };
      }

      link.provider.addNode("/Network Interfaces/${interface.name}", m);
    }
  }
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

class System {
  static Future shutdown() async {
    if (Platform.isWindows) {
      var process = await Process.start("shutdown", ["/s"]);
      Future<int> exitCode = process.exitCode;
      await exitCode.timeout(new Duration(seconds: 5), onTimeout: () {
        print("Failed to Shutdown.");
      });
    } else {
      if (Platform.environment["USER"] != "root") {
        var process = await Process.start("sudo", ["poweroff"]);
        Future<int> exitCode = process.exitCode;
        await exitCode.timeout(new Duration(seconds: 5), onTimeout: () {
          print("Failed to Shutdown.");
          process.kill();
        });
      } else {
        var process = await Process.start("poweroff", []);
        Future<int> exitCode = process.exitCode;
        await exitCode.timeout(new Duration(seconds: 5), onTimeout: () {
          print("Failed to Shutdown.");
          process.kill();
        });
      }
    }
  }

  static Future reboot() async {
    if (Platform.isWindows) {
      var process = await Process.start("shutdown", ["/r"]);
      Future<int> exitCode = process.exitCode;
      await exitCode.timeout(new Duration(seconds: 5), onTimeout: () {
        print("Failed to Reboot.");
        process.kill();
      });
    } else {
      if (Platform.environment["USER"] != "root") {
        var process = await Process.start("sudo", ["reboot"]);
        Future<int> exitCode = process.exitCode;
        await exitCode.timeout(new Duration(seconds: 5), onTimeout: () {
          print("Failed to Reboot.");
          process.kill();
        });
      } else {
        var process = await Process.start("reboot", []);
        Future<int> exitCode = process.exitCode;
        await exitCode.timeout(new Duration(seconds: 5), onTimeout: () {
          print("Failed to Reboot.");
          process.kill();
        });
      }
    }
  }
}
