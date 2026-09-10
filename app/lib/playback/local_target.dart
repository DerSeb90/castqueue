import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';

import 'playback_target.dart';

/// Plays on this device via just_audio (media_kit backend on Windows).
class LocalTarget implements PlaybackTarget {
  LocalTarget() {
    _player.playerStateStream.listen(_onPlayerState);
    _player.positionStream.listen((_) => _emit());
    _player.durationStream.listen((_) => _emit());
    _player.speedStream.listen((_) => _emit());
  }

  final AudioPlayer _player = AudioPlayer();
  final _controller = StreamController<PlaybackStatus>.broadcast();
  PlaybackStatus _status = PlaybackStatus.idle;
  String? _itemId;
  PlayItem? _next;
  bool _completedEmitted = false;
  bool _loading = false;

  @override
  String get id => 'local';

  @override
  String get name => Platform.isWindows ? 'Dieser PC' : 'Dieses Gerät';

  @override
  bool get supportsSpeed => true;

  @override
  Stream<PlaybackStatus> get status async* {
    yield _status;
    yield* _controller.stream;
  }

  @override
  PlaybackStatus get currentStatus => _status;

  void _onPlayerState(PlayerState s) => _emit();

  void _emit({String? error}) {
    if (_controller.isClosed) return;
    final ps = _player.playerState;
    PlaybackState state;
    if (error != null) {
      state = PlaybackState.error;
    } else if (_itemId == null) {
      state = PlaybackState.idle;
    } else if (_loading || ps.processingState == ProcessingState.loading) {
      state = PlaybackState.loading;
    } else if (ps.processingState == ProcessingState.completed) {
      state = PlaybackState.completed;
    } else if (ps.processingState == ProcessingState.buffering) {
      state = ps.playing ? PlaybackState.loading : PlaybackState.paused;
    } else if (ps.processingState == ProcessingState.idle) {
      state = PlaybackState.idle;
    } else {
      state = ps.playing ? PlaybackState.playing : PlaybackState.paused;
    }
    if (state == PlaybackState.completed) {
      if (_completedEmitted) return;
      _completedEmitted = true;
    }
    final dur = _player.duration;
    var pos = _player.position;
    if (state == PlaybackState.completed && dur != null) pos = dur;
    _status = PlaybackStatus(
      state: state,
      position: pos,
      duration: dur,
      itemId: _itemId,
      speed: _player.speed,
      error: error,
    );
    _controller.add(_status);
  }

  @override
  Future<void> load(PlayItem item, {Duration startAt = Duration.zero, bool autoplay = true}) async {
    _itemId = item.id;
    _completedEmitted = false;
    _loading = true;
    _emit();
    try {
      final source = item.url.scheme == 'file'
          ? AudioSource.file(item.url.toFilePath())
          : AudioSource.uri(item.url);
      await _player.setAudioSource(source, initialPosition: startAt, preload: true);
      _loading = false;
      _emit();
      if (autoplay) unawaited(_player.play());
    } catch (e) {
      _loading = false;
      _emit(error: 'Wiedergabe fehlgeschlagen: $e');
      rethrow;
    }
  }

  @override
  Future<void> play() async {
    if (_itemId == null) return;
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    _completedEmitted = false;
    unawaited(_player.play());
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() async {
    _itemId = null;
    _next = null;
    await _player.stop();
    _status = PlaybackStatus.idle;
    if (!_controller.isClosed) _controller.add(_status);
  }

  @override
  Future<void> seek(Duration position) async {
    _completedEmitted = false;
    await _player.seek(position);
    _emit();
  }

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  bool get supportsVolume => true;

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume.clamp(0.0, 1.0));

  @override
  Future<double?> readVolume() async => _player.volume;

  @override
  Future<void> setNext(PlayItem? item) async {
    // just_audio has no single-track "next" hint; the controller handles
    // advancing on completion. Kept for interface parity.
    _next = item;
  }

  PlayItem? get nextHint => _next;

  @override
  Future<void> dispose() async {
    await _controller.close();
    await _player.dispose();
  }
}
