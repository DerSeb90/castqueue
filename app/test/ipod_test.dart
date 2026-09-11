import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:castqueue/core/models.dart';
import 'package:castqueue/ipod/cover_art.dart';
import 'package:castqueue/ipod/id3_writer.dart';
import 'package:castqueue/ipod/ipod_manifest.dart';
import 'package:castqueue/ipod/ipod_selection.dart';
import 'package:castqueue/ipod/ipod_sync.dart';
import 'package:castqueue/ipod/rockbox_changelog.dart';
import 'package:castqueue/state/library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

Episode ep(
  String id, {
  String podcast = 'p1',
  String podcastTitle = 'Mein Podcast',
  String title = 'Folge',
  bool played = false,
  int size = 1000,
  DateTime? published,
  String mediaType = 'audio/mpeg',
  int episodeNumber = 0,
}) =>
    Episode(
      id: id,
      podcastId: podcast,
      podcastTitle: podcastTitle,
      title: title,
      played: played,
      mediaSize: size,
      mediaUrl: 'https://x/$id.mp3',
      streamUrl: 'https://x/$id.mp3',
      mediaType: mediaType,
      durationMs: 60000,
      publishedAt: published ?? DateTime.utc(2026, 1, 1),
      episodeNumber: episodeNumber,
    );

ManifestEntry entry(String id, {String podcast = 'p1', int size = 1000}) => ManifestEntry(
      episodeId: id,
      path: '/Podcasts/Mein Podcast/2026-01-01 - $id.mp3',
      podcastId: podcast,
      size: size,
      durationMs: 60000,
      addedAt: DateTime.utc(2026, 1, 2),
    );

void main() {
  group('Id3Writer', () {
    test('header, synchsafe size and frames', () {
      final tag = Id3Writer.buildTag(title: 'Hallo', artist: 'Pod', album: 'Pod', year: 2026, track: 7, comment: 'c');
      expect(tag.sublist(0, 5), [0x49, 0x44, 0x33, 3, 0]);
      final size = Id3Writer.unsynchsafe(tag, 6);
      expect(size, tag.length - 10);
      expect(Id3Writer.existingTagLength(tag), tag.length);
      final s = latin1.decode(tag, allowInvalid: true);
      for (final f in ['TIT2', 'TPE1', 'TALB', 'TCON', 'TYER', 'TRCK', 'COMM']) {
        expect(s.contains(f), isTrue, reason: f);
      }
      expect(s.contains('Hallo'), isTrue);
      expect(s.contains('Podcast'), isTrue);
      expect(s.contains('deu'), isTrue);
      // Latin-1 title → encoding byte 0 right after the TIT2 frame header.
      final i = s.indexOf('TIT2');
      expect(tag[i + 10], 0x00);
    });

    test('non-Latin-1 text uses UTF-16 with BOM', () {
      final tag = Id3Writer.buildTag(title: 'Folge – „Test“ 😀', artist: 'A', album: 'B');
      final s = latin1.decode(tag, allowInvalid: true);
      final i = s.indexOf('TIT2');
      expect(tag[i + 10], 0x01);
      expect(tag[i + 11], 0xFF);
      expect(tag[i + 12], 0xFE);
    });

    test('APIC frame carries the jpeg', () {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]);
      final tag = Id3Writer.buildTag(title: 't', artist: 'a', album: 'b', coverJpeg: jpeg);
      final s = latin1.decode(tag, allowInvalid: true);
      final i = s.indexOf('APIC');
      expect(i, greaterThan(0));
      expect(s.substring(i + 11, i + 21), 'image/jpeg');
      expect(tag[i + 22], 0x03);
      expect(tag.sublist(i + 24, i + 24 + jpeg.length), jpeg);
    });

    test('existingTagLength handles no tag, footer flag and garbage', () {
      expect(Id3Writer.existingTagLength([0xFF, 0xFB, 0, 0, 0, 0, 0, 0, 0, 0]), 0);
      expect(Id3Writer.existingTagLength([0x49, 0x44, 0x33, 4, 0, 0x10, 0, 0, 0, 5]), 10 + 5 + 10);
      expect(Id3Writer.existingTagLength([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0x80, 0]), 0);
      expect(Id3Writer.existingTagLength([0x49, 0x44]), 0);
    });

    test('writeTaggedCopy strips the old tag and prepends the new one', () async {
      final dir = await Directory.systemTemp.createTemp('cq_id3_');
      try {
        final old = Id3Writer.buildTag(title: 'old', artist: 'o', album: 'o');
        final audio = List<int>.generate(500, (i) => i % 251);
        final src = File('${dir.path}/src.mp3')..writeAsBytesSync([...old, ...audio]);
        final dst = File('${dir.path}/dst.mp3');
        final tag = Id3Writer.buildTag(title: 'new', artist: 'n', album: 'n');
        await Id3Writer.writeTaggedCopy(src, dst, tag);
        final out = dst.readAsBytesSync();
        expect(out.length, tag.length + audio.length);
        expect(out.sublist(0, tag.length), tag);
        expect(out.sublist(tag.length), audio);
        expect(latin1.decode(out, allowInvalid: true).contains('old'), isFalse);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('CoverArt', () {
    test('converts to square baseline jpeg of the requested size', () {
      final src = img.Image(width: 300, height: 120);
      img.fill(src, color: img.ColorRgb8(200, 50, 50));
      final png = Uint8List.fromList(img.encodePng(src));
      final out = CoverArt(size: 64).convert(png);
      expect(out, isNotNull);
      expect(out!.sublist(0, 2), [0xFF, 0xD8]);
      final back = img.decodeJpg(out)!;
      expect(back.width, 64);
      expect(back.height, 64);
      // Baseline: SOF0 marker present, SOF2 (progressive) absent.
      var sof0 = false, sof2 = false;
      for (var i = 0; i < out.length - 1; i++) {
        if (out[i] == 0xFF && out[i + 1] == 0xC0) sof0 = true;
        if (out[i] == 0xFF && out[i + 1] == 0xC2) sof2 = true;
      }
      expect(sof0, isTrue);
      expect(sof2, isFalse);
    });

    test('garbage yields null', () {
      expect(CoverArt().convert(Uint8List.fromList([1, 2, 3])), isNull);
    });
  });

  group('IpodManifest', () {
    test('round-trips and drops entries whose file is gone', () async {
      final dir = await Directory.systemTemp.createTemp('cq_manifest_');
      try {
        final root = dir.path;
        String resolve(String p) => '$root${Platform.pathSeparator}${p.substring(1).replaceAll('/', Platform.pathSeparator)}';
        final m = IpodManifest(IpodManifest.fileFor(root));
        m.entries['a'] = entry('a');
        m.entries['b'] = entry('b');
        await m.save();
        expect(IpodManifest.fileFor(root).existsSync(), isTrue);
        // only a's file exists
        final fa = File(resolve(m.entries['a']!.path));
        fa.parent.createSync(recursive: true);
        fa.writeAsBytesSync([1, 2, 3]);
        final loaded = await IpodManifest.load(IpodManifest.fileFor(root), resolve);
        expect(loaded.entries.keys, ['a']);
        expect(loaded.entries['a']!.path, m.entries['a']!.path);
        expect(loaded.entries['a']!.size, 1000);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('corrupt or missing file is an empty manifest', () async {
      final dir = await Directory.systemTemp.createTemp('cq_manifest2_');
      try {
        final f = IpodManifest.fileFor(dir.path);
        expect((await IpodManifest.load(f, (p) => p)).entries, isEmpty);
        f.parent.createSync(recursive: true);
        f.writeAsStringSync('{not json');
        expect((await IpodManifest.load(f, (p) => p)).entries, isEmpty);
        expect(IpodManifest.parse(f, '{"version":1,"entries":{"x":{"path":""}}}').entries, isEmpty);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('names and paths', () {
    test('sanitizeName strips FAT32-illegal characters', () {
      expect(sanitizeName(' Folge 3: "Was?" <a/b> | c*  '), 'Folge 3 Was a b c');
      expect(sanitizeName('...'), 'Unbenannt');
      expect(sanitizeName('x' * 100, max: 10).length, 10);
      expect(sanitizeName('ends with dot.'), 'ends with dot');
    });

    test('extensionFor prefers media type, then url, default mp3', () {
      expect(extensionFor('audio/mpeg', ''), '.mp3');
      expect(extensionFor('audio/mp4', ''), '.m4a');
      expect(extensionFor('audio/x-m4a', ''), '.m4a');
      expect(extensionFor('audio/ogg', ''), '.ogg');
      expect(extensionFor('audio/opus', ''), '.opus');
      expect(extensionFor('', 'https://h/x/y.FLAC?x=1'), '.flac');
      expect(extensionFor('application/octet-stream', 'https://h/y'), '.mp3');
    });

    test('targetPathFor builds /Podcasts/<podcast>/<date> - <title>.<ext>', () {
      final e = ep('e1', title: 'Titel: Teil 1/2', published: DateTime.utc(2026, 3, 4, 12));
      expect(targetPathFor(e), startsWith('/Podcasts/Mein Podcast/2026-03-04 - Titel Teil 1 2.mp3'));
    });
  });

  group('computePlan', () {
    LibraryState lib(List<Episode> eps, List<String> queue, {List<String> podcasts = const ['p1']}) => LibraryState(
          podcasts: {for (final p in podcasts) p: Podcast(id: p, title: p, feedUrl: 'https://f/$p')},
          episodes: {for (final e in eps) e.id: e},
          queueIds: queue,
        );

    test('queue → copy, on device → keep, played → delete', () {
      final l = lib([ep('a'), ep('b'), ep('c', played: true)], ['a', 'b', 'c']);
      final m = IpodManifest(File('x'))..entries.addAll({'b': entry('b'), 'c': entry('c')});
      final plan = computePlan(lib: l, manifest: m, sel: const IpodSelection());
      expect(plan.copy.map((i) => i.episodeId), ['a']);
      expect(plan.keep.map((i) => i.episodeId), ['b']);
      expect(plan.delete.map((i) => i.episodeId), ['c']);
      expect(plan.delete.first.reason, 'gehört');
      expect(plan.order, ['a', 'b']);
      expect(plan.bytesToCopy, 1000);
    });

    test('per-podcast latest N picks newest unplayed, no duplicates with queue', () {
      final l = lib([
        ep('old', published: DateTime.utc(2025, 1, 1)),
        ep('mid', published: DateTime.utc(2025, 6, 1)),
        ep('new', published: DateTime.utc(2026, 1, 1)),
        ep('done', published: DateTime.utc(2026, 2, 1), played: true),
      ], [
        'mid'
      ]);
      final plan = computePlan(
        lib: l,
        manifest: IpodManifest(File('x')),
        sel: const IpodSelection(perPodcastLatest: {'p1': 2}),
      );
      expect(plan.order, ['mid', 'new']);
      expect(plan.copy.length, 2);
    });

    test('unselected stays unless removeUnselected; unknown episodes are deleted', () {
      final l = lib([ep('a')], []);
      final m = IpodManifest(File('x'))..entries.addAll({'a': entry('a'), 'gone': entry('gone')});
      var plan = computePlan(lib: l, manifest: m, sel: const IpodSelection());
      expect(plan.keep.map((i) => i.episodeId), ['a']);
      expect(plan.delete.map((i) => i.episodeId), ['gone']);
      plan = computePlan(lib: l, manifest: m, sel: const IpodSelection(removeUnselected: true));
      expect(plan.delete.map((i) => i.episodeId).toSet(), {'a', 'gone'});
    });
  });

  test('buildM3u8', () {
    final entries = {'a': entry('a'), 'b': entry('b')};
    final eps = {'a': ep('a', title: 'Erste'), 'b': ep('b', title: 'Zweite')};
    final out = buildM3u8(order: ['b', 'missing', 'a'], entries: entries, episodes: eps);
    expect(out, '#EXTM3U\n'
        '#EXTINF:60,Mein Podcast - Zweite\n/Podcasts/Mein Podcast/2026-01-01 - b.mp3\n'
        '#EXTINF:60,Mein Podcast - Erste\n/Podcasts/Mein Podcast/2026-01-01 - a.mp3\n');
  });

  group('RockboxChangelog', () {
    const sample = '## Changelog version 1\n'
        'artist="Mein Podcast" album="Mein Podcast" genre="Podcast" title="Folge \\"eins\\"" '
        'filename="/Podcasts/Mein Podcast/2026-01-01 - a.mp3" composer="" comment="Zeile\\nzwei" '
        'year="2026" playcount="1" rating="0" playtime="55000" lastplayed="12" commitid="3" mtime="0" '
        'lastelapsed="0" lastoffset="0" \n'
        'title="Halb" filename="/Podcasts/Mein Podcast/2026-01-01 - b.mp3" playcount="1" playtime="20000" '
        'lastelapsed="30000" lastoffset="480000" \n'
        '\n'
        'garbage line without filename\n';

    test('parses lines, unescapes, ignores header and junk', () {
      final t = RockboxChangelog.parse(sample);
      expect(t.length, 2);
      expect(t[0].filename, '/Podcasts/Mein Podcast/2026-01-01 - a.mp3');
      expect(t[0].tags['title'], 'Folge "eins"');
      expect(t[0].tags['comment'], 'Zeile\nzwei');
      expect(t[0].playcount, 1);
      expect(t[0].playtime, 55000);
      expect(t[0].lastelapsed, 0);
      expect(t[1].lastelapsed, 30000);
      expect(t[1].lastoffset, 480000);
    });

    test('played heuristic', () {
      final t = RockboxChangelog.parse(sample);
      expect(t[0].isPlayed(60000), isTrue); // finished: playcount>0, elapsed reset
      expect(t[1].isPlayed(60000), isFalse); // stopped halfway
      expect(const ChangelogTrack(filename: 'x', playcount: 0, lastelapsed: 58000).isPlayed(60000), isTrue);
      expect(const ChangelogTrack(filename: 'x', playcount: 2, playtime: 59000, lastelapsed: 100).isPlayed(60000), isTrue);
      expect(const ChangelogTrack(filename: 'x', playcount: 0, lastelapsed: 0).isPlayed(60000), isFalse);
    });

    test('normalize matches case-insensitively with either slash', () {
      expect(RockboxChangelog.normalize(r'Podcasts\A\B.MP3'), '/podcasts/a/b.mp3');
    });
  });

  test('IpodSelection json round-trip', () {
    const s = IpodSelection(perPodcastLatest: {'p1': 3}, removeUnselected: true, manualRoot: r'D:\ipod');
    final back = IpodSelection.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(back.perPodcastLatest, {'p1': 3});
    expect(back.removeUnselected, isTrue);
    expect(back.manualRoot, r'D:\ipod');
    expect(back.includeQueue, isTrue);
  });
}
