import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';

/// What to put on the player and how. Persisted as JSON in SharedPreferences.
class IpodSelection {
  const IpodSelection({
    this.includeQueue = true,
    this.perPodcastLatest = const {},
    this.embedCover = true,
    this.folderCover = true,
    this.writePlaylist = true,
    this.removePlayed = true,
    this.removeUnselected = false,
    this.manualRoot,
  });

  final bool includeQueue;

  /// podcastId → N newest unplayed episodes to keep on the device.
  final Map<String, int> perPodcastLatest;
  final bool embedCover;
  final bool folderCover;
  final bool writePlaylist;

  /// Delete files whose episode is marked played on the server.
  final bool removePlayed;

  /// Delete files that are no longer part of the selection.
  final bool removeUnselected;

  /// Manually chosen folder (test folder or a drive the scan missed).
  final String? manualRoot;

  IpodSelection copyWith({
    bool? includeQueue,
    Map<String, int>? perPodcastLatest,
    bool? embedCover,
    bool? folderCover,
    bool? writePlaylist,
    bool? removePlayed,
    bool? removeUnselected,
    String? manualRoot,
    bool clearManualRoot = false,
  }) =>
      IpodSelection(
        includeQueue: includeQueue ?? this.includeQueue,
        perPodcastLatest: perPodcastLatest ?? this.perPodcastLatest,
        embedCover: embedCover ?? this.embedCover,
        folderCover: folderCover ?? this.folderCover,
        writePlaylist: writePlaylist ?? this.writePlaylist,
        removePlayed: removePlayed ?? this.removePlayed,
        removeUnselected: removeUnselected ?? this.removeUnselected,
        manualRoot: clearManualRoot ? null : (manualRoot ?? this.manualRoot),
      );

  Map<String, dynamic> toJson() => {
        'include_queue': includeQueue,
        'per_podcast_latest': perPodcastLatest,
        'embed_cover': embedCover,
        'folder_cover': folderCover,
        'write_playlist': writePlaylist,
        'remove_played': removePlayed,
        'remove_unselected': removeUnselected,
        if (manualRoot != null) 'manual_root': manualRoot,
      };

  factory IpodSelection.fromJson(Map<String, dynamic> j) => IpodSelection(
        includeQueue: j['include_queue'] as bool? ?? true,
        perPodcastLatest: {
          for (final e in ((j['per_podcast_latest'] as Map?) ?? const {}).entries)
            if (e.value is num && (e.value as num) > 0) e.key.toString(): (e.value as num).toInt(),
        },
        embedCover: j['embed_cover'] as bool? ?? true,
        folderCover: j['folder_cover'] as bool? ?? true,
        writePlaylist: j['write_playlist'] as bool? ?? true,
        removePlayed: j['remove_played'] as bool? ?? true,
        removeUnselected: j['remove_unselected'] as bool? ?? false,
        manualRoot: j['manual_root'] as String?,
      );
}

class IpodSelectionNotifier extends Notifier<IpodSelection> {
  static const key = 'ipod_selection';

  SharedPreferences get _p => ref.read(sharedPrefsProvider);

  @override
  IpodSelection build() {
    final raw = ref.watch(sharedPrefsProvider).getString(key);
    if (raw == null) return const IpodSelection();
    try {
      return IpodSelection.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const IpodSelection();
    }
  }

  Future<void> update(IpodSelection s) async {
    state = s;
    await _p.setString(key, jsonEncode(s.toJson()));
  }

  Future<void> setPodcastLatest(String podcastId, int n) {
    final m = Map<String, int>.of(state.perPodcastLatest);
    if (n <= 0) {
      m.remove(podcastId);
    } else {
      m[podcastId] = n;
    }
    return update(state.copyWith(perPodcastLatest: m));
  }
}

final ipodSelectionProvider = NotifierProvider<IpodSelectionNotifier, IpodSelection>(IpodSelectionNotifier.new);
