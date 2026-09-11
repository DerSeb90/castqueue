import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diagnostics.dart';
import 'playback_controller.dart';
import 'playback_target.dart' as pt;

/// Android: mirrors the [PlaybackController] into the media notification /
/// lockscreen and forwards media button presses back to it.
class CastQueueAudioHandler extends BaseAudioHandler with SeekHandler {
  CastQueueAudioHandler(this._container) {
    _container.listen<PlaybackUiState>(playbackControllerProvider, (_, s) => _mirror(s), fireImmediately: true);
  }

  final ProviderContainer _container;
  String? _lastItemId;
  bool? _lastPlaying;

  PlaybackController get _ctl => _container.read(playbackControllerProvider.notifier);

  void _mirror(PlaybackUiState s) {
    final ep = s.episode;
    if (ep == null || !s.hasItem) {
      if (_lastItemId != null) {
        _lastItemId = null;
        mediaItem.add(null);
      }
      playbackState.add(playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
        controls: const [],
        updatePosition: Duration.zero,
      ));
      return;
    }
    if (_lastItemId != ep.id || (mediaItem.value?.duration == null && s.duration > Duration.zero)) {
      _lastItemId = ep.id;
      mediaItem.add(MediaItem(
        id: ep.id,
        title: ep.title,
        artist: ep.podcastTitle,
        album: ep.podcastTitle,
        artUri: ep.artworkUrl.isNotEmpty ? Uri.tryParse(ep.artworkUrl) : null,
        duration: s.duration > Duration.zero ? s.duration : null,
      ));
    }
    final playing = s.status.state == pt.PlaybackState.playing;
    if (playing != _lastPlaying) {
      _lastPlaying = playing;
      Diagnostics.log('media session: playing=$playing item=${ep.id} target=${s.targetId}');
    }
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.rewind,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward},
      androidCompactActionIndices: const [0, 1, 2],
      processingState: switch (s.status.state) {
        pt.PlaybackState.idle => AudioProcessingState.idle,
        pt.PlaybackState.loading => AudioProcessingState.buffering,
        pt.PlaybackState.playing || pt.PlaybackState.paused => AudioProcessingState.ready,
        pt.PlaybackState.completed => AudioProcessingState.completed,
        pt.PlaybackState.error => AudioProcessingState.error,
      },
      playing: playing,
      updatePosition: s.position,
      speed: s.speed,
    ));
  }

  @override
  Future<void> play() {
    Diagnostics.log('media button: play');
    return _ctl.play();
  }

  @override
  Future<void> pause() {
    Diagnostics.log('media button: pause');
    return _ctl.pause();
  }

  @override
  Future<void> stop() => _ctl.stop();

  @override
  Future<void> seek(Duration position) => _ctl.seek(position);

  @override
  Future<void> skipToNext() => _ctl.next();

  @override
  Future<void> fastForward() => _ctl.skipForward();

  @override
  Future<void> rewind() => _ctl.skipBack();

  @override
  Future<void> setSpeed(double speed) => _ctl.setSpeed(speed);
}
