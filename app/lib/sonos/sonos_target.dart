import 'dart:async';

import 'package:http/http.dart' as http;

import '../playback/playback_target.dart';
import 'didl.dart';
import 'soap.dart';
import 'sonos_device.dart';

const avTransportService = 'urn:schemas-upnp-org:service:AVTransport:1';
const avTransportControl = '/MediaRenderer/AVTransport/Control';

/// [PlaybackTarget] that drives a Sonos coordinator via UPnP AVTransport.
///
/// Position/state are polled (1 s while playing/loading, 3 s while paused).
/// The item URL must be reachable by the speaker itself (use the server's
/// `stream_url`, never a local path).
class SonosTarget implements PlaybackTarget {
  SonosTarget(this.device, {http.Client? httpClient})
      : _soap = SoapClient(device.baseUri, client: httpClient);

  final SonosDevice device;
  final SoapClient _soap;

  final _controller = StreamController<PlaybackStatus>.broadcast();
  PlaybackStatus _status = PlaybackStatus.idle;

  PlayItem? _current;
  PlayItem? _next;
  Timer? _timer;
  bool _polling = false;
  bool _stoppedByUs = false;
  bool _disposed = false;

  @override
  String get id => 'sonos:${device.uuid}';

  @override
  String get name => device.roomName;

  @override
  bool get supportsSpeed => false;

  @override
  PlaybackStatus get currentStatus => _status;

  /// Replays the latest status to every new listener.
  @override
  Stream<PlaybackStatus> get status async* {
    yield _status;
    yield* _controller.stream;
  }

  // ---- PlaybackTarget -----------------------------------------------------

  @override
  Future<void> load(PlayItem item, {Duration startAt = Duration.zero, bool autoplay = true}) async {
    _ensureAlive();
    _stoppedByUs = false;
    _current = item;
    _next = null;
    _emit(PlaybackStatus(
      state: PlaybackState.loading,
      position: startAt,
      duration: item.duration,
      itemId: item.id,
    ));
    try {
      await _av('SetAVTransportURI', {
        'CurrentURI': item.url.toString(),
        'CurrentURIMetaData': buildDidlLite(item),
      });
      if (autoplay) {
        await _av('Play', {'Speed': '1'});
      }
      if (startAt > Duration.zero) {
        await _seekWithRetry(startAt);
      }
      _emit(_status.copyWith(
        state: autoplay ? PlaybackState.playing : PlaybackState.paused,
        position: startAt,
      ));
      _schedulePoll();
    } catch (e) {
      _emit(PlaybackStatus(
        state: PlaybackState.error,
        position: Duration.zero,
        duration: item.duration,
        itemId: item.id,
        error: e.toString(),
      ));
      _cancelTimer();
      rethrow;
    }
  }

  @override
  Future<void> play() async {
    _ensureAlive();
    _stoppedByUs = false;
    await _av('Play', {'Speed': '1'});
    _emit(_status.copyWith(state: PlaybackState.playing));
    _schedulePoll();
  }

  @override
  Future<void> pause() async {
    _ensureAlive();
    await _av('Pause');
    _emit(_status.copyWith(state: PlaybackState.paused));
    _schedulePoll();
  }

  @override
  Future<void> stop() async {
    _ensureAlive();
    _stoppedByUs = true;
    _cancelTimer();
    try {
      await _av('Stop');
    } catch (_) {
      // Stopping an already-stopped transport is fine.
    }
    _current = null;
    _next = null;
    _emit(PlaybackStatus.idle);
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureAlive();
    await _seekWithRetry(position);
    _emit(_status.copyWith(position: position));
  }

  @override
  Future<void> setSpeed(double speed) async {
    // Sonos AVTransport has no playback rate control for streams.
  }

  @override
  Future<void> setNext(PlayItem? item) async {
    _ensureAlive();
    _next = item;
    try {
      await _av('SetNextAVTransportURI', {
        'NextURI': item?.url.toString() ?? '',
        'NextURIMetaData': item == null ? '' : buildDidlLite(item),
      });
    } catch (_) {
      // Best effort: not all firmwares accept a next URI for plain streams.
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _cancelTimer();
    await _controller.close();
    _soap.close();
  }

  // ---- internals ----------------------------------------------------------

  void _ensureAlive() {
    if (_disposed) throw const SonosException('SonosTarget disposed');
  }

  Future<Map<String, String>> _av(String action, [Map<String, String> args = const {}]) {
    return _soap.call(
      controlPath: avTransportControl,
      serviceType: avTransportService,
      action: action,
      args: {'InstanceID': '0', ...args},
    );
  }

  Future<void> _seekWithRetry(Duration position) async {
    final args = {'Unit': 'REL_TIME', 'Target': formatSonosTime(position)};
    try {
      await _av('Seek', args);
    } on SonosException catch (e) {
      // 701 = transition not available, 711 = illegal seek target: the track
      // is usually not loaded yet right after SetAVTransportURI/Play.
      if (e.upnpErrorCode == 701 || e.upnpErrorCode == 711) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await _av('Seek', args);
      } else {
        rethrow;
      }
    }
  }

  void _emit(PlaybackStatus s) {
    _status = s;
    if (!_controller.isClosed) _controller.add(s);
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _schedulePoll() {
    _cancelTimer();
    if (_disposed) return;
    final Duration interval;
    switch (_status.state) {
      case PlaybackState.playing:
      case PlaybackState.loading:
        interval = const Duration(seconds: 1);
      case PlaybackState.paused:
        interval = const Duration(seconds: 3);
      case PlaybackState.idle:
      case PlaybackState.completed:
      case PlaybackState.error:
        return;
    }
    _timer = Timer(interval, _pollOnce);
  }

  Future<void> _pollOnce() async {
    if (_disposed || _polling) return;
    _polling = true;
    try {
      final pos = await _av('GetPositionInfo');
      final ti = await _av('GetTransportInfo');
      _applyPoll(
        transportState: ti['CurrentTransportState'] ?? '',
        relTime: pos['RelTime'],
        trackDuration: pos['TrackDuration'],
        trackUri: pos['TrackURI'] ?? '',
      );
    } catch (e) {
      // Transient network error: keep the last status, poll again later.
      if (_status.state == PlaybackState.playing || _status.state == PlaybackState.loading) {
        _emit(_status.copyWith(error: e.toString()));
      }
    } finally {
      _polling = false;
      if (!_stoppedByUs) _schedulePoll();
    }
  }

  /// Turns one poll result into a status. Exposed for tests.
  void _applyPoll({
    required String transportState,
    required String? relTime,
    required String? trackDuration,
    required String trackUri,
  }) {
    if (_stoppedByUs) return;

    final position = parseSonosTime(relTime) ?? _status.position;
    final polledDuration = parseSonosTime(trackDuration);

    // Did Sonos advance to the "next" item on its own?
    if (_next != null && trackUri.isNotEmpty && _sameUrl(trackUri, _next!.url)) {
      _current = _next;
      _next = null;
    }
    final item = _current;
    final duration = (polledDuration != null && polledDuration > Duration.zero)
        ? polledDuration
        : (item?.duration ?? _status.duration);

    final prev = _status;
    PlaybackState state;
    switch (transportState) {
      case 'PLAYING':
        state = PlaybackState.playing;
      case 'PAUSED_PLAYBACK':
        state = PlaybackState.paused;
      case 'TRANSITIONING':
        state = PlaybackState.loading;
      case 'STOPPED':
        final endedNaturally = duration != null &&
            duration > Duration.zero &&
            (duration - prev.position).abs() <= const Duration(seconds: 5);
        final lostCurrent = item != null &&
            trackUri.isNotEmpty &&
            !_sameUrl(trackUri, item.url) &&
            prev.state == PlaybackState.playing;
        state = (endedNaturally || lostCurrent) ? PlaybackState.completed : PlaybackState.paused;
        if (state == PlaybackState.completed && prev.state == PlaybackState.completed) {
          // Already reported; nothing new.
          return;
        }
      default:
        state = prev.state;
    }

    _emit(PlaybackStatus(
      state: state,
      position: state == PlaybackState.completed ? (duration ?? position) : position,
      duration: duration,
      itemId: item?.id,
    ));
  }

  static bool _sameUrl(String a, Uri b) {
    final ua = Uri.tryParse(a);
    if (ua == null) return a == b.toString();
    // Sonos may rewrite the scheme (x-rincon-mp3radio://) for streams.
    return ua.host == b.host && ua.path == b.path && ua.query == b.query;
  }
}

/// Test hook: apply a synthetic poll result to a target without network.
extension SonosTargetTesting on SonosTarget {
  void debugApplyPoll({
    required String transportState,
    String? relTime,
    String? trackDuration,
    String trackUri = '',
  }) =>
      _applyPoll(
        transportState: transportState,
        relTime: relTime,
        trackDuration: trackDuration,
        trackUri: trackUri,
      );

  void debugSetItems({PlayItem? current, PlayItem? next}) {
    _current = current;
    _next = next;
    if (current != null) {
      _emit(PlaybackStatus(
        state: PlaybackState.playing,
        position: Duration.zero,
        duration: current.duration,
        itemId: current.id,
      ));
    }
  }
}
