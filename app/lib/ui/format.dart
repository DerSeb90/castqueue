import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

final _dateFmt = DateFormat('dd.MM.yyyy');
final _dateTimeFmt = DateFormat('dd.MM.yyyy HH:mm');

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return '$m:${s.toString().padLeft(2, '0')}';
}

/// "1 Std. 23 Min." style.
String formatDurationShort(Duration d) {
  if (d <= Duration.zero) return '';
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  if (h > 0) return m > 0 ? '$h Std. $m Min.' : '$h Std.';
  return '$m Min.';
}

String formatRemaining(Duration total, Duration position) {
  final r = total - position;
  if (r <= Duration.zero) return '';
  return '${formatDurationShort(r)} übrig';
}

String formatDate(DateTime? d) {
  if (d == null) return '';
  final local = d.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Heute';
  if (diff == 1) return 'Gestern';
  if (diff < 7) return 'vor $diff Tagen';
  return _dateFmt.format(local);
}

String formatDateTime(DateTime? d) => d == null ? '' : _dateTimeFmt.format(d.toLocal());

String formatBytes(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Strip HTML tags for one-line previews.
String htmlToPlain(String html) {
  var s = html
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'</p>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  s = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#8217;', '’')
      .replaceAll('&#8211;', '–');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final scheme = Theme.of(context).colorScheme;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: error ? scheme.errorContainer : null,
  ));
}

/// Run an async action and surface errors as a SnackBar.
Future<bool> guarded(BuildContext context, Future<void> Function() action, {String? success}) async {
  try {
    await action();
    if (success != null && context.mounted) showSnack(context, success);
    return true;
  } catch (e) {
    if (context.mounted) showSnack(context, e.toString(), error: true);
    return false;
  }
}
