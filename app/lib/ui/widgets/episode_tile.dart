import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../downloads/download_manager.dart';
import '../../playback/playback_controller.dart';
import '../../state/library.dart';
import '../format.dart';
import '../screens/episode_screen.dart';
import 'artwork.dart';

/// Shared episode actions (menu + helpers).
class EpisodeActions {
  static Future<void> play(BuildContext context, WidgetRef ref, Episode e) =>
      guarded(context, () => ref.read(playbackControllerProvider.notifier).playEpisode(e));

  static Future<void> enqueue(BuildContext context, WidgetRef ref, Episode e, {bool front = false}) => guarded(
        context,
        () => ref.read(libraryProvider.notifier).enqueue(e, position: front ? 'front' : 'back'),
        success: front ? 'Als Nächstes eingereiht' : 'Zur Warteschlange hinzugefügt',
      );

  static Future<void> dequeue(BuildContext context, WidgetRef ref, Episode e) =>
      guarded(context, () => ref.read(libraryProvider.notifier).dequeue(e.id));

  static Future<void> markPlayed(BuildContext context, WidgetRef ref, Episode e, {bool played = true}) async {
    final ctl = ref.read(playbackControllerProvider);
    if (played && ctl.episode?.id == e.id && ctl.hasItem) {
      await ref.read(playbackControllerProvider.notifier).next();
      return;
    }
    await guarded(context, () => ref.read(libraryProvider.notifier).markPlayed(e, played: played));
  }

  static void openDetails(BuildContext context, Episode e) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EpisodeScreen(episodeId: e.id)));
  }

  static List<PopupMenuEntry<String>> menuItems(WidgetRef ref, Episode e) {
    final dl = ref.read(downloadManagerProvider);
    return [
      const PopupMenuItem(value: 'play', child: ListTile(leading: Icon(Icons.play_arrow_rounded), title: Text('Abspielen'))),
      if (!e.inQueue) ...[
        const PopupMenuItem(
            value: 'front', child: ListTile(leading: Icon(Icons.playlist_play_rounded), title: Text('Als Nächstes'))),
        const PopupMenuItem(
            value: 'back',
            child: ListTile(leading: Icon(Icons.playlist_add_rounded), title: Text('Ans Ende der Warteschlange'))),
      ] else
        const PopupMenuItem(
            value: 'dequeue',
            child: ListTile(leading: Icon(Icons.playlist_remove_rounded), title: Text('Aus Warteschlange entfernen'))),
      if (!e.played)
        const PopupMenuItem(
            value: 'played', child: ListTile(leading: Icon(Icons.check_circle_outline_rounded), title: Text('Gehört markieren')))
      else
        const PopupMenuItem(
            value: 'unplayed', child: ListTile(leading: Icon(Icons.replay_rounded), title: Text('Als ungehört markieren'))),
      if (downloadsSupported)
        if (dl.has(e.id))
          const PopupMenuItem(
              value: 'deletedl', child: ListTile(leading: Icon(Icons.delete_outline_rounded), title: Text('Download löschen')))
        else if (dl.isActive(e.id))
          const PopupMenuItem(
              value: 'canceldl', child: ListTile(leading: Icon(Icons.close_rounded), title: Text('Download abbrechen')))
        else
          const PopupMenuItem(
              value: 'download', child: ListTile(leading: Icon(Icons.download_rounded), title: Text('Herunterladen'))),
      const PopupMenuItem(value: 'details', child: ListTile(leading: Icon(Icons.info_outline_rounded), title: Text('Details'))),
    ];
  }

  static Future<void> handle(BuildContext context, WidgetRef ref, Episode e, String action) async {
    final dl = ref.read(downloadManagerProvider.notifier);
    switch (action) {
      case 'play':
        await play(context, ref, e);
      case 'front':
        await enqueue(context, ref, e, front: true);
      case 'back':
        await enqueue(context, ref, e);
      case 'dequeue':
        await dequeue(context, ref, e);
      case 'played':
        await markPlayed(context, ref, e);
      case 'unplayed':
        await markPlayed(context, ref, e, played: false);
      case 'download':
        await dl.download(e);
      case 'deletedl':
        await dl.delete(e.id);
      case 'canceldl':
        dl.cancel(e.id);
      case 'details':
        openDetails(context, e);
    }
  }
}

class EpisodeTile extends ConsumerWidget {
  const EpisodeTile({
    super.key,
    required this.episode,
    this.showPodcast = true,
    this.dragHandle,
    this.onTap,
  });

  final Episode episode;
  final bool showPodcast;
  final Widget? dragHandle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(episodeProvider(episode.id)) ?? episode;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final playing = ref.watch(playbackControllerProvider.select((s) => s.hasItem && s.episode?.id == e.id));
    final isPlaying = playing && ref.watch(playbackControllerProvider.select((s) => s.isPlaying));
    final dl = ref.watch(downloadManagerProvider);
    final dlProgress = dl.active[e.id];
    final downloaded = dl.has(e.id);

    final meta = <String>[
      if (e.seasonEpisodeLabel.isNotEmpty) e.seasonEpisodeLabel,
      if (e.publishedAt != null) formatDate(e.publishedAt),
      if (e.played)
        'Gehört'
      else if (e.positionMs > 0 && e.durationMs > 0)
        formatRemaining(e.duration, e.position)
      else if (e.durationMs > 0)
        formatDurationShort(e.duration),
    ];

    return InkWell(
      onTap: onTap ?? () => EpisodeActions.openDetails(context, e),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (dragHandle != null) ...[dragHandle!, const SizedBox(width: 6)],
            Stack(
              alignment: Alignment.center,
              children: [
                Opacity(opacity: e.played ? 0.5 : 1, child: Artwork(url: e.artworkUrl, size: 56)),
                if (playing)
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(isPlaying ? Icons.graphic_eq_rounded : Icons.pause_rounded, color: scheme.primary),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showPodcast)
                    Text(
                      e.podcastTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
                    ),
                  Text(
                    e.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: e.played ? scheme.onSurfaceVariant : scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (downloaded) ...[
                        Icon(Icons.offline_pin_rounded, size: 14, color: scheme.primary),
                        const SizedBox(width: 4),
                      ],
                      if (e.inQueue && !e.played) ...[
                        Icon(Icons.playlist_add_check_rounded, size: 14, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          meta.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  if (dlProgress != null) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: dlProgress < 0 ? null : dlProgress,
                        minHeight: 3,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ] else if (!e.played && e.progressFraction > 0) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: e.progressFraction,
                        minHeight: 3,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: playing && isPlaying ? 'Pause' : 'Abspielen',
              onPressed: () {
                if (playing) {
                  ref.read(playbackControllerProvider.notifier).togglePlay();
                } else {
                  EpisodeActions.play(context, ref, e);
                }
              },
              icon: Icon(playing && isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                  size: 34, color: scheme.primary),
            ),
            PopupMenuButton<String>(
              tooltip: 'Mehr',
              icon: const Icon(Icons.more_vert_rounded),
              itemBuilder: (_) => EpisodeActions.menuItems(ref, e),
              onSelected: (a) => EpisodeActions.handle(context, ref, e, a),
            ),
          ],
        ),
      ),
    );
  }
}
