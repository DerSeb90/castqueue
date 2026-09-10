import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// Everything the app needs to render offline / instantly at startup.
class LibrarySnapshot {
  const LibrarySnapshot({
    this.podcasts = const [],
    this.episodes = const [],
    this.queue = const QueueIds(version: 0, episodeIds: []),
    this.settings = const Settings(),
    this.lastSync,
    this.pendingProgress = const [],
  });

  final List<Podcast> podcasts;
  final List<Episode> episodes;
  final QueueIds queue;
  final Settings settings;
  final DateTime? lastSync;
  final List<ProgressUpdate> pendingProgress;

  Map<String, dynamic> toJson() => {
        'podcasts': [for (final p in podcasts) p.toJson()],
        'episodes': [for (final e in episodes) e.toJson()],
        'queue': queue.toJson(),
        'settings': settings.toJson(),
        'last_sync': lastSync?.toUtc().toIso8601String(),
        'pending_progress': [for (final u in pendingProgress) u.toJson(withId: true)],
      };

  factory LibrarySnapshot.fromJson(Map<String, dynamic> j) => LibrarySnapshot(
        podcasts: [
          for (final p in (j['podcasts'] as List? ?? const [])) Podcast.fromJson(p as Map<String, dynamic>)
        ],
        episodes: [
          for (final e in (j['episodes'] as List? ?? const [])) Episode.fromJson(e as Map<String, dynamic>)
        ],
        queue: QueueIds.fromJson((j['queue'] as Map<String, dynamic>?) ?? const {}),
        settings: Settings.fromJson((j['settings'] as Map<String, dynamic>?) ?? const {}),
        lastSync: j['last_sync'] is String ? DateTime.tryParse(j['last_sync'] as String)?.toUtc() : null,
        pendingProgress: [
          for (final u in (j['pending_progress'] as List? ?? const []))
            ProgressUpdate.fromJson(u as Map<String, dynamic>)
        ],
      );
}

/// JSON cache in the app support directory. Writes are debounced.
class LocalStore {
  LocalStore._(this._dir);

  final Directory _dir;
  Timer? _debounce;
  Map<String, dynamic>? _pendingWrite;
  Future<void> _writing = Future.value();

  static Future<LocalStore> open() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}castqueue');
    if (!await dir.exists()) await dir.create(recursive: true);
    return LocalStore._(dir);
  }

  Directory get directory => _dir;
  File get _cacheFile => File('${_dir.path}${Platform.pathSeparator}library.json');

  Future<LibrarySnapshot?> loadLibrary() async {
    try {
      if (!await _cacheFile.exists()) return null;
      final j = jsonDecode(await _cacheFile.readAsString()) as Map<String, dynamic>;
      return LibrarySnapshot.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  void saveLibrary(LibrarySnapshot snapshot) {
    _pendingWrite = snapshot.toJson();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), flush);
  }

  /// Write immediately (app pause / shutdown).
  Future<void> flush() async {
    _debounce?.cancel();
    final data = _pendingWrite;
    if (data == null) return;
    _pendingWrite = null;
    _writing = _writing.then((_) async {
      final tmp = File('${_cacheFile.path}.tmp');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      try {
        await tmp.rename(_cacheFile.path);
      } on FileSystemException {
        // Windows may refuse to rename over an existing file; fall back to copy.
        await tmp.copy(_cacheFile.path);
        await tmp.delete();
      }
    });
    await _writing;
  }

  Future<void> clear() async {
    _debounce?.cancel();
    _pendingWrite = null;
    try {
      if (await _cacheFile.exists()) await _cacheFile.delete();
    } catch (_) {}
  }
}
