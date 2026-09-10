/// Abstraction over "where audio plays": the local device (just_audio) or a
/// Sonos speaker in the LAN (UPnP/AVTransport). The playback controller in the
/// app only talks to this interface; progress reporting to the server is done
/// by the controller based on [PlaybackStatus] updates.
library;

/// What to play. `url` must be fetchable by the target itself (for Sonos this
/// means a public/LAN-reachable URL — use `Episode.stream_url` from the server,
/// never a local file path).
class PlayItem {
  const PlayItem({
    required this.id,
    required this.url,
    required this.title,
    required this.artist,
    this.artworkUrl,
    this.duration,
    this.mimeType,
  });

  /// Episode id (server id).
  final String id;
  final Uri url;
  final String title;

  /// Podcast title.
  final String artist;
  final Uri? artworkUrl;
  final Duration? duration;

  /// e.g. `audio/mpeg`. Sonos uses it for DIDL-Lite metadata.
  final String? mimeType;
}

enum PlaybackState { idle, loading, playing, paused, completed, error }

class PlaybackStatus {
  const PlaybackStatus({
    required this.state,
    required this.position,
    required this.duration,
    required this.itemId,
    this.speed = 1.0,
    this.error,
  });

  final PlaybackState state;
  final Duration position;

  /// `null` when unknown (e.g. live/unknown length streams).
  final Duration? duration;

  /// Id of the [PlayItem] currently loaded, `null` if none.
  final String? itemId;
  final double speed;
  final String? error;

  static const idle = PlaybackStatus(
    state: PlaybackState.idle,
    position: Duration.zero,
    duration: null,
    itemId: null,
  );

  PlaybackStatus copyWith({
    PlaybackState? state,
    Duration? position,
    Duration? duration,
    String? itemId,
    double? speed,
    String? error,
  }) {
    return PlaybackStatus(
      state: state ?? this.state,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      itemId: itemId ?? this.itemId,
      speed: speed ?? this.speed,
      error: error,
    );
  }
}

abstract class PlaybackTarget {
  /// Stable id: `local` for the device itself, `sonos:<uuid>` for speakers.
  String get id;

  /// Human readable, e.g. "Dieser PC", "Wohnzimmer".
  String get name;

  bool get supportsSpeed;

  /// Emits at least once per second while playing, and immediately on every
  /// state change. Must replay the latest value to new listeners.
  Stream<PlaybackStatus> get status;
  PlaybackStatus get currentStatus;

  /// Load [item]; if [autoplay] start playback at [startAt].
  Future<void> load(PlayItem item, {Duration startAt = Duration.zero, bool autoplay = true});

  Future<void> play();
  Future<void> pause();

  /// Stop and unload; status becomes idle.
  Future<void> stop();
  Future<void> seek(Duration position);

  /// No-op when [supportsSpeed] is false.
  Future<void> setSpeed(double speed);

  /// Optional gapless hint for the next queue item. Targets that cannot
  /// pre-queue may ignore it. Pass `null` to clear.
  Future<void> setNext(PlayItem? item);

  Future<void> dispose();
}
