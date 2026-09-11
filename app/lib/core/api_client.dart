import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.statusCode, this.message, {this.code = ''});
  final int statusCode;
  final String message;
  final String code;

  @override
  String toString() => message;
}

class UnauthorizedException extends ApiException {
  UnauthorizedException([String message = 'Nicht angemeldet'])
      : super(401, message, code: 'unauthorized');
}

/// `PUT /api/queue` version mismatch; carries the server's current queue.
/// 409 from `/api/playback/heartbeat`: another device is playing.
class PlaybackConflictException extends ApiException {
  PlaybackConflictException(this.lock)
      : super(409, 'Wiedergabe läuft auf „${lock.deviceName}“', code: 'playback_conflict');
  final PlaybackLock lock;
}

class QueueConflictException extends ApiException {
  QueueConflictException(this.current) : super(409, 'Warteschlange wurde woanders geändert', code: 'conflict');
  final QueueState current;
}

/// Typed client for the CastQueue API (see docs/API.md).
class ApiClient {
  ApiClient(String baseUrl, this.token, {http.Client? client})
      : baseUrl = normalizeBaseUrl(baseUrl),
        _client = client ?? http.Client();

  final String baseUrl;
  final String token;
  final http.Client _client;

  static const _timeout = Duration(seconds: 30);
  static const _longTimeout = Duration(seconds: 120);

  static String normalizeBaseUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) return u;
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Map<String, String> get _headers => {
        'Accept': 'application/json',
        if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      };

  Future<dynamic> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    String contentType = 'application/json',
    Duration? timeout,
    bool raw = false,
  }) async {
    final req = http.Request(method, _uri(path, query));
    req.headers.addAll(_headers);
    if (body != null) {
      req.headers['Content-Type'] = contentType;
      req.body = body is String ? body : jsonEncode(body);
    }
    http.Response res;
    try {
      final streamed = await _client.send(req).timeout(timeout ?? _timeout);
      res = await http.Response.fromStream(streamed).timeout(timeout ?? _timeout);
    } on TimeoutException {
      throw ApiException(0, 'Zeitüberschreitung beim Server', code: 'timeout');
    } on SocketException catch (e) {
      throw ApiException(0, 'Server nicht erreichbar (${e.message})', code: 'network');
    } on http.ClientException catch (e) {
      throw ApiException(0, 'Verbindungsfehler: ${e.message}', code: 'network');
    }
    if (res.statusCode == 401) {
      throw UnauthorizedException(_errorMessage(res) ?? 'Nicht angemeldet');
    }
    if (res.statusCode == 409 && path == '/api/playback/heartbeat') {
      final j = _decode(res) as Map<String, dynamic>;
      throw PlaybackConflictException(PlaybackLock.fromJson((j['playback'] as Map<String, dynamic>?) ?? const {}));
    }
    if (res.statusCode == 409 && path == '/api/queue') {
      throw QueueConflictException(QueueState.fromJson(_decode(res) as Map<String, dynamic>));
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(
        res.statusCode,
        _errorMessage(res) ?? 'HTTP ${res.statusCode}',
        code: _errorCode(res),
      );
    }
    if (raw) return utf8.decode(res.bodyBytes);
    if (res.statusCode == 204 || res.bodyBytes.isEmpty) return null;
    return _decode(res);
  }

  dynamic _decode(http.Response res) {
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      throw ApiException(res.statusCode, 'Ungültige Antwort vom Server', code: 'bad_response');
    }
  }

  String? _errorMessage(http.Response res) {
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is Map && j['error'] is String) return j['error'] as String;
    } catch (_) {}
    return null;
  }

  String _errorCode(http.Response res) {
    try {
      final j = jsonDecode(utf8.decode(res.bodyBytes));
      if (j is Map && j['code'] is String) return j['code'] as String;
    } catch (_) {}
    return '';
  }

  List<Map<String, dynamic>> _list(dynamic v) =>
      [for (final e in (v as List? ?? const [])) e as Map<String, dynamic>];

  // ---------------------------------------------------------------- auth

  /// Login does not need an existing token; use a throwaway client.
  static Future<LoginResponse> login({
    required String baseUrl,
    required String username,
    required String password,
    required String deviceName,
  }) async {
    final c = ApiClient(baseUrl, '');
    try {
      final j = await c._send('POST', '/api/auth/login', body: {
        'username': username,
        'password': password,
        'device_name': deviceName,
      });
      return LoginResponse.fromJson(j as Map<String, dynamic>);
    } finally {
      c.close();
    }
  }

  Future<void> logout() => _send('POST', '/api/auth/logout');

  Future<MeInfo> me() async => MeInfo.fromJson(await _send('GET', '/api/me') as Map<String, dynamic>);

  Future<List<DeviceInfo>> devices() async =>
      [for (final d in _list(await _send('GET', '/api/devices'))) DeviceInfo.fromJson(d)];

  Future<void> deleteDevice(String id) => _send('DELETE', '/api/devices/$id');

  Future<String> rotateStreamToken() async {
    final j = await _send('POST', '/api/stream-token/rotate') as Map<String, dynamic>;
    return j['stream_token'] as String? ?? '';
  }

  Future<bool> health() async {
    final j = await _send('GET', '/api/health', timeout: const Duration(seconds: 10));
    return j is Map && j['ok'] == true;
  }

  // ------------------------------------------------------------ podcasts

  Future<List<Podcast>> podcasts() async =>
      [for (final p in _list(await _send('GET', '/api/podcasts'))) Podcast.fromJson(p)];

  Future<Podcast> addPodcast({
    required String feedUrl,
    String authUsername = '',
    String authPassword = '',
    bool? autoEnqueue,
  }) async {
    final j = await _send(
      'POST',
      '/api/podcasts',
      body: {
        'feed_url': feedUrl,
        'auth_username': authUsername,
        'auth_password': authPassword,
        'auto_enqueue': ?autoEnqueue,
      },
      timeout: _longTimeout,
    );
    return Podcast.fromJson(j as Map<String, dynamic>);
  }

  Future<Podcast> podcast(String id) async =>
      Podcast.fromJson(await _send('GET', '/api/podcasts/$id') as Map<String, dynamic>);

  Future<Podcast> updatePodcast(
    String id, {
    bool? autoEnqueue,
    String? authUsername,
    String? authPassword,
    String? title,
  }) async {
    final j = await _send('PATCH', '/api/podcasts/$id', body: {
      'auto_enqueue': ?autoEnqueue,
      'auth_username': ?authUsername,
      'auth_password': ?authPassword,
      'title': ?title,
    });
    return Podcast.fromJson(j as Map<String, dynamic>);
  }

  Future<void> deletePodcast(String id) => _send('DELETE', '/api/podcasts/$id');

  Future<Podcast> refreshPodcast(String id) async => Podcast.fromJson(
      await _send('POST', '/api/podcasts/$id/refresh', timeout: _longTimeout) as Map<String, dynamic>);

  Future<RefreshResult> refreshAll() async => RefreshResult.fromJson(
      await _send('POST', '/api/podcasts/refresh', timeout: _longTimeout) as Map<String, dynamic>);

  Future<List<Episode>> podcastEpisodes(String id, {int limit = 50, int offset = 0}) async => [
        for (final e in _list(await _send('GET', '/api/podcasts/$id/episodes',
            query: {'limit': '$limit', 'offset': '$offset'})))
          Episode.fromJson(e)
      ];

  Future<List<SearchResult>> search(String q) async => [
        for (final r in _list(await _send('GET', '/api/search', query: {'q': q}))) SearchResult.fromJson(r)
      ];

  Future<String> exportOpml() async => await _send('GET', '/api/opml', raw: true) as String;

  Future<OpmlImportResult> importOpml(String xml) async => OpmlImportResult.fromJson(
      await _send('POST', '/api/opml', body: xml, contentType: 'text/xml', timeout: _longTimeout)
          as Map<String, dynamic>);

  // ------------------------------------------------------------ episodes

  Future<List<Episode>> episodes({DateTime? since, int limit = 100}) async => [
        for (final e in _list(await _send('GET', '/api/episodes', query: {
          if (since != null) 'since': since.toUtc().toIso8601String(),
          'limit': '$limit',
        })))
          Episode.fromJson(e)
      ];

  Future<Episode> episode(String id) async =>
      Episode.fromJson(await _send('GET', '/api/episodes/$id') as Map<String, dynamic>);

  Future<Episode> updateProgress(ProgressUpdate u) async => Episode.fromJson(
      await _send('PUT', '/api/episodes/${u.episodeId}/progress', body: u.toJson()) as Map<String, dynamic>);

  Future<List<Episode>> progressBatch(List<ProgressUpdate> items) async {
    final j = await _send('POST', '/api/progress/batch', body: {
      'items': [for (final u in items) u.toJson(withId: true)],
    }) as Map<String, dynamic>;
    return [for (final e in _list(j['episodes'])) Episode.fromJson(e)];
  }

  // --------------------------------------------------------------- queue

  Future<QueueState> queue() async =>
      QueueState.fromJson(await _send('GET', '/api/queue') as Map<String, dynamic>);

  /// Throws [QueueConflictException] on version mismatch.
  Future<QueueState> replaceQueue(int version, List<String> episodeIds) async => QueueState.fromJson(
      await _send('PUT', '/api/queue', body: {'version': version, 'episode_ids': episodeIds})
          as Map<String, dynamic>);

  /// [position] is `'front'`, `'back'` or an int index.
  Future<QueueState> enqueue(String episodeId, {Object position = 'back'}) async => QueueState.fromJson(
      await _send('POST', '/api/queue/items', body: {'episode_id': episodeId, 'position': position})
          as Map<String, dynamic>);

  Future<QueueState> dequeue(String episodeId) async =>
      QueueState.fromJson(await _send('DELETE', '/api/queue/items/$episodeId') as Map<String, dynamic>);

  Future<QueueState> moveInQueue(String episodeId, int to) async => QueueState.fromJson(
      await _send('POST', '/api/queue/move', body: {'episode_id': episodeId, 'to': to}) as Map<String, dynamic>);

  Future<QueueState> clearQueue() async =>
      QueueState.fromJson(await _send('DELETE', '/api/queue') as Map<String, dynamic>);

  // ---------------------------------------------------------------- sync

  // ------------------------------------------------------------ playback lock

  Future<PlaybackLock> playbackClaim(String episodeId, String target) async => PlaybackLock.fromJson(
      await _send('POST', '/api/playback/claim', body: {'episode_id': episodeId, 'target': target}) as Map<String, dynamic>);

  /// Throws [PlaybackConflictException] when another device holds the lock.
  Future<PlaybackLock> playbackHeartbeat(String episodeId, String target) async => PlaybackLock.fromJson(
      await _send('POST', '/api/playback/heartbeat', body: {'episode_id': episodeId, 'target': target})
          as Map<String, dynamic>);

  Future<void> playbackRelease() => _send('POST', '/api/playback/release');

  Future<SyncResponse> sync({DateTime? since}) async => SyncResponse.fromJson(await _send(
        'GET',
        '/api/sync',
        query: {if (since != null) 'since': since.toUtc().toIso8601String()},
        timeout: _longTimeout,
      ) as Map<String, dynamic>);

  // ------------------------------------------------------------ settings

  Future<Settings> settings() async =>
      Settings.fromJson(await _send('GET', '/api/settings') as Map<String, dynamic>);

  Future<Settings> updateSettings({
    bool? autoRemovePlayed,
    int? refreshIntervalMinutes,
    bool? autoEnqueueDefault,
  }) async =>
      Settings.fromJson(await _send('PUT', '/api/settings', body: {
        'auto_remove_played': ?autoRemovePlayed,
        'refresh_interval_minutes': ?refreshIntervalMinutes,
        'auto_enqueue_default': ?autoEnqueueDefault,
      }) as Map<String, dynamic>);

  void close() => _client.close();
}
