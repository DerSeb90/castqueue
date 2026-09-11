import 'dart:io';

import 'package:flutter/services.dart';

/// Small platform hooks implemented in `MainActivity.kt`.
class AppPlatform {
  static const _channel = MethodChannel('de.seifert.castqueue/platform');

  /// Android 13+: ask for POST_NOTIFICATIONS so the media notification with
  /// the lockscreen controls can be shown. Returns `true` when granted (or not
  /// needed on this OS).
  static Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _channel.invokeMethod<bool>('requestNotificationPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
