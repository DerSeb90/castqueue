import 'dart:io';

/// Whether the iPod/Rockbox sync is available (Windows desktop only).
bool get ipodSupported => Platform.isWindows;

/// A mounted Rockbox player: a drive (or any folder) with a `.rockbox` dir.
class RockboxDevice {
  const RockboxDevice({
    required this.root,
    required this.label,
    this.version = '',
    this.freeBytes,
    this.totalBytes,
  });

  /// Root path without trailing separator, e.g. `E:` or `D:\fake-ipod`.
  final String root;
  final String label;
  final String version;
  final int? freeBytes;
  final int? totalBytes;

  Directory get rockboxDir => Directory('$root${Platform.pathSeparator}.rockbox');
  Directory get podcastsDir => Directory('$root${Platform.pathSeparator}Podcasts');
  Directory get playlistsDir => Directory('$root${Platform.pathSeparator}Playlists');
  File get changelogFile => File('${rockboxDir.path}${Platform.pathSeparator}database_changelog.txt');

  /// Absolute filesystem path for a Rockbox path like `/Podcasts/x/y.mp3`.
  String resolve(String rockboxPath) {
    final rel = rockboxPath.replaceFirst(RegExp(r'^/+'), '').replaceAll('/', Platform.pathSeparator);
    return '$root${Platform.pathSeparator}$rel';
  }

  static bool isRockboxRoot(String dir) => Directory('${_strip(dir)}${Platform.pathSeparator}.rockbox').existsSync();

  static String _strip(String p) {
    var s = p.trim();
    while (s.length > 2 && (s.endsWith('\\') || s.endsWith('/'))) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// All drive letters (except C:) whose root has a `.rockbox` folder.
  static Future<List<RockboxDevice>> scanDrives() async {
    if (!Platform.isWindows) return const [];
    final out = <RockboxDevice>[];
    for (var c = 'A'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
      final letter = String.fromCharCode(c);
      if (letter == 'C') continue;
      final root = '$letter:';
      try {
        if (!isRockboxRoot('$root\\')) continue;
        out.add(await fromPath(root, label: 'Laufwerk $root'));
      } catch (_) {
        // unreadable drive (e.g. empty card reader) – skip
      }
    }
    return out;
  }

  /// Builds a device for a folder. Throws [ArgumentError] when `.rockbox` is
  /// missing so test folders must be set up like a real player.
  static Future<RockboxDevice> fromPath(String dir, {String? label}) async {
    final root = _strip(dir);
    if (!isRockboxRoot(root)) {
      throw ArgumentError('Kein Rockbox-Gerät: „$root\\.rockbox“ fehlt.');
    }
    final version = await _readVersion(root);
    final space = await _diskSpace(root);
    return RockboxDevice(
      root: root,
      label: label ?? root,
      version: version,
      freeBytes: space?.$1,
      totalBytes: space?.$2,
    );
  }

  static Future<String> _readVersion(String root) async {
    try {
      final f = File('$root${Platform.pathSeparator}.rockbox${Platform.pathSeparator}rockbox-info.txt');
      if (!await f.exists()) return '';
      for (final line in await f.readAsLines()) {
        final m = RegExp(r'^\s*Version:\s*(.+)$').firstMatch(line);
        if (m != null) return m.group(1)!.trim();
      }
    } catch (_) {}
    return '';
  }

  /// (free, total) via PowerShell; null when the volume can't be queried
  /// (e.g. a plain folder on C: still reports C:'s numbers, which is fine).
  static Future<(int, int)?> _diskSpace(String root) async {
    if (!Platform.isWindows) return null;
    final m = RegExp(r'^([A-Za-z]):').firstMatch(root);
    if (m == null) return null;
    final letter = m.group(1)!.toUpperCase();
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '\$d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID=\'$letter:\'"; "\$(\$d.FreeSpace);\$(\$d.Size)"',
      ]).timeout(const Duration(seconds: 15));
      final parts = (r.stdout as String).trim().split(';');
      if (parts.length != 2) return null;
      final free = int.tryParse(parts[0].trim());
      final total = int.tryParse(parts[1].trim());
      if (free == null || total == null) return null;
      return (free, total);
    } catch (_) {
      return null;
    }
  }
}
