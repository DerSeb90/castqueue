import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

/// In-app log for things that are otherwise only visible in logcat
/// (audio_service errors, notification permission, Sonos poll failures).
/// Shown under Einstellungen → Diagnose so problems can be reported from the
/// phone without a USB cable.
class Diagnostics extends ChangeNotifier {
  Diagnostics._();
  static final instance = Diagnostics._();

  static const _max = 200;
  static final _fmt = DateFormat('HH:mm:ss');
  final List<String> _lines = [];

  List<String> get lines => List.unmodifiable(_lines);

  static void log(String message) => instance._add(message);

  void _add(String message) {
    final line = '${_fmt.format(DateTime.now())}  $message';
    debugPrint('[castqueue] $line');
    _lines.add(line);
    if (_lines.length > _max) _lines.removeRange(0, _lines.length - _max);
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }
}
