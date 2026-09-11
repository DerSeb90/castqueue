import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Minimal ID3v2.3 writer: enough for Rockbox to show title/artist/album and
/// embedded cover art. No unsynchronisation, no extended header.
///
/// Rockbox reads embedded APIC only as baseline JPEG; PNG or progressive JPEG
/// is ignored, so callers must pass JPEG bytes produced by [CoverArt].
class Id3Writer {
  Id3Writer._();

  static const _padding = 256;

  /// Builds a complete ID3v2.3 tag (header + frames + padding).
  static Uint8List buildTag({
    required String title,
    required String artist,
    required String album,
    String genre = 'Podcast',
    int? year,
    String comment = '',
    int? track,
    Uint8List? coverJpeg,
  }) {
    final frames = BytesBuilder(copy: false);
    void text(String id, String value) {
      if (value.isEmpty) return;
      frames.add(_frame(id, _textPayload(value)));
    }

    text('TIT2', title);
    text('TPE1', artist);
    text('TALB', album);
    text('TCON', genre);
    if (year != null && year > 0) text('TYER', year.toString());
    if (track != null && track > 0) text('TRCK', track.toString());
    if (comment.isNotEmpty) frames.add(_frame('COMM', _commentPayload(comment)));
    if (coverJpeg != null && coverJpeg.isNotEmpty) frames.add(_frame('APIC', _apicPayload(coverJpeg)));

    final body = frames.takeBytes();
    final size = body.length + _padding;
    final out = BytesBuilder(copy: false);
    out.add([0x49, 0x44, 0x33, 0x03, 0x00, 0x00]); // "ID3", v2.3.0, flags 0
    out.add(synchsafe(size));
    out.add(body);
    out.add(Uint8List(_padding));
    return out.takeBytes();
  }

  /// 28-bit synchsafe integer, big endian.
  static Uint8List synchsafe(int n) => Uint8List.fromList([
        (n >> 21) & 0x7F,
        (n >> 14) & 0x7F,
        (n >> 7) & 0x7F,
        n & 0x7F,
      ]);

  static int unsynchsafe(List<int> b, [int offset = 0]) =>
      ((b[offset] & 0x7F) << 21) | ((b[offset + 1] & 0x7F) << 14) | ((b[offset + 2] & 0x7F) << 7) | (b[offset + 3] & 0x7F);

  /// Length of an ID3v2 tag at the start of [head] (at least 10 bytes), or 0.
  /// Includes the 10-byte footer when the footer flag (v2.4) is set.
  static int existingTagLength(List<int> head) {
    if (head.length < 10) return 0;
    if (head[0] != 0x49 || head[1] != 0x44 || head[2] != 0x33) return 0;
    if (head[3] == 0xFF || head[4] == 0xFF) return 0;
    for (var i = 6; i < 10; i++) {
      if (head[i] & 0x80 != 0) return 0;
    }
    final flags = head[5];
    final size = unsynchsafe(head, 6);
    final footer = (flags & 0x10) != 0 ? 10 : 0;
    return 10 + size + footer;
  }

  /// Copies [src] to [dst], replacing any leading ID3v2 tag with [tag].
  static Future<void> writeTaggedCopy(File src, File dst, Uint8List tag) async {
    final raf = await src.open();
    int skip;
    try {
      final head = await raf.read(10);
      skip = existingTagLength(head);
      final len = await raf.length();
      if (skip > len) skip = 0;
    } finally {
      await raf.close();
    }
    final sink = dst.openWrite();
    try {
      sink.add(tag);
      await sink.addStream(src.openRead(skip));
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  // ---- frames ----

  static Uint8List _frame(String id, List<int> payload) {
    final b = BytesBuilder(copy: false);
    b.add(ascii.encode(id));
    b.add(_be32(payload.length));
    b.add([0, 0]);
    b.add(payload);
    return b.takeBytes();
  }

  static Uint8List _be32(int n) => Uint8List.fromList([(n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF]);

  static bool _isLatin1(String s) => s.codeUnits.every((c) => c <= 0xFF);

  /// Encoding byte + string. ISO-8859-1 when possible, else UTF-16 with BOM.
  static List<int> _textPayload(String s) {
    if (_isLatin1(s)) return [0x00, ...latin1.encode(s)];
    return [0x01, ..._utf16le(s)];
  }

  static List<int> _utf16le(String s) {
    final units = s.codeUnits;
    final out = Uint8List(2 + units.length * 2);
    out[0] = 0xFF;
    out[1] = 0xFE;
    for (var i = 0; i < units.length; i++) {
      out[2 + i * 2] = units[i] & 0xFF;
      out[3 + i * 2] = (units[i] >> 8) & 0xFF;
    }
    return out;
  }

  static List<int> _commentPayload(String comment) {
    final lang = ascii.encode('deu');
    if (_isLatin1(comment)) {
      return [0x00, ...lang, 0x00, ...latin1.encode(comment)];
    }
    // UTF-16: empty description = BOM + terminator, then BOM + text.
    return [0x01, ...lang, 0xFF, 0xFE, 0x00, 0x00, ..._utf16le(comment)];
  }

  static List<int> _apicPayload(Uint8List jpeg) => [
        0x00, // ISO-8859-1 for mime/description
        ...ascii.encode('image/jpeg'), 0x00,
        0x03, // picture type: front cover
        0x00, // empty description
        ...jpeg,
      ];
}
