import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

/// Downloads podcast artwork and turns it into a small baseline JPEG that
/// Rockbox can decode on an iPod (320×240 screen, slow CPU).
///
/// Any failure yields `null`; a missing cover must never fail a sync.
class CoverArt {
  CoverArt({http.Client? client, this.size = 200, this.quality = 85}) : _client = client ?? http.Client();

  final http.Client _client;
  final int size;
  final int quality;
  final Map<String, Uint8List?> _cache = {};

  Future<Uint8List?> fetch(String url) async {
    if (url.isEmpty) return null;
    if (_cache.containsKey(url)) return _cache[url];
    Uint8List? out;
    try {
      final res = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (res.statusCode >= 200 && res.statusCode < 300) out = convert(res.bodyBytes);
    } catch (_) {
      out = null;
    }
    _cache[url] = out;
    return out;
  }

  /// Decode → square center crop → resize → baseline JPEG. Pure, testable.
  Uint8List? convert(Uint8List bytes) {
    try {
      var im = img.decodeImage(bytes);
      if (im == null) return null;
      final side = im.width < im.height ? im.width : im.height;
      if (im.width != im.height) {
        im = img.copyCrop(im, x: (im.width - side) ~/ 2, y: (im.height - side) ~/ 2, width: side, height: side);
      }
      if (im.width != size) {
        im = img.copyResize(im, width: size, height: size, interpolation: img.Interpolation.average);
      }
      // Strip alpha: JPEG has none and the encoder would otherwise ignore it.
      if (im.hasAlpha) im = im.convert(numChannels: 3);
      return Uint8List.fromList(img.encodeJpg(im, quality: quality));
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}
