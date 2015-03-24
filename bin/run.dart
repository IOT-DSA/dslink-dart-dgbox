import "dart:async";
import "dart:convert";
import "dart:io";

import "package:dslink/client.dart";
import "package:dslink/responder.dart";
import "package:syscall/syscall.dart" as sys;

LinkProvider link;

main(List<String> args) async {
  try {
    sys.setUserId(0);
  } catch (e) {
    print("ERROR: You must run this under root.");
    print("Try this: sudo dart bin/run.dart");
    exit(1);
  }

  link = new LinkProvider(args, "System-");

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

  link.save();
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
  static void reboot() {
    withRoot(() {
      var result = Process.runSync("reboot", []);

      if (result.exitCode != 0) {
        print("ERROR: Failed to reboot.");
      }
    });
  }

  static void shutdown() {
    withRoot(() {
      var result = Process.runSync(
        Platform.isLinux ? "poweroff" : "shutdown",
        Platform.isLinux ? [] : ["-h", "now"]
      );

      if (result.exitCode != 0) {
        print("ERROR: Failed to shutdown. Exit Code: ${result.exitCode}");
      }
    });
  }

  static dynamic withRoot(handler()) {
    var muid = sys.getUserId();

    if (muid != 0) {
      try {
        sys.setUserId(0);
      } catch (e) {
        print("ERROR: Failed to gain superuser permissions.");
        return null;
      }
    }

    var value = handler();

    if (muid != 0) {
      sys.setUserId(muid);
    }

    return value;
  }
}
