import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/platform.dart';
import 'core/sync_service.dart';
import 'playback/playback_controller.dart';
import 'state/app_state.dart';
import 'ui/screens/login_screen.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

class CastQueueApp extends ConsumerStatefulWidget {
  const CastQueueApp({super.key});

  @override
  ConsumerState<CastQueueApp> createState() => _CastQueueAppState();
}

class _CastQueueAppState extends ConsumerState<CastQueueApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Keep the playback controller alive for the whole app lifetime.
    ref.listenManual(playbackControllerProvider, (_, _) {});
    if (ref.read(sessionProvider) != null) {
      Future.microtask(() => ref.read(syncServiceProvider).start());
    }
    // Media notification / lockscreen controls need this on Android 13+.
    WidgetsBinding.instance.addPostFrameCallback((_) => AppPlatform.requestNotificationPermission());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final sync = ref.read(syncServiceProvider);
    switch (state) {
      case AppLifecycleState.resumed:
        if (ref.read(sessionProvider) != null) sync.start();
        ref.read(playbackControllerProvider.notifier).onAppResumed();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        sync.stop();
        ref.read(playbackControllerProvider.notifier).onAppPaused();
      case AppLifecycleState.inactive:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final prefs = ref.watch(appPrefsProvider);
    ref.listen(sessionProvider, (prev, next) {
      final sync = ref.read(syncServiceProvider);
      if (next != null && prev == null) {
        sync.syncNow(full: true);
        sync.start();
      } else if (next == null) {
        sync.stop();
      }
    });
    return MaterialApp(
      title: 'CastQueue',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: prefs.themeMode,
      home: session == null ? const LoginScreen() : const AppShell(),
    );
  }
}
