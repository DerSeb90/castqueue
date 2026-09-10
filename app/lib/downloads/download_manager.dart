import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../state/app_state.dart';
import '../state/library.dart';

/// Whether downloads are available on this platform (Android only; Windows streams).
bool get downloadsSupported => Platform.isAndroid;

class DownloadEntry {
  const DownloadEntry({required this.episodeId, required this.path, required this.size, required this.completedAt});
  final String episodeId;
  final String path;
  final int size;
  final DateTime completedAt;

  Map<String, dynamic> toJson() => {
        'episode_id': episodeId,
        'path': path,
        'size': size,
        'completed_at': completedAt.toUtc().toIso8601String(),
      };

  factory DownloadEntry.fromJson(Map<String, dynamic> j) => DownloadEntry(
        episodeId: j['episode_id'] as String,
        path: j['path'] as String,
        size: (j['size'] as num?)?.toInt() ?? 0,
        completedAt: DateTime.tryParse(j['completed_at'] as String? ?? '') ?? DateTime.now(),
      );
}

class DownloadsState {
  const DownloadsState({this.entries = const {}, this.active = const {}, this.errors = const {}});

  /// Completed downloads by episode id.
  final Map<String, DownloadEntry> entries;

  /// In-flight downloads: episode id → 0..1 progress (or -1 when size unknown).
  final Map<String, double> active;
  final Map<String, String> errors;

  bool has(String episodeId) => entries.containsKey(episodeId);
  bool isActive(String episodeId) => active.containsKey(episodeId);

  DownloadsState copyWith({
    Map<String, DownloadEntry>? entries,
    Map<String, double>? active,
    Map<String, String>? errors,
  }) =>
      DownloadsState(entries: entries ?? this.entries, active: active ?? this.active, errors: errors ?? this.errors);
}

class DownloadManager extends Notifier<DownloadsState> {
  Directory? _dir;
  final Map<String, http.Client> _clients = {};
  Future<void>? _init;

  @override
  DownloadsState build() {
    if (downloadsSupported) _init = _load();
    return const DownloadsState();
  }

  Future<void> _ensureInit() async => await (_init ??= _load());

  File get _indexFile => File('${_dir!.path}${Platform.pathSeparator}downloads.json');

  Future<void> _load() async {
    final base = await getApplicationDocumentsDirectory();
    _dir = Directory('${base.path}${Platform.pathSeparator}castqueue_downloads');
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    try {
      if (await _indexFile.exists()) {
        final j = jsonDecode(await _indexFile.readAsString()) as Map<String, dynamic>;
        final entries = <String, DownloadEntry>{};
        for (final e in (j['entries'] as List? ?? const [])) {
          final entry = DownloadEntry.fromJson(e as Map<String, dynamic>);
          if (await File(entry.path).exists()) entries[entry.episodeId] = entry;
        }
        state = state.copyWith(entries: entries);
      }
    } catch (_) {}
  }

  Future<void> _saveIndex() async {
    if (_dir == null) return;
    await _indexFile.writeAsString(jsonEncode({
      'entries': [for (final e in state.entries.values) e.toJson()],
    }));
  }

  /// Local file for a downloaded episode, or null.
  File? fileFor(String episodeId) {
    final e = state.entries[episodeId];
    return e == null ? null : File(e.path);
  }

  Future<void> download(Episode ep) async {
    if (!downloadsSupported) return;
    await _ensureInit();
    if (state.has(ep.id) || state.isActive(ep.id) || ep.streamUrl.isEmpty) return;
    state = state.copyWith(
      active: {...state.active, ep.id: 0},
      errors: {...state.errors}..remove(ep.id),
    );
    final client = http.Client();
    _clients[ep.id] = client;
    final ext = _extensionFor(ep);
    final target = File('${_dir!.path}${Platform.pathSeparator}${ep.id}$ext');
    final tmp = File('${target.path}.part');
    try {
      final res = await client.send(http.Request('GET', Uri.parse(ep.streamUrl)));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      final total = res.contentLength ?? ep.mediaSize;
      var received = 0;
      var lastEmit = 0;
      final sink = tmp.openWrite();
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (received - lastEmit > 256 * 1024) {
            lastEmit = received;
            state = state.copyWith(active: {...state.active, ep.id: total > 0 ? received / total : -1});
          }
        }
      } finally {
        await sink.close();
      }
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
      final entry = DownloadEntry(episodeId: ep.id, path: target.path, size: received, completedAt: DateTime.now());
      state = state.copyWith(
        entries: {...state.entries, ep.id: entry},
        active: {...state.active}..remove(ep.id),
      );
      await _saveIndex();
    } catch (e) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      state = state.copyWith(
        active: {...state.active}..remove(ep.id),
        errors: {...state.errors, ep.id: e.toString()},
      );
    } finally {
      _clients.remove(ep.id)?.close();
    }
  }

  void cancel(String episodeId) {
    _clients.remove(episodeId)?.close();
  }

  Future<void> delete(String episodeId) async {
    if (!downloadsSupported) return;
    await _ensureInit();
    final e = state.entries[episodeId];
    if (e == null) return;
    try {
      final f = File(e.path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    state = state.copyWith(entries: {...state.entries}..remove(episodeId));
    await _saveIndex();
  }

  /// Auto-download queue items / delete played or dequeued ones per prefs.
  Future<void> reconcile() async {
    if (!downloadsSupported) return;
    await _ensureInit();
    final prefs = ref.read(appPrefsProvider);
    final lib = ref.read(libraryProvider);
    final queueSet = lib.queueIds.toSet();
    if (prefs.autoDeleteDownloads) {
      for (final id in state.entries.keys.toList()) {
        final ep = lib.episodes[id];
        if (ep == null || ep.played || !queueSet.contains(id)) await delete(id);
      }
    }
    if (prefs.autoDownload) {
      for (final ep in lib.queue) {
        if (!ep.played && !state.has(ep.id) && !state.isActive(ep.id)) {
          unawaited(download(ep));
        }
      }
    }
  }

  static String _extensionFor(Episode ep) {
    final t = ep.mediaType.toLowerCase();
    if (t.contains('mp4') || t.contains('m4a') || t.contains('aac')) return '.m4a';
    if (t.contains('ogg') || t.contains('opus')) return '.ogg';
    if (t.contains('flac')) return '.flac';
    final path = Uri.tryParse(ep.mediaUrl)?.path ?? '';
    final dot = path.lastIndexOf('.');
    if (dot > 0 && path.length - dot <= 5) return path.substring(dot);
    return '.mp3';
  }
}

final downloadManagerProvider = NotifierProvider<DownloadManager, DownloadsState>(DownloadManager.new);
