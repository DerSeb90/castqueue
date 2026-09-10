import 'package:castqueue/playback/playback_target.dart';
import 'package:castqueue/sonos/sonos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  group('buildDidlLite', () {
    final item = PlayItem(
      id: 'ep 1/2',
      url: Uri.parse('https://pods.example.com/stream/abc?t=x&y=1'),
      title: 'Tom & Jerry <live>',
      artist: 'Show "Quotes"',
      artworkUrl: Uri.parse('https://img.example.com/a.jpg'),
      duration: const Duration(hours: 1, minutes: 2, seconds: 3),
      mimeType: 'audio/mp4',
    );

    test('produces well-formed XML with escaped values', () {
      final didl = buildDidlLite(item);
      final doc = XmlDocument.parse(didl);
      final itemEl = doc.findAllElements('item').single;
      expect(itemEl.getAttribute('id'), 'castqueue_ep_1_2');
      expect(doc.findAllElements('title', namespaceUri: '*').single.innerText, 'Tom & Jerry <live>');
      expect(doc.findAllElements('creator', namespaceUri: '*').single.innerText, 'Show "Quotes"');
      expect(doc.findAllElements('albumArtURI', namespaceUri: '*').single.innerText,
          'https://img.example.com/a.jpg');
      expect(doc.findAllElements('class', namespaceUri: '*').single.innerText,
          'object.item.audioItem.musicTrack');
      final res = doc.findAllElements('res').single;
      expect(res.getAttribute('protocolInfo'), 'http-get:*:audio/mp4:*');
      expect(res.getAttribute('duration'), '1:02:03');
      expect(res.innerText, 'https://pods.example.com/stream/abc?t=x&y=1');
      expect(didl, contains('&amp;'));
      expect(didl, contains('&lt;live&gt;'));
    });

    test('defaults mime to audio/mpeg and omits artwork when absent', () {
      final didl = buildDidlLite(PlayItem(
        id: 'x',
        url: Uri.parse('http://h/x.mp3'),
        title: 't',
        artist: 'a',
      ));
      expect(didl, contains('http-get:*:audio/mpeg:*'));
      expect(didl, isNot(contains('albumArtURI')));
      expect(didl, isNot(contains('duration=')));
    });

    test('survives SOAP embedding round trip', () {
      final didl = buildDidlLite(item);
      final env = buildSoapEnvelope(
        serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
        action: 'SetAVTransportURI',
        args: {'InstanceID': '0', 'CurrentURI': item.url.toString(), 'CurrentURIMetaData': didl},
      );
      final doc = XmlDocument.parse(env);
      final meta = doc.findAllElements('CurrentURIMetaData').single.innerText;
      expect(meta, didl);
    });
  });

  group('sonos time', () {
    test('formatSonosTime', () {
      expect(formatSonosTime(Duration.zero), '0:00:00');
      expect(formatSonosTime(const Duration(seconds: 59)), '0:00:59');
      expect(formatSonosTime(const Duration(minutes: 5, seconds: 7, milliseconds: 900)), '0:05:07');
      expect(formatSonosTime(const Duration(hours: 12, minutes: 34, seconds: 56)), '12:34:56');
      expect(formatSonosTime(const Duration(seconds: -5)), '0:00:00');
    });

    test('parseSonosTime', () {
      expect(parseSonosTime('0:00:00'), Duration.zero);
      expect(parseSonosTime('1:02:03'), const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(parseSonosTime('0:05:07.500'), const Duration(minutes: 5, seconds: 7, milliseconds: 500));
      expect(parseSonosTime('05:07'), const Duration(minutes: 5, seconds: 7));
      expect(parseSonosTime('NOT_IMPLEMENTED'), isNull);
      expect(parseSonosTime(''), isNull);
      expect(parseSonosTime(null), isNull);
      expect(parseSonosTime('abc'), isNull);
      expect(parseSonosTime('1:2:3:4'), isNull);
    });
  });
}
