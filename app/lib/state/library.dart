import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/local_store.dart';
import '../core/models.dart';
import 'app_state.dart';

class LibraryState {
  const LibraryState({
    this.podcasts = const {},
    this.episodes = const {},
    this.queueIds = const [],
    this.queueVersion = 0,
    this.settings = const Settings(),
    this.lastSync,
    this.pendingProgress = const {},
    this.syncing = false,
    this.refreshing = false,
    this.lastError,
    this.initialSyncDone = false,
    this.playback,
  });

  final Map<String, Podcast> podcasts;
  final Map<String, Episode> episodes;
  final List<String> queueIds;
  final int queueVersion;
  final Settings settings;
  final DateTime? lastSync;
  final Map<String, ProgressUpdate> pendingProgress;
  final bool syncing;
  final bool refreshing;
  final String? lastError;
  final bool initialSyncDone;

  /// Server-side playback lock as of the last sync.
  final PlaybackLock? playback;

  List<Episode> get queue => [for (final id in queueIds) if (episodes[id] != null) episodes[id]!];

  List<Podcast> get sortedPodcasts {
    final l = podcasts.values.toList();
    l.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return l;
  }

  List<Episode> episodesOf(String podcastId) {
    final l = episodes.values.where((e) => e.podcastId == podcastId).toList();
    l.sort(_newestFirst);
    return l;
  }

  /// Episodes published in the last [days] days, newest first.
  List<Episode> recent({int days = 14}) {
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: days));
    final l = episodes.values.where((e) => e.publishedAt != null && e.publishedAt!.isAfter(cutoff)).toList();
    l.sort(_newestFirst);
    return l;
  }

  static int _newestFirst(Episode a, Episode b) {
    final pa = a.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final pb = b.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return pb.compareTo(pa);
  }

  LibraryState copyWith({
    Map<String, Podcast>? podcasts,
    Map<String, Episode>? episodes,
    List<String>? queueIds,
    int? queueVersion,
    Settings? settings,
    DateTime? lastSync,
    Map<String, ProgressUpdate>? pendingProgress,
    bool? syncing,
    bool? refreshing,
    String? lastError,
    bool clearError = false,
    bool? initialSyncDone,
    PlaybackLock? playback,
  }) =>
      LibraryState(
        playback: playback ?? this.playback,
        podcasts: podcasts ?? this.podcasts,
        episodes: episodes ?? this.episodes,
        queueIds: queueIds ?? this.queueIds,
        queueVersion: queueVersion ?? this.queueVersion,
        settings: settings ?? this.settings,
        lastSync: lastSync ?? this.lastSync,
        pendingProgress: pendingProgress ?? this.pendingProgress,
        syncing: syncing ?? this.syncing,
        refreshing: refreshing ?? this.refreshing,
        lastError: clearError ? null : (lastError ?? this.lastError),
        initialSyncDone: initialSyncDone ?? this.initialSyncDone,
      );

  LibrarySnapshot toSnapshot() => LibrarySnapshot(
        podcasts: podcasts.values.toList(),
        episodes: episodes.values.toList(),
        queue: QueueIds(version: queueVersion, episodeIds: queueIds),
        settings: settings,
        lastSync: lastSync,
        pendingProgress: pendingProgress.values.toList(),
      );

  static LibraryState fromSnapshot(LibrarySnapshot s) => LibraryState(
        podcasts: {for (final p in s.podcasts) p.id: p},
        episodes: {for (final e in s.episodes) e.id: e},
        queueIds: s.queue.episodeIds,
        queueVersion: s.queue.version,
        settings: s.settings,
        lastSync: s.lastSync,
        pendingProgress: {for (final u in s.pendingProgress) u.episodeId: u},
        initialSyncDone: s.lastSync != null,
      );
}

/// Server-backed library. Every mutation goes to the API first (the server is
/// the source of truth) and the returned state is merged locally.
class LibraryNotifier extends Notifier<LibraryState> {
  @override
  LibraryState build() {
    final snap = ref.watch(initialSnapshotProvider);
    // Reset when the session changes (logout/login).
    ref.watch(sessionProvider);
    return snap == null ? const LibraryState() : LibraryState.fromSnapshot(snap);
  }

  ApiClient get _api {
    final c = ref.read(apiClientProvider);
    if (c == null) throw UnauthorizedException();
    return c;
  }

  void _persist() => ref.read(localStoreProvider).saveLibrary(state.toSnapshot());

  void setError(String? msg) => state = state.copyWith(lastError: msg, clearError: msg == null);

  // ------------------------------------------------------------------ sync

  void applySync(SyncResponse r, {required bool full}) {
    final podcasts = full ? <String, Podcast>{} : Map<String, Podcast>.of(state.podcasts);
    final episodes = full ? <String, Episode>{} : Map<String, Episode>.of(state.episodes);
    for (final p in r.podcasts) {
      podcasts[p.id] = p;
    }
    for (final id in r.podcastsDeleted) {
      podcasts.remove(id);
      episodes.removeWhere((_, e) => e.podcastId == id);
    }
    for (final e in r.episodes) {
      episodes[e.id] = _mergePending(e);
    }
    for (final id in r.episodesDeleted) {
      episodes.remove(id);
    }
    // Drop episodes of podcasts we no longer have.
    episodes.removeWhere((_, e) => !podcasts.containsKey(e.podcastId));
    final queueSet = r.queue.episodeIds.toSet();
    for (final e in episodes.values.toList()) {
      final inQ = queueSet.contains(e.id);
      if (e.inQueue != inQ) episodes[e.id] = e.copyWith(inQueue: inQ);
    }
    state = state.copyWith(
      podcasts: podcasts,
      episodes: episodes,
      queueIds: r.queue.episodeIds.where(episodes.containsKey).toList(),
      queueVersion: r.queue.version,
      settings: r.settings,
      lastSync: r.serverTime,
      initialSyncDone: true,
      clearError: true,
      playback: r.playback ?? const PlaybackLock(active: false),
    );
    _persist();
  }

  /// Keep locally newer progress over what the server sent.
  Episode _mergePending(Episode e) {
    final p = state.pendingProgress[e.id];
    if (p == null) return e;
    final serverTs = e.progressUpdatedAt;
    if (serverTs != null && !p.updatedAt.isAfter(serverTs)) return e;
    return e.copyWith(
      positionMs: p.positionMs,
      durationMs: p.durationMs,
      played: p.played,
      progressUpdatedAt: p.updatedAt,
    );
  }

  void setSyncing(bool v) => state = state.copyWith(syncing: v);

  // ----------------------------------------------------------------- queue

  void _applyQueue(QueueState q) {
    final episodes = Map<String, Episode>.of(state.episodes);
    final ids = <String>[];
    for (final e in q.items) {
      episodes[e.id] = _mergePending(e).copyWith(inQueue: true);
      ids.add(e.id);
    }
    final set = ids.toSet();
    for (final e in episodes.values.toList()) {
      if (e.inQueue && !set.contains(e.id)) episodes[e.id] = e.copyWith(inQueue: false);
    }
    state = state.copyWith(episodes: episodes, queueIds: ids, queueVersion: q.version, clearError: true);
    _persist();
  }

  Future<void> enqueue(Episode e, {Object position = 'back'}) async {
    // Optimistic local update.
    if (!state.queueIds.contains(e.id)) {
      final ids = [...state.queueIds];
      if (position == 'front') {
        ids.insert(0, e.id);
      } else {
        ids.add(e.id);
      }
      _localQueue(ids, upsert: e);
    }
    _applyQueue(await _api.enqueue(e.id, position: position));
  }

  Future<void> dequeue(String episodeId) async {
    _localQueue(state.queueIds.where((id) => id != episodeId).toList());
    _applyQueue(await _api.dequeue(episodeId));
  }

  Future<void> move(String episodeId, int to) async {
    final ids = [...state.queueIds];
    final from = ids.indexOf(episodeId);
    if (from < 0) return;
    ids.removeAt(from);
    ids.insert(to.clamp(0, ids.length), episodeId);
    _localQueue(ids);
    _applyQueue(await _api.moveInQueue(episodeId, to));
  }

  /// Full reorder with version check. Returns false on conflict (server state
  /// has been adopted locally in that case).
  Future<bool> replaceQueue(List<String> ids) async {
    final version = state.queueVersion;
    _localQueue(ids);
    try {
      _applyQueue(await _api.replaceQueue(version, ids));
      return true;
    } on QueueConflictException catch (c) {
      _applyQueue(c.current);
      return false;
    }
  }

  Future<void> clearQueue() async {
    _localQueue(const []);
    _applyQueue(await _api.clearQueue());
  }

  void _localQueue(List<String> ids, {Episode? upsert}) {
    final episodes = Map<String, Episode>.of(state.episodes);
    if (upsert != null) episodes[upsert.id] = upsert;
    final set = ids.toSet();
    for (final e in episodes.values.toList()) {
      final inQ = set.contains(e.id);
      if (e.inQueue != inQ) episodes[e.id] = e.copyWith(inQueue: inQ);
    }
    state = state.copyWith(episodes: episodes, queueIds: ids);
  }

  // -------------------------------------------------------------- progress

  /// Optimistic local update + best-effort network push. Failures stay in
  /// [LibraryState.pendingProgress] and are flushed by the sync service.
  Future<void> reportProgress(ProgressUpdate u, {bool flush = true}) async {
    final episodes = Map<String, Episode>.of(state.episodes);
    final existing = episodes[u.episodeId];
    if (existing != null) {
      episodes[u.episodeId] = existing.copyWith(
        positionMs: u.positionMs,
        durationMs: u.durationMs != null && u.durationMs! > 0 ? u.durationMs : null,
        played: u.played,
        progressUpdatedAt: u.updatedAt,
      );
    }
    var ids = state.queueIds;
    if (u.played == true && state.settings.autoRemovePlayed) {
      ids = ids.where((id) => id != u.episodeId).toList();
      final e = episodes[u.episodeId];
      if (e != null) episodes[u.episodeId] = e.copyWith(inQueue: false);
    }
    state = state.copyWith(
      episodes: episodes,
      queueIds: ids,
      pendingProgress: {...state.pendingProgress, u.episodeId: u},
    );
    _persist();
    if (flush) await flushPendingProgress();
  }

  Future<void> flushPendingProgress() async {
    if (state.pendingProgress.isEmpty) return;
    final items = state.pendingProgress.values.toList();
    try {
      final result = await _api.progressBatch(items);
      final episodes = Map<String, Episode>.of(state.episodes);
      for (final e in result) {
        if (episodes.containsKey(e.id)) episodes[e.id] = e;
      }
      final pending = Map<String, ProgressUpdate>.of(state.pendingProgress);
      for (final u in items) {
        if (identical(pending[u.episodeId], u)) pending.remove(u.episodeId);
      }
      // Queue membership may have changed (auto-remove played).
      final removed = result.where((e) => !e.inQueue).map((e) => e.id).toSet();
      final ids = state.queueIds.where((id) => !removed.contains(id)).toList();
      state = state.copyWith(episodes: episodes, pendingProgress: pending, queueIds: ids, clearError: true);
      _persist();
    } on UnauthorizedException {
      rethrow;
    } on ApiException {
      // keep pending
    }
  }

  Future<void> markPlayed(Episode e, {bool played = true}) => reportProgress(ProgressUpdate(
        episodeId: e.id,
        positionMs: played ? (e.durationMs > 0 ? e.durationMs : e.positionMs) : 0,
        durationMs: e.durationMs > 0 ? e.durationMs : null,
        played: played,
        updatedAt: DateTime.now().toUtc(),
      ));

  // -------------------------------------------------------------- podcasts

  void _upsertPodcast(Podcast p) {
    state = state.copyWith(podcasts: {...state.podcasts, p.id: p}, clearError: true);
    _persist();
  }

  Future<Podcast> addPodcast({
    required String feedUrl,
    String authUsername = '',
    String authPassword = '',
    bool? autoEnqueue,
  }) async {
    final p = await _api.addPodcast(
      feedUrl: feedUrl,
      authUsername: authUsername,
      authPassword: authPassword,
      autoEnqueue: autoEnqueue,
    );
    _upsertPodcast(p);
    await loadEpisodes(p.id);
    return p;
  }

  Future<Podcast> updatePodcast(
    String id, {
    bool? autoEnqueue,
    String? authUsername,
    String? authPassword,
    String? title,
  }) async {
    final p = await _api.updatePodcast(
      id,
      autoEnqueue: autoEnqueue,
      authUsername: authUsername,
      authPassword: authPassword,
      title: title,
    );
    _upsertPodcast(p);
    // stream_url of episodes may change when auth changes.
    if (authUsername != null || authPassword != null) await loadEpisodes(id);
    return p;
  }

  Future<void> unsubscribe(String id) async {
    await _api.deletePodcast(id);
    final podcasts = Map<String, Podcast>.of(state.podcasts)..remove(id);
    final episodes = Map<String, Episode>.of(state.episodes)..removeWhere((_, e) => e.podcastId == id);
    final pending = Map<String, ProgressUpdate>.of(state.pendingProgress)
      ..removeWhere((k, _) => !episodes.containsKey(k));
    state = state.copyWith(
      podcasts: podcasts,
      episodes: episodes,
      queueIds: state.queueIds.where(episodes.containsKey).toList(),
      pendingProgress: pending,
      clearError: true,
    );
    _persist();
  }

  Future<Podcast> refreshPodcast(String id) async {
    final p = await _api.refreshPodcast(id);
    _upsertPodcast(p);
    return p;
  }

  Future<RefreshResult> refreshAll() async {
    state = state.copyWith(refreshing: true);
    try {
      return await _api.refreshAll();
    } finally {
      state = state.copyWith(refreshing: false);
    }
  }

  /// Load (more) episodes of a podcast into the cache.
  Future<List<Episode>> loadEpisodes(String podcastId, {int limit = 100, int offset = 0}) async {
    final list = await _api.podcastEpisodes(podcastId, limit: limit, offset: offset);
    final episodes = Map<String, Episode>.of(state.episodes);
    for (final e in list) {
      episodes[e.id] = _mergePending(e);
    }
    state = state.copyWith(episodes: episodes, clearError: true);
    _persist();
    return list;
  }

  // -------------------------------------------------------------- settings

  Future<void> updateSettings({
    bool? autoRemovePlayed,
    int? refreshIntervalMinutes,
    bool? autoEnqueueDefault,
  }) async {
    final s = await _api.updateSettings(
      autoRemovePlayed: autoRemovePlayed,
      refreshIntervalMinutes: refreshIntervalMinutes,
      autoEnqueueDefault: autoEnqueueDefault,
    );
    state = state.copyWith(settings: s, clearError: true);
    _persist();
  }

  /// Remove a single episode locally (e.g. server says it's gone).
  void forgetEpisode(String id) {
    if (!state.episodes.containsKey(id)) return;
    final episodes = Map<String, Episode>.of(state.episodes)..remove(id);
    state = state.copyWith(episodes: episodes, queueIds: state.queueIds.where((q) => q != id).toList());
    _persist();
  }

  Future<void> persistNow() => ref.read(localStoreProvider).flush();
}

final libraryProvider = NotifierProvider<LibraryNotifier, LibraryState>(LibraryNotifier.new);

/// Convenience selectors.
final queueProvider = Provider<List<Episode>>((ref) => ref.watch(libraryProvider).queue);
final podcastsProvider = Provider<List<Podcast>>((ref) => ref.watch(libraryProvider).sortedPodcasts);
final episodeProvider = Provider.family<Episode?, String>((ref, id) => ref.watch(libraryProvider).episodes[id]);
final podcastProvider = Provider.family<Podcast?, String>((ref, id) => ref.watch(libraryProvider).podcasts[id]);
