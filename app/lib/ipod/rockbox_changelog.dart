/// Parser for Rockbox's `/.rockbox/database_changelog.txt`, written by
/// *Database → Export modifications*.
///
/// Format (apps/tagcache.c, `tagcache_create_changelog` / `write_tag`):
///
/// ```
/// ## Changelog version 1
/// artist="…" album="…" … filename="/Podcasts/X/y.mp3" … playcount="1" playtime="123456" lastplayed="17" … lastelapsed="0" lastoffset="0"
/// ```
///
/// One track per line, every tag as `key="value"`, `"` and `\` escaped with a
/// backslash and newlines written as `\n`. Only tracks whose runtime data was
/// modified on the player appear.
///
/// Semantics from apps/tagtree.c (`tagtree_track_finish_event`):
/// * `lastelapsed` / `lastoffset` are the resume point in ms / bytes. They are
///   **reset to 0** when a track ends by itself (auto skip), and left alone for
///   tracks stopped in the first 3 s.
/// * `playcount` increments on every listen of ≥ 15 s when *Gather Runtime
///   Data* is on — it does **not** mean "finished".
/// * `playtime` is the cumulative listened time in ms (last 15 s not counted).
library;

class ChangelogTrack {
  const ChangelogTrack({
    required this.filename,
    this.playcount = 0,
    this.playtime = 0,
    this.lastplayed = 0,
    this.lastelapsed = 0,
    this.lastoffset = 0,
    this.tags = const {},
  });

  final String filename;
  final int playcount;
  final int playtime;
  final int lastplayed;
  final int lastelapsed;
  final int lastoffset;
  final Map<String, String> tags;

  /// Heuristic "finished": ended by itself at least once (elapsed reset while
  /// playcount > 0), or the resume point / listened time is ≥ 95 % / 90 % of
  /// the known duration.
  bool isPlayed(int durationMs) {
    if (durationMs <= 0) return playcount > 0 && lastelapsed == 0;
    if (playcount > 0 && lastelapsed == 0) return true;
    if (lastelapsed >= durationMs * 0.95) return true;
    if (playtime >= durationMs * 0.9 && playcount > 0) return true;
    return false;
  }
}

class RockboxChangelog {
  RockboxChangelog._();

  static final _pair = RegExp(r'(\w+)="((?:[^"\\]|\\.)*)"');

  static List<ChangelogTrack> parse(String text) {
    final out = <ChangelogTrack>[];
    for (final rawLine in text.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final tags = <String, String>{};
      for (final m in _pair.allMatches(line)) {
        tags[m.group(1)!] = _unescape(m.group(2)!);
      }
      final filename = tags['filename'];
      if (filename == null || filename.isEmpty) continue;
      out.add(ChangelogTrack(
        filename: filename,
        playcount: _int(tags['playcount']),
        playtime: _int(tags['playtime']),
        lastplayed: _int(tags['lastplayed']),
        lastelapsed: _int(tags['lastelapsed']),
        lastoffset: _int(tags['lastoffset']),
        tags: tags,
      ));
    }
    return out;
  }

  static int _int(String? s) => s == null ? 0 : (int.tryParse(s.trim()) ?? 0);

  static String _unescape(String s) {
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c == '\\' && i + 1 < s.length) {
        final n = s[i + 1];
        b.write(n == 'n' ? '\n' : n);
        i++;
      } else {
        b.write(c);
      }
    }
    return b.toString();
  }

  /// Normalises a Rockbox path for matching: forward slashes, leading slash,
  /// case-insensitive (FAT32).
  static String normalize(String p) {
    var s = p.replaceAll('\\', '/');
    if (!s.startsWith('/')) s = '/$s';
    return s.toLowerCase();
  }
}
