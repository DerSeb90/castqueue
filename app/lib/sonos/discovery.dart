import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'soap.dart';
import 'sonos_device.dart';

const _ssdpAddress = '239.255.255.250';
const _ssdpPort = 1900;
const _zonePlayerSt = 'urn:schemas-upnp-org:device:ZonePlayer:1';
const zoneGroupTopologyService = 'urn:schemas-upnp-org:service:ZoneGroupTopology:1';
const zoneGroupTopologyControl = '/ZoneGroupTopology/Control';

/// Raw SSDP responder before topology resolution.
class SsdpResponder {
  const SsdpResponder({required this.uuid, required this.location});

  /// UUID without `uuid:` prefix.
  final String uuid;
  final Uri location;

  String get host => location.host;
  int get port => location.hasPort ? location.port : 1400;
}

/// One member of a zone group as reported by ZoneGroupTopology.
class ZoneGroupMember {
  const ZoneGroupMember({
    required this.uuid,
    required this.zoneName,
    required this.host,
    required this.port,
    this.invisible = false,
  });

  final String uuid;
  final String zoneName;
  final String host;
  final int port;

  /// Sub, surrounds, bonded stereo partner, … — not selectable.
  final bool invisible;
}

class ZoneGroup {
  const ZoneGroup({required this.coordinatorUuid, required this.members});

  final String coordinatorUuid;
  final List<ZoneGroupMember> members;

  ZoneGroupMember? get coordinator =>
      members.where((m) => m.uuid == coordinatorUuid).firstOrNull;

  List<ZoneGroupMember> get visibleMembers => members.where((m) => !m.invisible).toList();
}

/// Sonos discovery via SSDP + ZoneGroupTopology.
///
/// Uses unicast M-SEARCH requests; the responses come back unicast to our
/// socket, so no Android multicast lock is required for discovery. (A
/// multicast lock would only be needed to *receive* multicast NOTIFYs, which
/// this implementation does not rely on.)
class SonosDiscovery {
  SonosDiscovery._();

  /// Finds zone group coordinators in the LAN. Never throws; `[]` if none.
  static Future<List<SonosDevice>> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    List<SsdpResponder> responders;
    try {
      responders = await ssdpSearch(timeout: timeout);
    } catch (_) {
      return const [];
    }
    if (responders.isEmpty) return const [];

    // Ask one responder for the whole topology.
    for (final r in responders) {
      try {
        final groups = await fetchZoneGroups(Uri(scheme: 'http', host: r.host, port: r.port));
        final devices = coordinatorsFromGroups(groups);
        if (devices.isNotEmpty) return devices;
      } catch (_) {
        // try next responder
      }
    }

    // Fallback: the responders themselves, enriched via device description.
    final out = <SonosDevice>[];
    for (final r in responders) {
      try {
        out.add(await fromHost(r.host, port: r.port));
      } catch (_) {
        out.add(SonosDevice(uuid: r.uuid, roomName: r.host, host: r.host, port: r.port));
      }
    }
    out.sort((a, b) => a.roomName.toLowerCase().compareTo(b.roomName.toLowerCase()));
    return out;
  }

  /// Builds a device from `http://host:1400/xml/device_description.xml`.
  /// Throws [SonosException] if unreachable/unparseable.
  static Future<SonosDevice> fromHost(String host, {int port = 1400}) async {
    final uri = Uri(scheme: 'http', host: host.trim(), port: port, path: '/xml/device_description.xml');
    http.Response res;
    try {
      res = await http.get(uri).timeout(const Duration(seconds: 5));
    } catch (e) {
      throw SonosException('Cannot reach $host: $e');
    }
    if (res.statusCode != 200) {
      throw SonosException('$host answered HTTP ${res.statusCode}');
    }
    return parseDeviceDescription(res.body, host: host.trim(), port: port);
  }

  // ---- pure helpers (testable) -------------------------------------------

  static SonosDevice parseDeviceDescription(String xml, {required String host, int port = 1400}) {
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } catch (_) {
      throw const SonosException('Invalid device description');
    }
    final device = doc.findAllElements('device', namespaceUri: '*').firstOrNull;
    if (device == null) throw const SonosException('No <device> in description');
    String text(String name) =>
        device.findElements(name, namespaceUri: '*').firstOrNull?.innerText.trim() ?? '';
    final udn = text('UDN').replaceFirst(RegExp('^uuid:'), '');
    if (udn.isEmpty) throw const SonosException('No UDN in device description');
    var room = text('roomName');
    if (room.isEmpty) room = text('friendlyName');
    if (room.isEmpty) room = host;
    return SonosDevice(uuid: udn, roomName: room, host: host, port: port, modelName: text('modelName'));
  }

  /// Parses the (already unescaped) `ZoneGroupState` XML.
  static List<ZoneGroup> parseZoneGroupState(String xml) {
    XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } catch (_) {
      return const [];
    }
    final groups = <ZoneGroup>[];
    for (final g in doc.findAllElements('ZoneGroup')) {
      final coord = g.getAttribute('Coordinator') ?? '';
      final members = <ZoneGroupMember>[];
      for (final m in g.findElements('ZoneGroupMember')) {
        final uuid = m.getAttribute('UUID') ?? '';
        final loc = Uri.tryParse(m.getAttribute('Location') ?? '');
        if (uuid.isEmpty || loc == null || loc.host.isEmpty) continue;
        members.add(ZoneGroupMember(
          uuid: uuid,
          zoneName: m.getAttribute('ZoneName') ?? '',
          host: loc.host,
          port: loc.hasPort ? loc.port : 1400,
          invisible: m.getAttribute('Invisible') == '1',
        ));
      }
      if (members.isNotEmpty) groups.add(ZoneGroup(coordinatorUuid: coord, members: members));
    }
    return groups;
  }

  /// One [SonosDevice] per group (its coordinator), sorted by room name.
  static List<SonosDevice> coordinatorsFromGroups(List<ZoneGroup> groups) {
    final out = <SonosDevice>[];
    for (final g in groups) {
      final c = g.coordinator ?? g.visibleMembers.firstOrNull;
      if (c == null || c.invisible) continue;
      final others = g.visibleMembers.where((m) => m.uuid != c.uuid).length;
      final name = others > 0 ? '${c.zoneName} (+$others)' : c.zoneName;
      out.add(SonosDevice(uuid: c.uuid, roomName: name, host: c.host, port: c.port));
    }
    out.sort((a, b) => a.roomName.toLowerCase().compareTo(b.roomName.toLowerCase()));
    return out;
  }

  /// Parses one SSDP HTTP/1.1 response into a responder; `null` if not a Sonos.
  static SsdpResponder? parseSsdpResponse(String datagram) {
    final headers = <String, String>{};
    final lines = const LineSplitter().convert(datagram);
    if (lines.isEmpty) return null;
    for (final line in lines.skip(1)) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      headers[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
    }
    final location = Uri.tryParse(headers['location'] ?? '');
    final usn = headers['usn'] ?? '';
    if (location == null || location.host.isEmpty || usn.isEmpty) return null;
    final st = headers['st'] ?? '';
    final server = headers['server'] ?? '';
    if (!st.contains('ZonePlayer') && !server.contains('Sonos')) return null;
    final m = RegExp(r'uuid:([^:\s]+)').firstMatch(usn);
    final uuid = m?.group(1) ?? usn;
    return SsdpResponder(uuid: uuid, location: location);
  }

  // ---- network ------------------------------------------------------------

  static Future<List<SsdpResponder>> ssdpSearch({Duration timeout = const Duration(seconds: 3)}) async {
    // One socket per IPv4 interface (plus a wildcard one): on Windows with
    // Hyper-V/WSL/VPN adapters the wildcard socket alone may send the
    // M-SEARCH out of the wrong interface.
    final sockets = <RawDatagramSocket>[];
    try {
      sockets.add(await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0));
    } catch (_) {}
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLinkLocal: false);
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          try {
            sockets.add(await RawDatagramSocket.bind(addr, 0));
          } catch (_) {}
        }
      }
    } catch (_) {}
    if (sockets.isEmpty) return const [];

    final found = <String, SsdpResponder>{};
    final done = Completer<void>();
    final subs = <StreamSubscription<RawSocketEvent>>[];
    for (final socket in sockets) {
      socket.broadcastEnabled = true;
      subs.add(socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = socket.receive();
        if (dg == null) return;
        final text = utf8.decode(dg.data, allowMalformed: true);
        final r = parseSsdpResponse(text);
        if (r != null) found.putIfAbsent(r.uuid, () => r);
      }));
    }

    final msg = utf8.encode(
      'M-SEARCH * HTTP/1.1\r\n'
      'HOST: $_ssdpAddress:$_ssdpPort\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: 1\r\n'
      'ST: $_zonePlayerSt\r\n'
      '\r\n',
    );
    final target = InternetAddress(_ssdpAddress);

    // Send 3 times spread over the first 2/3 of the timeout.
    const sendCount = 3;
    final gap = Duration(milliseconds: (timeout.inMilliseconds * 2 ~/ 3) ~/ sendCount);
    for (var i = 0; i < sendCount; i++) {
      for (final socket in sockets) {
        try {
          socket.send(msg, target, _ssdpPort);
        } catch (_) {}
      }
      if (i < sendCount - 1) await Future<void>.delayed(gap);
    }

    Timer(timeout - gap * (sendCount - 1), () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    for (final sub in subs) {
      await sub.cancel();
    }
    for (final socket in sockets) {
      socket.close();
    }
    return found.values.toList();
  }

  static Future<List<ZoneGroup>> fetchZoneGroups(Uri baseUri) async {
    final client = SoapClient(baseUri);
    try {
      final res = await client.call(
        controlPath: zoneGroupTopologyControl,
        serviceType: zoneGroupTopologyService,
        action: 'GetZoneGroupState',
      );
      final raw = res['ZoneGroupState'] ?? '';
      if (raw.isEmpty) return const [];
      // innerText already unescapes one level; unescape again in case the
      // player double-escaped (some firmwares do).
      final xml = raw.trimLeft().startsWith('<') ? raw : xmlUnescape(raw);
      return parseZoneGroupState(xml);
    } finally {
      client.close();
    }
  }
}
