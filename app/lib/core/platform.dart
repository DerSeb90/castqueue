import 'dart:io';

import 'package:flutter/services.dart';

import 'diagnostics.dart';

/// Small platform hooks implemented in `MainActivity.kt`.
class AppPlatform {
  static const _channel = MethodChannel('de.seifert.castqueue/platform');

  /// Android 13+: ask for POST_NOTIFICATIONS so the media notification with
  /// the lockscreen controls can be shown. Returns `true` when granted (or not
  /// needed on this OS).
  static Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final ok = await _channel.invokeMethod<bool>('requestNotificationPermission') ?? false;
      Diagnostics.log('notification permission: ${ok ? 'granted' : 'denied'}');
      return ok;
    } on PlatformException catch (e) {
      Diagnostics.log('notification permission: error $e');
      return false;
    } on MissingPluginException {
      Diagnostics.log('notification permission: channel missing');
      return false;
    }
  }
}
