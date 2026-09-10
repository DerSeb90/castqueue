import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/api_client.dart';
import '../core/local_store.dart';
import '../core/session.dart';

/// Overridden in `main.dart` with the real instances.
final sharedPrefsProvider = Provider<SharedPreferences>((ref) => throw UnimplementedError());
final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore(ref.watch(sharedPrefsProvider)));
final localStoreProvider = Provider<LocalStore>((ref) => throw UnimplementedError());
final initialSnapshotProvider = Provider<LibrarySnapshot?>((ref) => null);

// ------------------------------------------------------------------ session

class SessionNotifier extends Notifier<Session?> {
  @override
  Session? build() => ref.watch(sessionStoreProvider).load();

  Future<void> login(Session s) async {
    await ref.read(sessionStoreProvider).save(s);
    state = s;
  }

  Future<void> setStreamToken(String token) async {
    final s = state;
    if (s == null) return;
    final n = s.copyWith(streamToken: token);
    await ref.read(sessionStoreProvider).save(n);
    state = n;
  }

  /// Local logout; call [ApiClient.logout] before if the server should revoke.
  Future<void> clear() async {
    await ref.read(sessionStoreProvider).clear();
    await ref.read(localStoreProvider).clear();
    state = null;
  }
}

final sessionProvider = NotifierProvider<SessionNotifier, Session?>(SessionNotifier.new);

final apiClientProvider = Provider<ApiClient?>((ref) {
  final s = ref.watch(sessionProvider);
  if (s == null) return null;
  final c = ApiClient(s.baseUrl, s.token);
  ref.onDispose(c.close);
  return c;
});

// ---------------------------------------------------------------- app prefs

class AppPrefs {
  const AppPrefs({
    this.themeMode = ThemeMode.dark,
    this.defaultSpeed = 1.0,
    this.localVolume = 1.0,
    this.sonosHosts = const [],
    this.autoDownload = false,
    this.autoDeleteDownloads = true,
    this.skipForwardSeconds = 30,
    this.skipBackSeconds = 10,
  });

  final ThemeMode themeMode;
  final double defaultSpeed;
  final double localVolume;
  final List<String> sonosHosts;
  final bool autoDownload;
  final bool autoDeleteDownloads;
  final int skipForwardSeconds;
  final int skipBackSeconds;

  AppPrefs copyWith({
    ThemeMode? themeMode,
    double? defaultSpeed,
    double? localVolume,
    List<String>? sonosHosts,
    bool? autoDownload,
    bool? autoDeleteDownloads,
    int? skipForwardSeconds,
    int? skipBackSeconds,
  }) =>
      AppPrefs(
        themeMode: themeMode ?? this.themeMode,
        defaultSpeed: defaultSpeed ?? this.defaultSpeed,
        localVolume: localVolume ?? this.localVolume,
        sonosHosts: sonosHosts ?? this.sonosHosts,
        autoDownload: autoDownload ?? this.autoDownload,
        autoDeleteDownloads: autoDeleteDownloads ?? this.autoDeleteDownloads,
        skipForwardSeconds: skipForwardSeconds ?? this.skipForwardSeconds,
        skipBackSeconds: skipBackSeconds ?? this.skipBackSeconds,
      );
}

class AppPrefsNotifier extends Notifier<AppPrefs> {
  static const _kTheme = 'prefs.theme';
  static const _kSpeed = 'prefs.speed';
  static const _kVolume = 'prefs.volume';
  static const _kSonos = 'prefs.sonos_hosts';
  static const _kAutoDl = 'prefs.auto_download';
  static const _kAutoDel = 'prefs.auto_delete_downloads';

  SharedPreferences get _p => ref.read(sharedPrefsProvider);

  @override
  AppPrefs build() {
    final p = ref.watch(sharedPrefsProvider);
    return AppPrefs(
      themeMode: switch (p.getString(_kTheme)) {
        'light' => ThemeMode.light,
        'system' => ThemeMode.system,
        _ => ThemeMode.dark,
      },
      defaultSpeed: p.getDouble(_kSpeed) ?? 1.0,
      localVolume: p.getDouble(_kVolume) ?? 1.0,
      sonosHosts: p.getStringList(_kSonos) ?? const [],
      autoDownload: p.getBool(_kAutoDl) ?? false,
      autoDeleteDownloads: p.getBool(_kAutoDel) ?? true,
    );
  }

  Future<void> setThemeMode(ThemeMode m) async {
    await _p.setString(_kTheme, m.name);
    state = state.copyWith(themeMode: m);
  }

  Future<void> setDefaultSpeed(double s) async {
    await _p.setDouble(_kSpeed, s);
    state = state.copyWith(defaultSpeed: s);
  }

  Future<void> setLocalVolume(double v) async {
    await _p.setDouble(_kVolume, v);
    state = state.copyWith(localVolume: v);
  }

  Future<void> addSonosHost(String host) async {
    if (host.isEmpty || state.sonosHosts.contains(host)) return;
    final l = [...state.sonosHosts, host];
    await _p.setStringList(_kSonos, l);
    state = state.copyWith(sonosHosts: l);
  }

  Future<void> removeSonosHost(String host) async {
    final l = state.sonosHosts.where((h) => h != host).toList();
    await _p.setStringList(_kSonos, l);
    state = state.copyWith(sonosHosts: l);
  }

  Future<void> setAutoDownload(bool v) async {
    await _p.setBool(_kAutoDl, v);
    state = state.copyWith(autoDownload: v);
  }

  Future<void> setAutoDeleteDownloads(bool v) async {
    await _p.setBool(_kAutoDel, v);
    state = state.copyWith(autoDeleteDownloads: v);
  }
}

final appPrefsProvider = NotifierProvider<AppPrefsNotifier, AppPrefs>(AppPrefsNotifier.new);
