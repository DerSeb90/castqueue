import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/diagnostics.dart';
import 'core/local_store.dart';
import 'playback/audio_handler.dart';
import 'state/app_state.dart';
import 'state/library.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    JustAudioMediaKit.title = 'CastQueue';
    JustAudioMediaKit.ensureInitialized();
  }

  final prefs = await SharedPreferences.getInstance();
  final store = await LocalStore.open();
  final snapshot = await store.loadLibrary();

  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      localStoreProvider.overrideWithValue(store),
      initialSnapshotProvider.overrideWithValue(snapshot),
    ],
  );
  // Eagerly build the library so screens render from cache immediately.
  container.read(libraryProvider);

  if (Platform.isAndroid) {
    AudioService.asyncError.listen((e) => Diagnostics.log('audio_service: $e'));
    try {
      await AudioService.init(
        builder: () => CastQueueAudioHandler(container),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'de.seifert.castqueue.audio',
          androidNotificationChannelName: 'Wiedergabe',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          androidNotificationIcon: 'drawable/ic_launcher_monochrome',
        ),
      );
      Diagnostics.log('audio_service: init ok');
    } catch (e) {
      // Without the media session the app still works, just without
      // notification / lockscreen controls.
      Diagnostics.log('audio_service: init failed: $e');
    }
  }

  runApp(UncontrolledProviderScope(container: container, child: const CastQueueApp()));
}
