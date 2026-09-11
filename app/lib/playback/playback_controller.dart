import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/models.dart';
import '../downloads/download_manager.dart';
import '../sonos/sonos.dart';
import '../state/app_state.dart';
import '../state/library.dart';
import 'local_target.dart';
import 'playback_target.dart';

class PlaybackUiState {
  const PlaybackUiState({
    this.episode,
    this.status = PlaybackStatus.idle,
    this.targetId = 'local',
    this.targetName = '',
    this.targetSupportsSpeed = true,
    this.targetSupportsVolume = true,
    this.speed = 1.0,
    this.volume = 1.0,
    this.sonosDevices = const [],
    this.discovering = false,
    this.error,
    this.notice,
  });

  final Episode? episode;
  final PlaybackStatus status;
  final String targetId;
  final String targetName;
  final bool targetSupportsSpeed;
  final bool targetSupportsVolume;
  final double speed;
  final double volume;
  final List<SonosDevice> sonosDevices;
  final bool discovering;
  final String? error;

  /// Non-error information for the user (e.g. playback taken over elsewhere).
  final String? notice;

  bool get hasItem => episode != null && status.state != PlaybackState.idle;
  bool get isPlaying => status.state == PlaybackState.playing || status.state == PlaybackState.loading;
  bool get isLoading => status.state == PlaybackState.loading;
  bool get isSonos => targetId.startsWith('sonos:');

  Duration get position => status.position;
  Duration get duration {
    final d = status.duration;
    if (d != null && d > Duration.zero) return d;
    return episode?.duration ?? Duration.zero;
  }

  PlaybackUiState copyWith({
    Episode? episode,
    bool clearEpisode = false,
    PlaybackStatus? status,
    String? targetId,
    String? targetName,
    bool? targetSupportsSpeed,
    bool? targetSupportsVolume,
    double? speed,
    double? volume,
    List<SonosDevice>? sonosDevices,
    bool? discovering,
    String? error,
    bool clearError = false,
    String? notice,
    bool clearNotice = false,
  }) =>
      PlaybackUiState(
        notice: clearNotice ? null : (notice ?? this.notice),
        episode: clearEpisode ? null : (episode ?? this.episode),
        status: status ?? this.status,
        targetId: targetId ?? this.targetId,
        targetName: targetName ?? this.targetName,
        targetSupportsSpeed: targetSupportsSpeed ?? this.targetSupportsSpeed,
        targetSupportsVolume: targetSupportsVolume ?? this.targetSupportsVolume,
        speed: speed ?? this.speed,
        volume: volume ?? this.volume,
        sonosDevices: sonosDevices ?? this.sonosDevices,
        discovering: discovering ?? this.discovering,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Drives the active [PlaybackTarget], walks the queue and reports progress.
class PlaybackController extends Notifier<PlaybackUiState> {
  late LocalTarget _local;
  late PlaybackTarget _target;
  StreamSubscription<PlaybackStatus>? _sub;
  Timer? _progressTimer;
  bool _handlingCompletion = false;
  String? _completedFor;
  static const _reportEvery = Duration(seconds: 10);
  static const _resumeRewind = Duration(seconds: 3);

  @override
  PlaybackUiState build() {
    _local = LocalTarget();
    _target = _local;
    _subscribe();
    _progressTimer = Timer.periodic(_reportEvery, (_) {
      if (state.isPlaying) {
        unawaited(_report());
        unawaited(_heartbeat());
      }
    });
    ref.listen(libraryProvider.select((s) => s.queueIds), (_, _) => unawaited(_updateNextHint()));
    ref.listen(libraryProvider.select((s) => s.playback), (_, lock) => unawaited(_onServerLock(lock)));
    ref.onDispose(() {
      _progressTimer?.cancel();
      _sub?.cancel();
      if (!identical(_target, _local)) unawaited(_target.dispose());
      unawaited(_local.dispose());
    });
    final prefs = ref.read(appPrefsProvider);
    final speed = prefs.defaultSpeed;
    final volume = prefs.localVolume.clamp(0.0, 1.0);
    unawaited(_local.setSpeed(speed));
    unawaited(_local.setVolume(volume));
    return PlaybackUiState(targetId: _local.id, targetName: _local.name, speed: speed, volume: volume);
  }

  LibraryNotifier get _lib => ref.read(libraryProvider.notifier);

  void _subscribe() {
    _sub?.cancel();
    _sub = _target.status.listen(_onStatus);
  }

  void _onStatus(PlaybackStatus s) {
    var ep = state.episode;
    // Target advanced on its own (Sonos gapless "next").
    if (s.itemId != null && ep != null && s.itemId != ep.id) {
      final next = ref.read(libraryProvider).episodes[s.itemId!];
      if (next != null) {
        final prev = ep;
        ep = next;
        unawaited(_report(episode: prev, played: true, position: prev.duration));
        state = state.copyWith(episode: next);
        _completedFor = null;
        unawaited(_updateNextHint());
      }
    }
    state = state.copyWith(status: s, error: s.error, clearError: s.error == null);
    if (s.state == PlaybackState.completed && ep != null && _completedFor != ep.id) {
      _completedFor = ep.id;
      unawaited(_onCompleted(ep));
    }
  }

  // --------------------------------------------------------------- items

  PlayItem _itemFor(Episode ep, PlaybackTarget target) {
    Uri url = Uri.parse(ep.streamUrl.isNotEmpty ? ep.streamUrl : ep.mediaUrl);
    if (identical(target, _local)) {
      final f = ref.read(downloadManagerProvider.notifier).fileFor(ep.id);
      if (f != null && f.existsSync()) url = f.uri;
    }
    return PlayItem(
      id: ep.id,
      url: url,
      title: ep.title,
      artist: ep.podcastTitle,
      artworkUrl: ep.artworkUrl.isNotEmpty ? Uri.tryParse(ep.artworkUrl) : null,
      duration: ep.durationMs > 0 ? ep.duration : null,
      mimeType: ep.mediaType.isNotEmpty ? ep.mediaType : null,
    );
  }

  Episode? _nextInQueue(String? currentId) {
    for (final e in ref.read(libraryProvider).queue) {
      if (e.id != currentId && !e.played) return e;
    }
    return null;
  }

  Future<void> _updateNextHint() async {
    final ep = state.episode;
    if (ep == null) return;
    final next = _nextInQueue(ep.id);
    try {
      await _target.setNext(next == null ? null : _itemFor(next, _target));
    } catch (_) {}
  }

  // ------------------------------------------------------------ playback

  Future<void> playEpisode(Episode ep) async {
    final lib = ref.read(libraryProvider);
    if (!lib.queueIds.contains(ep.id)) {
      try {
        await _lib.enqueue(ep, position: 'front');
      } on ApiException catch (e) {
        _lib.setError(e.message);
      }
    }
    final prev = state.episode;
    if (prev != null && prev.id != ep.id && state.hasItem) await _report(episode: prev);
    final fresh = ref.read(libraryProvider).episodes[ep.id] ?? ep;
    final startMs = fresh.played ? 0 : math.max(0, fresh.positionMs - _resumeRewind.inMilliseconds);
    _completedFor = null;
    state = state.copyWith(episode: fresh, clearError: true);
    try {
      await _target.load(_itemFor(fresh, _target), startAt: Duration(milliseconds: startMs));
      if (_target.supportsSpeed) await _target.setSpeed(state.speed);
      unawaited(_claim());
      unawaited(_updateNextHint());
    } catch (e) {
      state = state.copyWith(error: 'Wiedergabe fehlgeschlagen: $e');
    }
  }

  Future<void> playQueue() async {
    final next = _nextInQueue(null);
    if (next != null) await playEpisode(next);
  }

  Future<void> togglePlay() async {
    if (!state.hasItem) {
      final ep = state.episode;
      if (ep != null) return playEpisode(ep);
      return playQueue();
    }
    if (state.isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  Future<void> play() async {
    if (!state.hasItem) return togglePlay();
    await _target.play();
    unawaited(_claim());
  }

  Future<void> pause() async {
    await _target.pause();
    await _report();
    unawaited(_release());
  }

  Future<void> stop({bool report = true}) async {
    if (report && state.hasItem) await _report();
    unawaited(_release());
    _completedFor = null;
    try {
      await _target.stop();
    } catch (_) {}
    state = state.copyWith(status: PlaybackStatus.idle, clearEpisode: true, clearError: true);
  }

  Future<void> seek(Duration pos) async {
    final d = state.duration;
    var p = pos < Duration.zero ? Duration.zero : pos;
    if (d > Duration.zero && p > d) p = d;
    await _target.seek(p);
    await _report(position: p);
  }

  Future<void> skipForward() =>
      seek(state.position + Duration(seconds: ref.read(appPrefsProvider).skipForwardSeconds));

  Future<void> skipBack() => seek(state.position - Duration(seconds: ref.read(appPrefsProvider).skipBackSeconds));

  Future<void> next() async {
    final cur = state.episode;
    if (cur != null && state.hasItem) await _report(episode: cur);
    final n = _nextInQueue(cur?.id);
    if (n != null) {
      await playEpisode(n);
    } else {
      await stop(report: false);
    }
  }

  Future<void> setSpeed(double speed) async {
    final s = speed.clamp(0.5, 3.0).toDouble();
    state = state.copyWith(speed: s);
    await ref.read(appPrefsProvider.notifier).setDefaultSpeed(s);
    if (_target.supportsSpeed) await _target.setSpeed(s);
  }

  Future<void> setVolume(double volume) async {
    final v = volume.clamp(0.0, 1.0);
    state = state.copyWith(volume: v);
    if (identical(_target, _local)) {
      await ref.read(appPrefsProvider.notifier).setLocalVolume(v);
    }
    if (_target.supportsVolume) {
      try {
        await _target.setVolume(v);
      } catch (e) {
        state = state.copyWith(error: 'Lautstärke fehlgeschlagen: $e');
      }
    }
  }

  Future<void> _refreshVolume() async {
    if (!_target.supportsVolume) return;
    try {
      final v = await _target.readVolume();
      if (v != null) state = state.copyWith(volume: v);
    } catch (_) {}
  }

  Future<void> _onCompleted(Episode ep) async {
    if (_handlingCompletion) return;
    _handlingCompletion = true;
    try {
      await _report(episode: ep, played: true, position: ep.durationMs > 0 ? ep.duration : state.position);
      final n = _nextInQueue(ep.id);
      if (n != null) {
        await playEpisode(n);
      } else {
        await stop(report: false);
      }
    } finally {
      _handlingCompletion = false;
    }
  }

  // ------------------------------------------------------------ progress

  Future<void> _report({Episode? episode, bool? played, Duration? position}) async {
    final ep = episode ?? state.episode;
    if (ep == null) return;
    final pos = position ?? state.position;
    final dur = (state.status.duration ?? Duration.zero) > Duration.zero ? state.status.duration! : ep.duration;
    try {
      await _lib.reportProgress(
        ProgressUpdate(
          episodeId: ep.id,
          positionMs: pos.inMilliseconds,
          durationMs: dur > Duration.zero ? dur.inMilliseconds : null,
          played: played,
          updatedAt: DateTime.now().toUtc(),
        ),
        // Offline the flush would block pause/seek until the timeout; the
        // update is persisted locally and retried by the sync service.
        flush: false,
      );
      unawaited(_lib.flushPendingProgress().catchError((_) {}));
    } on UnauthorizedException {
      // handled by sync service
    } catch (_) {}
  }

  // ------------------------------------------------------ exclusive playback
  //
  // Only one device may play at a time. Starting playback claims the server
  // lock (taking over from any other device); while playing we heartbeat
  // every [_reportEvery]. A 409 on heartbeat, or a live lock of another
  // device arriving via sync, pauses this device.

  DateTime? _lastClaimAt;

  String get _myDeviceId => ref.read(sessionProvider)?.deviceId ?? '';

  Future<void> _claim() async {
    final ep = state.episode;
    final api = ref.read(apiClientProvider);
    if (ep == null || api == null) return;
    _lastClaimAt = DateTime.now().toUtc();
    try {
      await api.playbackClaim(ep.id, state.targetName);
    } catch (_) {
      // offline: play anyway, the next heartbeat claims
    }
  }

  Future<void> _heartbeat() async {
    final ep = state.episode;
    final api = ref.read(apiClientProvider);
    if (ep == null || api == null || !state.isPlaying) return;
    try {
      await api.playbackHeartbeat(ep.id, state.targetName);
    } on PlaybackConflictException catch (e) {
      await _takenOver(e.lock);
    } catch (_) {}
  }

  Future<void> _release() async {
    final api = ref.read(apiClientProvider);
    if (api == null) return;
    try {
      await api.playbackRelease();
    } catch (_) {}
  }

  Future<void> _onServerLock(PlaybackLock? lock) async {
    if (lock == null || !lock.live || !state.isPlaying) return;
    if (lock.deviceId.isEmpty || lock.deviceId == _myDeviceId) return;
    // A sync that was in flight while we claimed may still carry the old holder.
    final claimed = _lastClaimAt;
    if (claimed != null && lock.heartbeatAt != null && lock.heartbeatAt!.isBefore(claimed)) return;
    await _takenOver(lock);
  }

  Future<void> _takenOver(PlaybackLock lock) async {
    if (!state.isPlaying) return;
    try {
      await _target.pause();
    } catch (_) {}
    await _report();
    final where = lock.target.isNotEmpty && lock.target != lock.deviceName
        ? '${lock.deviceName} (${lock.target})'
        : lock.deviceName;
    state = state.copyWith(notice: 'Wiedergabe läuft jetzt auf „$where“ – hier pausiert.');
  }

  void clearNotice() => state = state.copyWith(clearNotice: true);

  /// App going to background / closing.
  Future<void> onAppPaused() async {
    if (state.hasItem) await _report();
    await _lib.persistNow();
  }

  // ------------------------------------------------------------- targets

  Future<void> discoverSonos() async {
    state = state.copyWith(discovering: true);
    try {
      final found = await SonosDiscovery.discover();
      final byId = {for (final d in found) d.uuid: d};
      for (final host in ref.read(appPrefsProvider).sonosHosts) {
        try {
          final d = await SonosDiscovery.fromHost(host);
          byId.putIfAbsent(d.uuid, () => d);
        } catch (_) {}
      }
      final list = byId.values.toList()..sort((a, b) => a.roomName.compareTo(b.roomName));
      state = state.copyWith(sonosDevices: list);
    } finally {
      state = state.copyWith(discovering: false);
    }
  }

  Future<void> selectTarget(String id) async {
    if (id == state.targetId) return;
    if (id == 'local') return _switchTo(_local);
    SonosDevice? dev;
    for (final d in state.sonosDevices) {
      if ('sonos:${d.uuid}' == id) dev = d;
    }
    if (dev == null) return;
    await _switchTo(SonosTarget(dev));
  }

  Future<void> _switchTo(PlaybackTarget t) async {
    final ep = state.episode;
    final wasActive = state.hasItem;
    final wasPlaying = state.isPlaying;
    final pos = state.position;
    if (wasActive) await _report();
    _sub?.cancel();
    final old = _target;
    try {
      await old.stop();
    } catch (_) {}
    if (!identical(old, _local)) unawaited(old.dispose());
    _target = t;
    _subscribe();
    state = state.copyWith(
      targetId: t.id,
      targetName: t.name,
      targetSupportsSpeed: t.supportsSpeed,
      targetSupportsVolume: t.supportsVolume,
      status: PlaybackStatus.idle,
      clearError: true,
    );
    if (identical(t, _local)) {
      state = state.copyWith(volume: ref.read(appPrefsProvider).localVolume);
    } else {
      unawaited(_refreshVolume());
    }
    if (ep != null && wasActive) {
      _completedFor = null;
      try {
        await t.load(_itemFor(ep, t), startAt: pos, autoplay: wasPlaying);
        if (t.supportsSpeed) await t.setSpeed(state.speed);
        unawaited(_updateNextHint());
      } catch (e) {
        state = state.copyWith(error: 'Wiedergabe auf ${t.name} fehlgeschlagen: $e');
      }
    }
  }
}

final playbackControllerProvider =
    NotifierProvider<PlaybackController, PlaybackUiState>(PlaybackController.new);
