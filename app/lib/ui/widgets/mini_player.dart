import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../playback/playback_controller.dart';
import '../screens/now_playing_screen.dart';
import 'artwork.dart';

class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(playbackControllerProvider);
    final ep = s.episode;
    if (ep == null || !s.hasItem) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final total = s.duration;
    final frac = total > Duration.zero ? (s.position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0) : 0.0;
    final ctl = ref.read(playbackControllerProvider.notifier);

    return Material(
      color: scheme.surfaceContainer,
      child: InkWell(
        onTap: () => NowPlayingScreen.open(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 2,
              child: LinearProgressIndicator(
                value: s.isLoading ? null : frac,
                backgroundColor: scheme.surfaceContainerHighest,
                minHeight: 2,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: [
                  Artwork(url: ep.artworkUrl, size: 44, radius: 8),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(ep.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                        Row(
                          children: [
                            if (s.isSonos) ...[
                              Icon(Icons.speaker_rounded, size: 12, color: scheme.primary),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                s.isSonos ? '${s.targetName} · ${ep.podcastTitle}' : ep.podcastTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Zurück',
                    onPressed: ctl.skipBack,
                    icon: const Icon(Icons.replay_10_rounded),
                  ),
                  IconButton(
                    tooltip: s.isPlaying ? 'Pause' : 'Abspielen',
                    onPressed: ctl.togglePlay,
                    iconSize: 36,
                    icon: s.isLoading
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : Icon(s.isPlaying ? Icons.pause_circle_filled_rounded : Icons.play_circle_fill_rounded,
                            color: scheme.primary),
                  ),
                  IconButton(
                    tooltip: 'Vorwärts',
                    onPressed: ctl.skipForward,
                    icon: const Icon(Icons.forward_30_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
