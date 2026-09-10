import 'package:castqueue/sonos/sonos.dart';
import 'package:flutter_test/flutter_test.dart';

const _zoneGroupState = '''
<ZoneGroupState>
  <ZoneGroups>
    <ZoneGroup Coordinator="RINCON_AAA01400" ID="RINCON_AAA01400:12">
      <ZoneGroupMember UUID="RINCON_AAA01400" Location="http://192.168.1.10:1400/xml/device_description.xml" ZoneName="Wohnzimmer" Icon="x:icon-living" Configuration="1"/>
      <ZoneGroupMember UUID="RINCON_BBB01400" Location="http://192.168.1.11:1400/xml/device_description.xml" ZoneName="Küche" Configuration="1"/>
      <ZoneGroupMember UUID="RINCON_SUB01400" Location="http://192.168.1.12:1400/xml/device_description.xml" ZoneName="Wohnzimmer" Invisible="1" Configuration="1"/>
    </ZoneGroup>
    <ZoneGroup Coordinator="RINCON_CCC01400" ID="RINCON_CCC01400:7">
      <ZoneGroupMember UUID="RINCON_CCC01400" Location="http://192.168.1.20:1400/xml/device_description.xml" ZoneName="Bad" Configuration="1"/>
    </ZoneGroup>
  </ZoneGroups>
  <VanishedDevices/>
</ZoneGroupState>
''';

const _deviceDescription = '''
<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType>
    <friendlyName>192.168.1.10 - Sonos One</friendlyName>
    <manufacturer>Sonos, Inc.</manufacturer>
    <modelName>Sonos One</modelName>
    <UDN>uuid:RINCON_AAA01400</UDN>
    <roomName>Wohnzimmer</roomName>
  </device>
</root>
''';

void main() {
  group('parseZoneGroupState', () {
    test('parses groups, members and invisible flag', () {
      final groups = SonosDiscovery.parseZoneGroupState(_zoneGroupState);
      expect(groups, hasLength(2));
      expect(groups[0].coordinatorUuid, 'RINCON_AAA01400');
      expect(groups[0].members, hasLength(3));
      expect(groups[0].visibleMembers, hasLength(2));
      expect(groups[0].members[2].invisible, isTrue);
      expect(groups[0].coordinator!.host, '192.168.1.10');
      expect(groups[0].coordinator!.port, 1400);
      expect(groups[1].coordinator!.zoneName, 'Bad');
    });

    test('coordinatorsFromGroups yields one device per group, sorted', () {
      final devices =
          SonosDiscovery.coordinatorsFromGroups(SonosDiscovery.parseZoneGroupState(_zoneGroupState));
      expect(devices.map((d) => d.roomName), ['Bad', 'Wohnzimmer (+1)']);
      expect(devices[1].uuid, 'RINCON_AAA01400');
      expect(devices[1].host, '192.168.1.10');
    });

    test('handles escaped payload via xmlUnescape', () {
      final escaped = xmlEscape(_zoneGroupState);
      final groups = SonosDiscovery.parseZoneGroupState(xmlUnescape(escaped));
      expect(groups, hasLength(2));
    });

    test('returns empty on garbage', () {
      expect(SonosDiscovery.parseZoneGroupState('not xml <'), isEmpty);
    });
  });

  group('parseDeviceDescription', () {
    test('extracts UDN, room, model', () {
      final d = SonosDiscovery.parseDeviceDescription(_deviceDescription, host: '192.168.1.10');
      expect(d.uuid, 'RINCON_AAA01400');
      expect(d.roomName, 'Wohnzimmer');
      expect(d.modelName, 'Sonos One');
      expect(d.host, '192.168.1.10');
      expect(d.port, 1400);
    });

    test('throws on invalid xml', () {
      expect(
        () => SonosDiscovery.parseDeviceDescription('<<', host: 'h'),
        throwsA(isA<SonosException>()),
      );
    });
  });

  group('parseSsdpResponse', () {
    const response = 'HTTP/1.1 200 OK\r\n'
        'CACHE-CONTROL: max-age = 1800\r\n'
        'EXT:\r\n'
        'location: http://192.168.1.10:1400/xml/device_description.xml\r\n'
        'SERVER: Linux UPnP/1.0 Sonos/79.1-54040 (ZPS12)\r\n'
        'ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n'
        'USN: uuid:RINCON_AAA01400::urn:schemas-upnp-org:device:ZonePlayer:1\r\n'
        'X-RINCON-HOUSEHOLD: Sonos_abc\r\n'
        '\r\n';

    test('parses location and uuid case-insensitively', () {
      final r = SonosDiscovery.parseSsdpResponse(response)!;
      expect(r.uuid, 'RINCON_AAA01400');
      expect(r.host, '192.168.1.10');
      expect(r.port, 1400);
      expect(r.location.path, '/xml/device_description.xml');
    });

    test('ignores non-Sonos responders', () {
      const other = 'HTTP/1.1 200 OK\r\n'
          'LOCATION: http://192.168.1.1:49152/desc.xml\r\n'
          'ST: upnp:rootdevice\r\n'
          'USN: uuid:12345::upnp:rootdevice\r\n\r\n';
      expect(SonosDiscovery.parseSsdpResponse(other), isNull);
      expect(SonosDiscovery.parseSsdpResponse(''), isNull);
      expect(SonosDiscovery.parseSsdpResponse('HTTP/1.1 200 OK\r\n\r\n'), isNull);
    });
  });

  group('soap', () {
    test('parseSoapResponse extracts args', () {
      const body = '<?xml version="1.0"?>'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
          '<s:Body><u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
          '<Track>1</Track><RelTime>0:01:02</RelTime><TrackDuration>1:00:00</TrackDuration>'
          '<TrackURI>http://x/y.mp3</TrackURI>'
          '</u:GetPositionInfoResponse></s:Body></s:Envelope>';
      final m = parseSoapResponse(body, action: 'GetPositionInfo');
      expect(m['RelTime'], '0:01:02');
      expect(m['TrackURI'], 'http://x/y.mp3');
    });

    test('parseSoapResponse throws SonosException with code on fault', () {
      const body = '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
          '<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>'
          '<detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
          '<errorCode>711</errorCode><errorDescription>Illegal seek target</errorDescription>'
          '</UPnPError></detail></s:Fault></s:Body></s:Envelope>';
      expect(
        () => parseSoapResponse(body, action: 'Seek', statusCode: 500),
        throwsA(isA<SonosException>().having((e) => e.upnpErrorCode, 'code', 711)),
      );
    });
  });
}
