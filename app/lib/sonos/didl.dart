import '../playback/playback_target.dart';
import 'soap.dart';

/// Builds DIDL-Lite metadata for [item] (raw XML — NOT yet escaped for SOAP).
String buildDidlLite(PlayItem item) {
  final mime = (item.mimeType == null || item.mimeType!.isEmpty) ? 'audio/mpeg' : item.mimeType!;
  final b = StringBuffer()
    ..write('<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" ')
    ..write('xmlns:dc="http://purl.org/dc/elements/1.1/" ')
    ..write('xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" ')
    ..write('xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/">')
    ..write('<item id="${xmlEscape(_itemId(item.id))}" parentID="-1" restricted="true">')
    ..write('<dc:title>${xmlEscape(item.title)}</dc:title>')
    ..write('<dc:creator>${xmlEscape(item.artist)}</dc:creator>')
    ..write('<upnp:artist>${xmlEscape(item.artist)}</upnp:artist>')
    ..write('<upnp:album>${xmlEscape(item.artist)}</upnp:album>')
    ..write('<upnp:class>object.item.audioItem.musicTrack</upnp:class>');
  if (item.artworkUrl != null) {
    b.write('<upnp:albumArtURI>${xmlEscape(item.artworkUrl.toString())}</upnp:albumArtURI>');
  }
  b.write('<res protocolInfo="http-get:*:${xmlEscape(mime)}:*"');
  if (item.duration != null) {
    b.write(' duration="${formatSonosTime(item.duration!)}"');
  }
  b
    ..write('>${xmlEscape(item.url.toString())}</res>')
    ..write('</item></DIDL-Lite>');
  return b.toString();
}

String _itemId(String id) {
  // Only safe characters; Sonos is picky about item ids.
  final clean = id.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '_');
  return 'castqueue_$clean';
}

/// `H:MM:SS` (Sonos REL_TIME). Fractions are dropped.
String formatSonosTime(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return '$h:${two(m)}:${two(s)}';
}

/// Parses `H:MM:SS`, `H:MM:SS.mmm`, `MM:SS`; returns `null` for
/// `NOT_IMPLEMENTED`, empty, or malformed values.
Duration? parseSonosTime(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.isEmpty || t == 'NOT_IMPLEMENTED') return null;
  final parts = t.split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  try {
    var h = 0;
    var m = 0;
    String secStr;
    if (parts.length == 3) {
      h = int.parse(parts[0]);
      m = int.parse(parts[1]);
      secStr = parts[2];
    } else {
      m = int.parse(parts[0]);
      secStr = parts[1];
    }
    final sec = double.parse(secStr);
    if (h < 0 || m < 0 || sec < 0) return null;
    return Duration(hours: h, minutes: m, milliseconds: (sec * 1000).round());
  } on FormatException {
    return null;
  }
}
