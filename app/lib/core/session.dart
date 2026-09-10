import 'package:shared_preferences/shared_preferences.dart';

/// Logged-in state: server + device token. Persisted in SharedPreferences.
class Session {
  const Session({
    required this.baseUrl,
    required this.token,
    required this.deviceId,
    required this.streamToken,
    this.username = '',
    this.deviceName = '',
  });

  final String baseUrl;
  final String token;
  final String deviceId;
  final String streamToken;
  final String username;
  final String deviceName;

  Session copyWith({String? streamToken}) => Session(
        baseUrl: baseUrl,
        token: token,
        deviceId: deviceId,
        streamToken: streamToken ?? this.streamToken,
        username: username,
        deviceName: deviceName,
      );
}

class SessionStore {
  SessionStore(this._prefs);
  final SharedPreferences _prefs;

  static const _kBaseUrl = 'session.base_url';
  static const _kToken = 'session.token';
  static const _kDeviceId = 'session.device_id';
  static const _kStreamToken = 'session.stream_token';
  static const _kUsername = 'session.username';
  static const _kDeviceName = 'session.device_name';

  /// Last used server URL (kept after logout to prefill the login form).
  String get lastBaseUrl => _prefs.getString(_kBaseUrl) ?? '';
  String get lastUsername => _prefs.getString(_kUsername) ?? '';

  Session? load() {
    final base = _prefs.getString(_kBaseUrl);
    final token = _prefs.getString(_kToken);
    if (base == null || base.isEmpty || token == null || token.isEmpty) return null;
    return Session(
      baseUrl: base,
      token: token,
      deviceId: _prefs.getString(_kDeviceId) ?? '',
      streamToken: _prefs.getString(_kStreamToken) ?? '',
      username: _prefs.getString(_kUsername) ?? '',
      deviceName: _prefs.getString(_kDeviceName) ?? '',
    );
  }

  Future<void> save(Session s) async {
    await _prefs.setString(_kBaseUrl, s.baseUrl);
    await _prefs.setString(_kToken, s.token);
    await _prefs.setString(_kDeviceId, s.deviceId);
    await _prefs.setString(_kStreamToken, s.streamToken);
    await _prefs.setString(_kUsername, s.username);
    await _prefs.setString(_kDeviceName, s.deviceName);
  }

  /// Keeps base URL and username for the next login.
  Future<void> clear() async {
    await _prefs.remove(_kToken);
    await _prefs.remove(_kDeviceId);
    await _prefs.remove(_kStreamToken);
  }
}
