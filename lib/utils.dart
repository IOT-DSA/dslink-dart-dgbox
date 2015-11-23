library dslink.host.utils;

import "dart:async";
import "dart:convert";
import "dart:io";

import "package:path/path.dart" as pathlib;
import "package:intl/intl.dart";

typedef void ProcessHandler(Process process);
typedef void OutputHandler(String str);

Stdin get _stdin => stdin;

Directory currentDir = Directory.current;

class BetterProcessResult extends ProcessResult {
  final String output;

  BetterProcessResult(int pid, int exitCode, stdout, stderr, this.output)
      : super(pid, exitCode, stdout, stderr);
}

Future<BetterProcessResult> exec(String executable,
    {List<String> args: const [], String workingDirectory,
    Map<String, String> environment, bool includeParentEnvironment: true,
    bool runInShell: false, stdin, ProcessHandler handler,
    OutputHandler stdoutHandler, OutputHandler stderrHandler,
    OutputHandler outputHandler, File outputFile, bool inherit: false,
    bool writeToBuffer: false}) async {
  IOSink raf;

  if (workingDirectory == null && currentDir != null) {
    workingDirectory = currentDir.path;
  }

  if (outputFile != null) {
    if (!(await outputFile.exists())) {
      await outputFile.create(recursive: true);
    }

    raf = await outputFile.openWrite(mode: FileMode.APPEND);
  }

  try {
    Process process = await Process.start(executable, args,
        workingDirectory: workingDirectory,
        environment: environment,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell);

    if (raf != null) {
      await raf.writeln(
          "[${currentTimestamp}] == Executing ${executable} with arguments ${args} (pid: ${process.pid}) ==");
    }

    var buff = new StringBuffer();
    var ob = new StringBuffer();
    var eb = new StringBuffer();

    process.stdout.transform(UTF8.decoder).listen((str) async {
      if (writeToBuffer) {
        ob.write(str);
        buff.write(str);
      }

      if (stdoutHandler != null) {
        stdoutHandler(str);
      }

      if (outputHandler != null) {
        outputHandler(str);
      }

      if (inherit) {
        stdout.write(str);
      }

      if (raf != null) {
        await raf.writeln("[${currentTimestamp}] ${str}");
      }
    });

    process.stderr.transform(UTF8.decoder).listen((str) async {
      if (writeToBuffer) {
        eb.write(str);
        buff.write(str);
      }

      if (stderrHandler != null) {
        stderrHandler(str);
      }

      if (outputHandler != null) {
        outputHandler(str);
      }

      if (inherit) {
        stderr.write(str);
      }

      if (raf != null) {
        await raf.writeln("[${currentTimestamp}] ${str}");
      }
    });

    if (handler != null) {
      handler(process);
    }

    if (stdin != null) {
      if (stdin is Stream) {
        stdin.listen(process.stdin.add, onDone: process.stdin.close);
      } else if (stdin is List) {
        process.stdin.add(stdin);
      } else {
        process.stdin.write(stdin);
        await process.stdin.close();
      }
    } else if (inherit) {
      _stdin.listen(process.stdin.add, onDone: process.stdin.close);
    }

    var code = await process.exitCode;
    var pid = process.pid;

    if (raf != null) {
      await raf
          .writeln("[${currentTimestamp}] == Exited with status ${code} ==");
      await raf.flush();
      await raf.close();
    }

    return new BetterProcessResult(
        pid, code, ob.toString(), eb.toString(), buff.toString());
  } finally {
    if (raf != null) {
      await raf.flush();
      await raf.close();
    }
  }
}

Future<String> findExecutable(String name) async {
  var paths =
      Platform.environment["PATH"].split(Platform.isWindows ? ";" : ":");
  var tryFiles = [name];

  if (Platform.isWindows) {
    tryFiles.addAll(["${name}.exe", "${name}.bat"]);
  }

  for (var p in paths) {
    if (Platform.environment.containsKey("HOME")) {
      p = p.replaceAll("~/", Platform.environment["HOME"]);
    }

    var dir = new Directory(pathlib.normalize(p));

    if (!(await dir.exists())) {
      continue;
    }

    for (var t in tryFiles) {
      var file = new File("${dir.path}/${t}");

      if (await file.exists()) {
        return file.path;
      }
    }
  }

  return null;
}

Future<bool> isPortOpen(int port, {String host: "0.0.0.0"}) async {
  try {
    ServerSocket server = await ServerSocket.bind(host, port);
    await server.close();
    return true;
  } catch (e) {
    return false;
  }
}

String get currentTimestamp {
  return new DateTime.now().toString();
}

String fseType(FileSystemEntity entity) {
  if (entity is Directory) {
    return "directory";
  } else if (entity is File) {
    return "file";
  } else if (entity is Link) {
    return "link";
  }

  return "unknown";
}

Future<bool> setWifiNetwork(
    String interface, String ssid, String password) async {
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
    if (await isProbablyDGBox()) {
      try {
        var c = await WifiConfig.read();
        c.passkey = password;
        c.ssid = ssid;
        await c.write();
        var result = await Process.run("bash", ["${currentDir.path}/tools/dreamplug/wireless.sh", "client"]);
        return result.exitCode == 0;
      } catch (e) {
        return false;
      }
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
}

Future startAccessPoint() async {
  if (await isProbablyDGBox()) {
    await exec("bash", args: ["${currentDir.path}/tools/dreamplug/wireless.sh", "base"]);
  } else {
    await Process.run("hotspotd", ["start"]);
  }
}

Future stopAccessPoint() async {
  if (await isProbablyDGBox()) {
    await exec("bash", args: ["${currentDir.path}/tools/dreamplug/wireless.sh", "client"]);
  } else {
    await Process.run("hotspotd", ["stop"]);
    await Process.run("pkill", ["hostapd"]);
  }
}

Future<bool> isAccessPointOn() async {
  if (await isProbablyDGBox()) {
    return (await exec("ifconfig", args: ["uap0"])).exitCode != 1;
  }

  return (await Process.run("pgrep", ["hostapd"])).exitCode == 0;
}

Future<bool> isWifiInterface(String name) async {
  if (Platform.isMacOS) {
    var result = await Process.run("networksetup", ["-listallhardwareports"]);

    if (result.exitCode != 0) {
      return false;
    }

    List<String> lines =
        result.stdout.split("\n").map((x) => x.trim()).toList();

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

  var script = await NetworkInterfaceScript.read();
  var iface = script.getInterface(interface);

  if (iface == null) {
    return false;
  }

  iface.netmask = null;
  iface.gateway = null;
  iface.address = null;

  await script.write();
  return true;
}

Future restartNetworkService(String iface, [bool wlan = false]) async {
  if (wlan && await isProbablyDGBox()) {
    await Process.run("pkill", ["dhclient"]);
  }

  await Process.run("ifdown", [iface]);
  await new Future.delayed(const Duration(seconds: 1));
  var resultB = await Process.run("ifup", [iface]);

  if (wlan && await isProbablyDGBox()) {
    await exec("bash", args: ["${currentDir.path}/tools/dreamplug/wireless.sh", "client"]);
  }

  return resultB.exitCode == 0;
}

Future configureNetworkManual(
    String interface, String ip, String netmask, String gateway) async {
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

  var script = await NetworkInterfaceScript.read();
  var iface = script.getInterface(interface);

  if (iface == null) {
    return false;
  }

  if (netmask != null) {
    iface.netmask = netmask;
  }

  if (gateway != null) {
    iface.gateway = gateway;
  }

  if (ip != null) {
    iface.address = ip;
  }

  await script.write();

  return true;
}

class WifiConfig {
  String ssid;
  String passkey;

  WifiConfig([this.ssid, this.passkey]);

  static WifiConfig parse(String input) {
    var s = SSID_REGEX.firstMatch(input).group(1);
    String p;
    try {
      p = PSK_REGEX.firstMatch(input).group(1);
    } catch (e) {}
    return new WifiConfig(s, p);
  }

  static Future<WifiConfig> read() async {
    var file = new File("/root/.mlan.conf");
    if (!(await file.exists())) {
      return new WifiConfig();
    }
    return parse(await file.readAsString());
  }

  Future write() async {
    var file = new File("/root/.mlan.conf");
    await file.writeAsString(await build());
  }

  static final RegExp SSID_REGEX = new RegExp('ssid="(.*?)"');
  static final RegExp PSK_REGEX = new RegExp('"#psk="(.*?)"');

  Future<String> build() async {
    var buff = new StringBuffer();
    buff.writeln("network={");
    buff.writeln('\tssid="${ssid}"');
    if (passkey != null && passkey.isNotEmpty) {
      buff.writeln("\tproto=WPA");
      buff.writeln("\tkey_mgmt=WPA-PSK");
      buff.writeln('\t#psk="${passkey}"');
      var r = await Process.run("wpa_passphrase", [ssid, passkey]);
      String x = r.stdout.split("\n")[3].trim().split("=").last;
      buff.writeln('\tpsk=${x}');
    } else {
      buff.writeln("\tkey_mgmt=NONE");
    }
    buff.writeln("}");
    return buff.toString();
  }
}

Future<bool> isInterfaceUp(String iface) async {
  if (!Platform.isLinux) {
    return true;
  }

  var file = new File("/sys/class/net/${iface}/operstate");

  if (!(await file.exists())) {
    return false;
  }

  return (await file.readAsString()).contains("up");
}

class NetworkInterfaceScript {
  final List<NetworkInterfaceScriptEntry> entries;

  NetworkInterfaceScript(this.entries);

  NetworkInterfaceScriptEntry getInterface(String iface) {
    return entries.firstWhere((x) => x.interface == iface, orElse: () => null);
  }

  static NetworkInterfaceScript parse(String input) {
    List<String> lines = input.split("\n");
    lines.removeWhere((x) => x.startsWith("#"));
    var entries = [];
    var sections = [];

    var buffz = [];
    for (var line in lines) {
      if (line.isEmpty && buffz.isNotEmpty) {
        buffz.removeWhere((x) => x.isEmpty || x.startsWith("auto "));
        sections.add(buffz.map((n) => n.trim()).toList());
        buffz = [];
      } else {
        buffz.add(line);
      }
    }

    for (var section in sections) {
      try {
        var inf = section[0];
        String iface;
        String address;
        String netmask;
        String gateway;
        String type;

        var map = {};

        for (var s in section.skip(1)) {
          var p = s.split(" ");
          map[p[0]] = p.skip(1).join(" ");
        }

        {
          var parts = inf.split(" ");
          iface = parts[1];
          type = parts[3];
        }

        if (type == "static") {
          address = map["address"];
          netmask = map["netmask"];
          gateway = map["gateway"];
        }

        if (type == "dhcp") {
          entries.add(new NetworkInterfaceScriptEntry.dhcp(iface));
        } else {
          entries.add(new NetworkInterfaceScriptEntry(iface, address, netmask, gateway));
        }
      } catch (e) {}
    }

    return new NetworkInterfaceScript(entries);
  }

  static Future<NetworkInterfaceScript> read() async {
    var file = new File("/etc/network/interfaces");
    var content = await file.readAsString();

    return NetworkInterfaceScript.parse(content);
  }

  write() async {
    var file = new File("/etc/network/interfaces");
    if (!(await file.parent.exists())) {
      await file.parent.create(recursive: true);
    }
    await file.writeAsString(build());
  }

  String build() {
    var buff = new StringBuffer();
    for (var entry in entries) {
      buff.writeln(entry.build());
    }
    return buff.toString();
  }
}

class NetworkInterfaceScriptEntry {
  final String interface;
  String address;
  String netmask;
  String gateway;

  NetworkInterfaceScriptEntry(this.interface, this.address, this.netmask, this.gateway);
  NetworkInterfaceScriptEntry.dhcp(this.interface) : address = null, netmask = null, gateway = null;

  String build() {
    var buff = new StringBuffer();
    if (interface == "lo") {
      buff.writeln("auto ${interface}");
      buff.writeln("iface lo inet loopback");
      return buff.toString();
    }

    if (address == null) {
      buff.writeln("iface ${interface} inet dhcp");
    } else {
      buff.writeln("iface ${interface} inet static");
      buff.writeln("\taddress ${address}");
      buff.writeln("\tnetmask ${netmask}");
      buff.writeln("\tgateway ${gateway}");
    }

    return buff.toString();
  }
}

Future<String> getWifiNetwork(String interface) async {
  if (Platform.isMacOS) {
    var result =
        await Process.run("networksetup", ["-getairportnetwork", interface]);
    if (result.exitCode != 0) {
      return null;
    } else {
      return result.stdout.trim().replaceAll("Current Wi-Fi Network: ", "");
    }
  } else {
    if (await isProbablyDGBox()) {
      try {
        var conf = await WifiConfig.read();
        if (conf.ssid != null) {
          return conf.ssid;
        }
      } catch (e) {}
    }

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
    var airport =
        "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/A/Resources/airport";
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

    String out = result.stdout;

    var parts = out.split("Extra:");
    var networks = [];

    for (var part in parts) {
      if (!part.contains("ESSID:")) {
        continue;
      }

      var matches = SSID_REGEXP.allMatches(part);
      if (matches.isEmpty) {
        continue;
      }

      var ssid = matches.first.group(1);
      var hasSecurity = part.contains("Encryption key:on");
      networks.add(new WifiNetwork(ssid, hasSecurity));
    }

    return networks;
  }
}

final RegExp SSID_REGEXP = new RegExp(r'ESSID:"(.*)"');

Future<String> getCurrentWifiNetwork(String iface) async {
  if (Platform.isLinux) {
    var result = await Process.run("iwgetid", [iface]);
    String line = result.stdout.split("\n").first;
    var parts = line.split("ESSID:");
    var ssid = parts.skip(1).join();
    ssid = ssid.substring(1, ssid.length - 1);
    return ssid;
  } else {
    return "";
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
        isUnix ? "poweroff" : "shutdown", isUnix ? [] : ["-h", "now"]);

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
      .where((x) => x.isNotEmpty && !x.startsWith("#"))
      .toList();

  return lines
      .where((x) => x.startsWith("nameserver "))
      .map((x) => x.replaceAll("nameserver ", ""))
      .toList();
}

Future<bool> setCurrentNameServers(List<String> servers) async {
  var file = new File("/etc/resolv.conf");

  if (!(await file.parent.exists())) {
    await file.parent.create(recursive: true);
  }

  var lines = (await file.readAsLines())
    .map((x) => x.trim())
    .toList();
  lines.removeWhere((x) => x.startsWith("nameserver "));
  servers.map((x) => "nameserver ${x}").forEach(lines.add);
  await file.writeAsString(lines.join("\n"));

  return true;
}

Future<String> getCurrentTimezone() async {
  var type = await FileSystemEntity.type("/etc/localtime", followLinks: false);

  if (type == FileSystemEntityType.LINK) {
    var link = new Link("/etc/localtime");

    return (await link.resolveSymbolicLinks()).substring("/usr/share/zoneinfo/".length);
  } else if (type == FileSystemEntityType.FILE) {
    var mf = new File("/etc/localtime");
    var tz = await getAllTimezones();
    List<File> files = tz.map((x) => new File("/usr/share/zoneinfo/${x}")).toList();
    var codec = new Utf8Codec(allowMalformed: true);
    var mfb = await mf.readAsString(encoding: codec);
    var i = 0;
    for (var file in files) {
      try {
        if (await file.readAsString(encoding: codec) == mfb) {
          return tz[i];
        }
      } catch (e) {}
      i++;
    }
  }

  return "UTC";
}

Future<List<String>> getAllTimezones() async {
  var dir = new Directory("/usr/share/zoneinfo");

  if (!(await dir.exists())) {
    return ["UTC"];
  }

  var files = await dir.list(recursive: true).toList();
  var zones = [];

  for (var file in files) {
    if (file is! File) {
      continue;
    }

    if (file.path.contains(".")) {
      continue;
    }

    var name = file.path.substring("/usr/share/zoneinfo/".length);

    if (name[0].toLowerCase() == name[0]) {
      continue;
    }

    zones.add(name);
  }

  zones.sort();

  return zones;
}

bool _hasAptUpdated = false;

Future installPackage(String pkg) async {
  if (Platform.isMacOS) {
    throw new Exception("Installing Packages on Mac OS X is not supported.");
  }

  var isArchLinux = await fileExists("/etc/arch-release");
  var isDebian = await fileExists("/usr/bin/apt-get");

  runCommand(String cmd, List<String> args) async {
    var result = await exec(cmd, args: args, inherit: true);
    if (result.exitCode != 0) {
      print("Failed to install package: ${pkg}");
      exit(1);
    }
  }

  if (isArchLinux) {
    await runCommand("pacman", ["-S", pkg]);
  } else if (isDebian) {
    if (!_hasAptUpdated) {
      await runCommand("apt-get", ["update"]);
      _hasAptUpdated = true;
    }

    await runCommand("apt-get", ["install", pkg]);
  } else {
    print("Unknown Linux Distribution. Please install the package '${pkg}' with your distribution's package manager.");
    exit(1);
  }
}

class LedManager {
  Map<String, int> _maxBrightnessCache = {};
  Map<String, File> _ledFileCache = {};

  Future<int> getMaxBrightness(String name) async {
    if (_maxBrightnessCache.containsKey(name)) {
      return _maxBrightnessCache[name];
    }
    var file = new File("/sys/class/leds/${name}/max_brightness");
    var str = await file.readAsString();
    str = str.trim();
    var mb = int.parse(str);
    return _maxBrightnessCache[name] = mb;
  }

  Future<int> getBrightness(String name) async {
    File file;
    if (_ledFileCache.containsKey(name)) {
      file = _ledFileCache[name];
    } else {
      file = new File("/sys/class/leds/${name}/brightness");
      _ledFileCache[name] = file;
    }
    var str = await file.readAsString();
    return int.parse(str.trim());
  }

  Future setBrightness(String name, int brightness) async {
    File file;
    if (_ledFileCache.containsKey(name)) {
      file = _ledFileCache[name];
    } else {
      file = new File("/sys/class/leds/${name}/brightness");
      _ledFileCache[name] = file;
    }
    await file.writeAsString(brightness.toString());
  }

  Future<List<String>> list() async {
    return await LINUX_LED_DIR.list()
      .where((x) => x is Directory)
      .map((x) => pathlib.basename(x.path))
      .toList();
  }
}

final LedManager ledManager = new LedManager();

Directory LINUX_LED_DIR = new Directory("/sys/class/leds");

Future<bool> fileExists(String path) async => await new File(path).exists();

Future setCurrentTimezone(String name) async {
  var path = "/usr/share/zoneinfo/${name}";
  var rp = "/etc/localtime";
  if (!(await FileSystemEntity.isLink(rp))) {
    var file = new File("/etc/localtime");
    await file.writeAsBytes(await new File(path).readAsBytes());
  } else {
    var link = new Link("/etc/localtime");
    if (await link.exists()) {
      await link.delete();
    }

    await link.create(path);
  }
}

Future<bool> isProbablyDGBox() async {
  if (!Platform.isLinux) {
    return false;
  }

  if (_dgbox != null) {
    return _dgbox;
  }
  var file = new File("/proc/cpuinfo");
  var content = await file.readAsString();

  return _dgbox = content.contains("Feroceon 88FR131 rev 1 (v5l)");
}

File _dnsMasqFile = new File("/etc/dnsmaq.conf");

Future<String> readCaptivePortalConfig() async {
  return await _dnsMasqFile.readAsString();
}

Future writeCaptivePortalConfig(String config) async {
  await _dnsMasqFile.writeAsString(config);
}

Future<bool> hasCaptivePortalInConfig() async {
  var content = await _dnsMasqFile.readAsString();
  if (content.contains("## Begin DSA Host DSLink ##")) {
    return true;
  }
  return false;
}

bool _dgbox;

String getDnsMasqCaptivePortal(String address) {
  return [
    "## Begin DSA Host DSLink ##",
    "address=/#/${address}",
    "## End DSA Host DSLink ##"
  ].join("\n");
}

Future restartDnsMasq() async {
  if (await fileExists("/etc/init.d/dnsmasq")) {
    await exec("service", args: ["dnsmasq", "restart"]);
  } else {
    await exec("systemctl", args: ["restart", "dnsmasq"]);
  }
}

String removeCaptivePortalConfig(String input) {
  var lines = input.split("\n");
  var out = [];
  var flag = false;
  for (var line in lines) {
    if (line == "## Begin DSA Host DSLink ##" || line == "## End DSA Host DSLink ##") {
      flag = !flag;
    } else if (!flag) {
      out.add(line);
    }
  }
  return out.join("\n");
}

Future<String> getGatewayIp(String interface) async {
  try {
    if (Platform.isMacOS) {
      var no = await Process.run("networksetup", ["-getinfo", await getNetworkServiceForInterface(interface)]);
      String out = no.stdout;
      var lines = out.split("\n");
      for (var line in lines) {
        if (line.startsWith("Router: ")) {
          return line.substring("Router: ".length);
        }
      }
      return "unknown";
    }
  } catch (e) {}

  try {
    var script = await NetworkInterfaceScript.read();
    var gw = script.getInterface(interface).gateway;
    if (gw != null) {
      return gw;
    }
  } catch (e) {
  }

  try {
    var ro = await Process.run("ip", ["route", "show"]);
    List<String> lines = ro.stdout.toString().split("\n");
    lines.removeWhere((x) => !x.startsWith("default via "));
    if (lines.isNotEmpty) {
      var line = lines.first.split(" ")[2];
      return line;
    }
  } catch (e) {}

  return "0.0.0.0";
}

Future<String> getSubnetIp(String interface) async {
  try {
    if (Platform.isMacOS) {
      var no = await Process.run("networksetup", ["-getinfo", await getNetworkServiceForInterface(interface)]);
      String out = no.stdout;
      var lines = out.split("\n");
      lines.removeAt(0);
      lines.removeAt(0);
      for (var line in lines) {
        if (line.startsWith("Subnet mask: ")) {
          return line.substring("Subnet mask: ".length);
        }
      }
      return "unknown";
    }

    if (await isInterfaceDHCP(interface)) {
      var ro = await Process.run("route", ["-n"]);
      List<String> lines = ro.stdout.toString().split("\n");
      for (var line in lines) {
        var parts = reflix(line).split(" ");
        parts = parts.map((x) => x.trim()).toList();
        parts.removeWhere((x) => x.isEmpty);

        if (parts.length < 7) {
          continue;
        }

        var iface = parts[7];
        if (iface == interface && parts[2] != "0.0.0.0") {
          return parts[2];
        }
      }
    } else {
      var m = await NetworkInterfaceScript.read();
      return m.getInterface(interface).netmask;
    }
  } catch (e) {}
  return "0.0.0.0";
}

Future<bool> isInterfaceDHCP(String iface) async {
  if (!Platform.isLinux) {
    return false;
  }

  var script = await NetworkInterfaceScript.read();
  var interface = script.getInterface(iface);

  if (interface == null) {
    return false;
  }

  return interface.address == null;
}

String reflix(String n) {
  while (n.contains("  ")) {
    n = n.replaceAll("  ", " ");
  }

  n = n.replaceAll("\t", " ");
  return n;
}

String createSystemTime(DateTime date) {
  var format = new DateFormat("MMddHHmmyyyy.ss");
  return format.format(date);
}
