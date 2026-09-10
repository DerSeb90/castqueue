import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../downloads/download_manager.dart';
import '../playback/playback_controller.dart';
import '../state/app_state.dart';
import '../state/library.dart';
import 'api_client.dart';

/// Pulls `/api/sync` deltas: at start, every 30 s in the foreground and on
/// demand after mutations. Flushes pending progress first.
class SyncService {
  SyncService(this._ref);

  final Ref _ref;
  Timer? _timer;
  bool _foreground = true;
  bool _busy = false;
  bool _again = false;
  static const interval = Duration(seconds: 30);

  void start() {
    _foreground = true;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => syncNow());
    syncNow();
  }

  void stop() {
    _foreground = false;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => stop();

  /// Runs a sync; concurrent calls coalesce into one follow-up run.
  Future<void> syncNow({bool full = false}) async {
    if (_ref.read(apiClientProvider) == null) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    final lib = _ref.read(libraryProvider.notifier);
    lib.setSyncing(true);
    try {
      await lib.flushPendingProgress();
      final state = _ref.read(libraryProvider);
      final since = full ? null : state.lastSync;
      final api = _ref.read(apiClientProvider);
      if (api == null) return;
      final resp = await api.sync(since: since);
      final deletedEpisodes = resp.episodesDeleted.toSet();
      final deletedPodcasts = resp.podcastsDeleted.toSet();
      lib.applySync(resp, full: since == null);
      // Stop playback if the current episode vanished (unsubscribed elsewhere).
      final playing = _ref.read(playbackControllerProvider).episode;
      if (playing != null) {
        final stillThere = _ref.read(libraryProvider).episodes.containsKey(playing.id);
        if (!stillThere || deletedEpisodes.contains(playing.id) || deletedPodcasts.contains(playing.podcastId)) {
          await _ref.read(playbackControllerProvider.notifier).stop(report: false);
        }
      }
      await _ref.read(downloadManagerProvider.notifier).reconcile();
    } on UnauthorizedException {
      await _ref.read(playbackControllerProvider.notifier).stop(report: false);
      await _ref.read(sessionProvider.notifier).clear();
    } on ApiException catch (e) {
      lib.setError(e.message);
    } catch (e) {
      lib.setError('Sync fehlgeschlagen: $e');
    } finally {
      lib.setSyncing(false);
      _busy = false;
      if (_again) {
        _again = false;
        if (_foreground) unawaited(syncNow());
      }
    }
  }

  /// Refresh feeds on the server, then sync.
  Future<void> refreshAndSync() async {
    final lib = _ref.read(libraryProvider.notifier);
    try {
      await lib.refreshAll();
    } on UnauthorizedException {
      await _ref.read(sessionProvider.notifier).clear();
      return;
    } on ApiException catch (e) {
      lib.setError(e.message);
    }
    await syncNow();
  }
}

final syncServiceProvider = Provider<SyncService>((ref) {
  final s = SyncService(ref);
  ref.onDispose(s.dispose);
  return s;
});
