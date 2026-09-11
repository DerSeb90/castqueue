import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../state/library.dart';
import 'cover_art.dart';
import 'id3_writer.dart';
import 'ipod_manifest.dart';
import 'ipod_selection.dart';
import 'rockbox_changelog.dart';
import 'rockbox_device.dart';

// ---------------------------------------------------------------- plan

enum PlanAction { copy, keep, delete }

class PlanItem {
  const PlanItem({
    required this.action,
    required this.episodeId,
    required this.title,
    required this.podcastTitle,
    required this.size,
    this.episode,
    this.entry,
    this.reason = '',
  });

  final PlanAction action;
  final String episodeId;
  final String title;
  final String podcastTitle;
  final int size;
  final Episode? episode;
  final ManifestEntry? entry;
  final String reason;
}

class IpodPlan {
  const IpodPlan({required this.copy, required this.keep, required this.delete, required this.order});

  final List<PlanItem> copy;
  final List<PlanItem> keep;
  final List<PlanItem> delete;

  /// Episode ids in playlist order (queue first, then per-podcast extras).
  final List<String> order;

  int get bytesToCopy => copy.fold(0, (a, b) => a + b.size);
  int get bytesToDelete => delete.fold(0, (a, b) => a + b.size);
  bool get isEmpty => copy.isEmpty && delete.isEmpty;
  static const empty = IpodPlan(copy: [], keep: [], delete: [], order: []);
}

/// Pure planning step. `desired` = unplayed queue (in order) ∪ per-podcast
/// newest N unplayed; compare with what the manifest says is on the device.
IpodPlan computePlan({
  required LibraryState lib,
  required IpodManifest manifest,
  required IpodSelection sel,
}) {
  final desired = <String, Episode>{};
  final order = <String>[];
  void want(Episode e) {
    if (e.played || (e.mediaUrl.isEmpty && e.streamUrl.isEmpty)) return;
    if (desired.containsKey(e.id)) return;
    desired[e.id] = e;
    order.add(e.id);
  }

  if (sel.includeQueue) {
    for (final e in lib.queue) {
      want(e);
    }
  }
  for (final entry in sel.perPodcastLatest.entries) {
    if (entry.value <= 0 || !lib.podcasts.containsKey(entry.key)) continue;
    var n = 0;
    for (final e in lib.episodesOf(entry.key)) {
      if (e.played) continue;
      want(e);
      if (++n >= entry.value) break;
    }
  }

  final copy = <PlanItem>[];
  final keep = <PlanItem>[];
  final delete = <PlanItem>[];

  for (final id in order) {
    final e = desired[id]!;
    if (manifest.entries.containsKey(id)) {
      keep.add(PlanItem(
        action: PlanAction.keep,
        episodeId: id,
        title: e.title,
        podcastTitle: e.podcastTitle,
        size: manifest.entries[id]!.size,
        episode: e,
        entry: manifest.entries[id],
      ));
    } else {
      copy.add(PlanItem(
        action: PlanAction.copy,
        episodeId: id,
        title: e.title,
        podcastTitle: e.podcastTitle,
        size: e.mediaSize,
        episode: e,
      ));
    }
  }

  for (final entry in manifest.entries.values) {
    if (desired.containsKey(entry.episodeId)) continue;
    final e = lib.episodes[entry.episodeId];
    String? reason;
    if (e == null) {
      reason = 'nicht mehr abonniert';
    } else if (e.played && sel.removePlayed) {
      reason = 'gehört';
    } else if (sel.removeUnselected) {
      reason = 'nicht mehr ausgewählt';
    }
    if (reason == null) {
      keep.add(PlanItem(
        action: PlanAction.keep,
        episodeId: entry.episodeId,
        title: e?.title ?? entry.path.split('/').last,
        podcastTitle: e?.podcastTitle ?? '',
        size: entry.size,
        episode: e,
        entry: entry,
        reason: 'bleibt (nicht ausgewählt)',
      ));
      continue;
    }
    delete.add(PlanItem(
      action: PlanAction.delete,
      episodeId: entry.episodeId,
      title: e?.title ?? entry.path.split('/').last,
      podcastTitle: e?.podcastTitle ?? '',
      size: entry.size,
      episode: e,
      entry: entry,
      reason: reason,
    ));
  }

  return IpodPlan(copy: copy, keep: keep, delete: delete, order: order);
}

// ------------------------------------------------------------ file names

final _invalid = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

/// FAT32-safe file/folder name component.
String sanitizeName(String s, {int max = 80}) {
  var t = s.replaceAll(_invalid, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  t = t.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  if (t.length > max) t = t.substring(0, max).trimRight().replaceAll(RegExp(r'[. ]+$'), '');
  return t.isEmpty ? 'Unbenannt' : t;
}

/// `.mp3`, `.m4a`, `.ogg`, `.opus`, `.flac` — from the media type, then URL.
String extensionFor(String mediaType, String mediaUrl) {
  final t = mediaType.toLowerCase();
  if (t.contains('mpeg') || t.contains('mp3')) return '.mp3';
  if (t.contains('mp4') || t.contains('m4a') || t.contains('aac')) return '.m4a';
  if (t.contains('opus')) return '.opus';
  if (t.contains('ogg') || t.contains('vorbis')) return '.ogg';
  if (t.contains('flac')) return '.flac';
  final path = (Uri.tryParse(mediaUrl)?.path ?? '').toLowerCase();
  for (final ext in const ['.mp3', '.m4a', '.opus', '.ogg', '.flac']) {
    if (path.endsWith(ext)) return ext;
  }
  return '.mp3';
}

final _dayFmt = DateFormat('yyyy-MM-dd');

/// Rockbox path (`/Podcasts/<Podcast>/<date> - <title>.<ext>`).
String targetPathFor(Episode e) {
  final folder = sanitizeName(e.podcastTitle.isEmpty ? 'Podcast' : e.podcastTitle, max: 60);
  final date = e.publishedAt == null ? '0000-00-00' : _dayFmt.format(e.publishedAt!.toLocal());
  final title = sanitizeName(e.title.isEmpty ? e.id : e.title);
  return '/Podcasts/$folder/$date - $title${extensionFor(e.mediaType, e.mediaUrl)}';
}

/// Extended M3U with Rockbox-absolute paths. Entries in [order] that are not
/// in [entries] are skipped.
String buildM3u8({
  required List<String> order,
  required Map<String, ManifestEntry> entries,
  required Map<String, Episode> episodes,
}) {
  final b = StringBuffer('#EXTM3U\n');
  for (final id in order) {
    final entry = entries[id];
    if (entry == null) continue;
    final e = episodes[id];
    final secs = ((e?.durationMs ?? entry.durationMs) / 1000).round();
    final label = e == null ? entry.path.split('/').last : '${e.podcastTitle} - ${e.title}';
    b.write('#EXTINF:$secs,${label.replaceAll('\n', ' ')}\n');
    b.write('${entry.path}\n');
  }
  return b.toString();
}

// ------------------------------------------------------------ controller

enum IpodPhase { idle, planning, ready, syncing, done, error }

class IpodSyncState {
  const IpodSyncState({
    this.phase = IpodPhase.idle,
    this.device,
    this.plan = IpodPlan.empty,
    this.current = '',
    this.progress = 0,
    this.fileProgress = 0,
    this.log = const [],
    this.error,
  });

  final IpodPhase phase;
  final RockboxDevice? device;
  final IpodPlan plan;
  final String current;

  /// 0..1 over all planned work.
  final double progress;

  /// 0..1 within the current file (-1 unknown).
  final double fileProgress;
  final List<String> log;
  final String? error;

  bool get busy => phase == IpodPhase.planning || phase == IpodPhase.syncing;

  IpodSyncState copyWith({
    IpodPhase? phase,
    RockboxDevice? device,
    bool clearDevice = false,
    IpodPlan? plan,
    String? current,
    double? progress,
    double? fileProgress,
    List<String>? log,
    String? error,
    bool clearError = false,
  }) =>
      IpodSyncState(
        phase: phase ?? this.phase,
        device: clearDevice ? null : (device ?? this.device),
        plan: plan ?? this.plan,
        current: current ?? this.current,
        progress: progress ?? this.progress,
        fileProgress: fileProgress ?? this.fileProgress,
        log: log ?? this.log,
        error: clearError ? null : (error ?? this.error),
      );
}

class IpodSyncController extends Notifier<IpodSyncState> {
  bool _cancel = false;
  http.Client? _client;

  @override
  IpodSyncState build() => const IpodSyncState();

  void selectDevice(RockboxDevice? d) {
    state = state.copyWith(device: d, clearDevice: d == null, plan: IpodPlan.empty, phase: IpodPhase.idle, clearError: true);
  }

  void _log(String s) => state = state.copyWith(log: [...state.log.take(199), s].toList());

  Future<void> makePlan() async {
    final dev = state.device;
    if (dev == null) return;
    state = state.copyWith(phase: IpodPhase.planning, clearError: true, log: const []);
    try {
      final manifest = await IpodManifest.load(IpodManifest.fileFor(dev.root), dev.resolve);
      final plan = computePlan(
        lib: ref.read(libraryProvider),
        manifest: manifest,
        sel: ref.read(ipodSelectionProvider),
      );
      state = state.copyWith(phase: IpodPhase.ready, plan: plan, progress: 0, current: '');
    } catch (e) {
      state = state.copyWith(phase: IpodPhase.error, error: 'Plan fehlgeschlagen: $e');
    }
  }

  void cancel() {
    _cancel = true;
    _client?.close();
  }

  Future<void> run() async {
    final dev = state.device;
    final plan = state.plan;
    if (dev == null || state.busy) return;
    _cancel = false;
    final sel = ref.read(ipodSelectionProvider);
    final lib = ref.read(libraryProvider);
    final total = plan.copy.length + plan.delete.length + (sel.writePlaylist ? 1 : 0);
    var done = 0;
    state = state.copyWith(phase: IpodPhase.syncing, progress: 0, clearError: true, log: const []);
    final covers = CoverArt();
    final manifest = await IpodManifest.load(IpodManifest.fileFor(dev.root), dev.resolve);
    try {
      // Deletes first: frees space for the copies.
      for (final item in plan.delete) {
        if (_cancel) throw const _Cancelled();
        state = state.copyWith(current: 'Lösche ${item.title}', fileProgress: -1);
        await _deleteEntry(dev, manifest, item.entry!);
        _log('Gelöscht: ${item.title} (${item.reason})');
        state = state.copyWith(progress: ++done / total);
      }
      final coveredFolders = <String>{};
      for (final item in plan.copy) {
        if (_cancel) throw const _Cancelled();
        final e = item.episode!;
        state = state.copyWith(current: 'Kopiere ${e.podcastTitle} – ${e.title}', fileProgress: 0);
        try {
          await _copyEpisode(dev, manifest, e, sel, covers, coveredFolders);
          _log('Kopiert: ${e.title}');
        } on _Cancelled {
          rethrow;
        } catch (err) {
          _log('Fehler bei „${e.title}“: $err');
        }
        state = state.copyWith(progress: ++done / total);
      }
      if (sel.writePlaylist) {
        state = state.copyWith(current: 'Schreibe Playlist', fileProgress: -1);
        final order = [...plan.order, ...manifest.entries.keys.where((id) => !plan.order.contains(id))];
        final m3u = buildM3u8(order: order, entries: manifest.entries, episodes: lib.episodes);
        await dev.playlistsDir.create(recursive: true);
        await File('${dev.playlistsDir.path}${Platform.pathSeparator}CastQueue.m3u8').writeAsString(m3u, flush: true);
        _log('Playlist geschrieben (${manifest.entries.length} Folgen)');
        state = state.copyWith(progress: ++done / total);
      }
      state = state.copyWith(phase: IpodPhase.done, current: 'Fertig', progress: 1);
    } on _Cancelled {
      _log('Abgebrochen.');
      state = state.copyWith(phase: IpodPhase.ready, current: 'Abgebrochen');
    } catch (e) {
      state = state.copyWith(phase: IpodPhase.error, error: e.toString());
    } finally {
      covers.close();
      _client = null;
    }
  }

  Future<void> _deleteEntry(RockboxDevice dev, IpodManifest manifest, ManifestEntry entry) async {
    final f = File(dev.resolve(entry.path));
    try {
      if (await f.exists()) await f.delete();
      final dir = f.parent;
      if (await dir.exists()) {
        final left = await dir.list().where((x) => !x.path.endsWith('cover.jpg')).isEmpty;
        if (left) await dir.delete(recursive: true);
      }
    } catch (e) {
      _log('Löschen fehlgeschlagen: ${entry.path} ($e)');
    }
    manifest.entries.remove(entry.episodeId);
    await manifest.save();
  }

  Future<void> _copyEpisode(
    RockboxDevice dev,
    IpodManifest manifest,
    Episode e,
    IpodSelection sel,
    CoverArt covers,
    Set<String> coveredFolders,
  ) async {
    final url = e.streamUrl.isNotEmpty ? e.streamUrl : e.mediaUrl;
    if (url.isEmpty) throw StateError('keine Medien-URL');
    final rbPath = targetPathFor(e);
    final target = File(dev.resolve(rbPath));
    await target.parent.create(recursive: true);

    final tmpDir = await getTemporaryDirectory();
    final tmp = File('${tmpDir.path}${Platform.pathSeparator}castqueue-ipod-${e.id}.part');
    final client = _client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url)));
      if (res.statusCode < 200 || res.statusCode >= 300) throw HttpException('HTTP ${res.statusCode}');
      final totalBytes = res.contentLength ?? e.mediaSize;
      var received = 0;
      var lastEmit = 0;
      final sink = tmp.openWrite();
      try {
        await for (final chunk in res.stream) {
          if (_cancel) throw const _Cancelled();
          sink.add(chunk);
          received += chunk.length;
          if (received - lastEmit > 512 * 1024) {
            lastEmit = received;
            state = state.copyWith(fileProgress: totalBytes > 0 ? (received / totalBytes).clamp(0, 1) : -1);
          }
        }
      } finally {
        await sink.close();
      }
      if (_cancel) throw const _Cancelled();

      Uint8List? cover;
      if (sel.embedCover || sel.folderCover) cover = await covers.fetch(e.artworkUrl);

      final ext = extensionFor(e.mediaType, e.mediaUrl);
      if (ext == '.mp3') {
        final tag = Id3Writer.buildTag(
          title: e.title,
          artist: e.podcastTitle,
          album: e.podcastTitle,
          year: e.publishedAt?.toLocal().year,
          comment: e.link,
          track: e.episodeNumber > 0 ? e.episodeNumber : null,
          coverJpeg: sel.embedCover ? cover : null,
        );
        await Id3Writer.writeTaggedCopy(tmp, target, tag);
      } else {
        await tmp.copy(target.path);
      }

      if (sel.folderCover && cover != null && coveredFolders.add(target.parent.path)) {
        final coverFile = File('${target.parent.path}${Platform.pathSeparator}cover.jpg');
        if (!await coverFile.exists()) await coverFile.writeAsBytes(cover, flush: true);
      }

      manifest.entries[e.id] = ManifestEntry(
        episodeId: e.id,
        path: rbPath,
        podcastId: e.podcastId,
        size: await target.length(),
        durationMs: e.durationMs,
        addedAt: DateTime.now().toUtc(),
      );
      await manifest.save();
    } finally {
      client.close();
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  // -------------------------------------------------------- read-back

  /// Reads `database_changelog.txt` and pushes newer positions / played flags
  /// to the server. Returns a human-readable summary.
  Future<String> importChangelog() async {
    final dev = state.device;
    if (dev == null) return 'Kein Gerät ausgewählt.';
    final f = dev.changelogFile;
    if (!await f.exists()) {
      return 'Keine database_changelog.txt gefunden. Auf dem iPod: Database → Export modifications.';
    }
    final tracks = RockboxChangelog.parse(await f.readAsString());
    final manifest = await IpodManifest.load(IpodManifest.fileFor(dev.root), dev.resolve);
    final byPath = {for (final e in manifest.entries.values) RockboxChangelog.normalize(e.path): e};
    final lib = ref.read(libraryProvider);
    final notifier = ref.read(libraryProvider.notifier);
    final stamp = (await f.lastModified()).toUtc();
    var updated = 0;
    var matched = 0;
    for (final t in tracks) {
      final entry = byPath[RockboxChangelog.normalize(t.filename)];
      if (entry == null) continue;
      final e = lib.episodes[entry.episodeId];
      if (e == null) continue;
      matched++;
      final duration = e.durationMs > 0 ? e.durationMs : entry.durationMs;
      final played = t.isPlayed(duration);
      final pos = played ? (duration > 0 ? duration : e.positionMs) : t.lastelapsed;
      final newer = (played && !e.played) || (!e.played && pos > e.positionMs);
      if (!newer) continue;
      await notifier.reportProgress(ProgressUpdate(
        episodeId: e.id,
        positionMs: pos,
        durationMs: duration > 0 ? duration : null,
        played: played ? true : null,
        updatedAt: stamp,
      ));
      updated++;
    }
    return '${tracks.length} Einträge, $matched zu CastQueue-Folgen, $updated aktualisiert.';
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

final ipodSyncProvider = NotifierProvider<IpodSyncController, IpodSyncState>(IpodSyncController.new);
