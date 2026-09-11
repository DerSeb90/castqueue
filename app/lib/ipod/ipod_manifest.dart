import 'dart:convert';
import 'dart:io';

/// One episode that lives on the player.
class ManifestEntry {
  const ManifestEntry({
    required this.episodeId,
    required this.path,
    required this.podcastId,
    required this.size,
    required this.durationMs,
    required this.addedAt,
  });

  final String episodeId;

  /// Rockbox-style absolute path with forward slashes: `/Podcasts/<p>/<f>`.
  final String path;
  final String podcastId;
  final int size;
  final int durationMs;
  final DateTime addedAt;

  Map<String, dynamic> toJson() => {
        'path': path,
        'podcast_id': podcastId,
        'size': size,
        'duration_ms': durationMs,
        'added_at': addedAt.toUtc().toIso8601String(),
      };

  static ManifestEntry? fromJson(String id, Object? j) {
    if (j is! Map) return null;
    final path = j['path'];
    if (path is! String || path.isEmpty) return null;
    return ManifestEntry(
      episodeId: id,
      path: path,
      podcastId: (j['podcast_id'] as String?) ?? '',
      size: (j['size'] as num?)?.toInt() ?? 0,
      durationMs: (j['duration_ms'] as num?)?.toInt() ?? 0,
      addedAt: DateTime.tryParse((j['added_at'] as String?) ?? '')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// `<root>/Podcasts/.castqueue.json` — what CastQueue put on the player.
///
/// Tolerant: a missing or corrupt file is an empty manifest, and entries whose
/// file vanished (deleted on the device) are dropped on load.
class IpodManifest {
  IpodManifest(this.file, [Map<String, ManifestEntry>? entries]) : entries = entries ?? {};

  static const version = 1;
  final File file;
  final Map<String, ManifestEntry> entries;

  static File fileFor(String root) =>
      File('$root${Platform.pathSeparator}Podcasts${Platform.pathSeparator}.castqueue.json');

  /// Loads and reconciles against the filesystem. [resolve] maps a manifest
  /// path to an absolute local path.
  static Future<IpodManifest> load(File file, String Function(String rockboxPath) resolve) async {
    final m = IpodManifest(file);
    Map<String, dynamic> j;
    try {
      if (!await file.exists()) return m;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return m;
      j = decoded;
    } catch (_) {
      return m;
    }
    final raw = j['entries'];
    if (raw is! Map) return m;
    for (final e in raw.entries) {
      final entry = ManifestEntry.fromJson(e.key.toString(), e.value);
      if (entry == null) continue;
      if (await File(resolve(entry.path)).exists()) m.entries[entry.episodeId] = entry;
    }
    return m;
  }

  static IpodManifest parse(File file, String json) {
    final m = IpodManifest(file);
    try {
      final decoded = jsonDecode(json);
      final raw = decoded is Map ? decoded['entries'] : null;
      if (raw is Map) {
        for (final e in raw.entries) {
          final entry = ManifestEntry.fromJson(e.key.toString(), e.value);
          if (entry != null) m.entries[entry.episodeId] = entry;
        }
      }
    } catch (_) {}
    return m;
  }

  String encode() => const JsonEncoder.withIndent('  ').convert({
        'version': version,
        'entries': {for (final e in entries.values) e.episodeId: e.toJson()},
      });

  /// Atomic-ish save: write temp then rename.
  Future<void> save() async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(encode(), flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
  }
}
