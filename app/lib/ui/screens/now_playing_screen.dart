import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../playback/playback_controller.dart';
import '../../playback/playback_target.dart';
import '../format.dart';
import '../widgets/artwork.dart';
import '../widgets/output_picker.dart';
import 'episode_screen.dart';

class NowPlayingScreen extends ConsumerStatefulWidget {
  const NowPlayingScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
        PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => const NowPlayingScreen(),
          transitionsBuilder: (_, anim, _, child) => SlideTransition(
            position: Tween(begin: const Offset(0, 1), end: Offset.zero)
                .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 260),
        ),
      );

  @override
  ConsumerState<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends ConsumerState<NowPlayingScreen> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(playbackControllerProvider);
    final ep = s.episode;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final ctl = ref.read(playbackControllerProvider.notifier);

    if (ep == null) {
      return Scaffold(
        appBar: AppBar(leading: const CloseButton()),
        body: const Center(child: Text('Nichts in Wiedergabe')),
      );
    }

    final total = s.duration;
    final totalMs = total.inMilliseconds.toDouble();
    final posMs = (_dragValue ?? s.position.inMilliseconds.toDouble()).clamp(0.0, totalMs > 0 ? totalMs : double.infinity);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.expand_more_rounded), onPressed: () => Navigator.of(context).maybePop()),
        title: Text('Läuft gerade', style: text.titleMedium),
        actions: [
          IconButton(
            tooltip: 'Episode',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => EpisodeScreen(episodeId: ep.id))),
            icon: const Icon(Icons.info_outline_rounded),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              children: [
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 360),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(24),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.45), blurRadius: 40, offset: const Offset(0, 16)),
                          ],
                        ),
                        child: Artwork(url: ep.artworkUrl, size: null, radius: 24),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(ep.title,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.titleLarge),
                const SizedBox(height: 4),
                Text(ep.podcastTitle,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600)),
                const SizedBox(height: 16),
                Slider(
                  value: totalMs > 0 ? posMs : 0,
                  max: totalMs > 0 ? totalMs : 1,
                  onChanged: totalMs > 0 ? (v) => setState(() => _dragValue = v) : null,
                  onChangeEnd: (v) async {
                    setState(() => _dragValue = null);
                    await ctl.seek(Duration(milliseconds: v.round()));
                  },
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Text(formatDuration(Duration(milliseconds: posMs.round())),
                          style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                      const Spacer(),
                      Text(total > Duration.zero ? '-${formatDuration(total - Duration(milliseconds: posMs.round()))}' : '--:--',
                          style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      tooltip: 'Geschwindigkeit',
                      onPressed: s.targetSupportsSpeed ? () => _pickSpeed(context, s.speed) : null,
                      icon: Text('${s.speed.toStringAsFixed(s.speed % 1 == 0 ? 0 : 2).replaceAll(RegExp(r'0$'), '')}×',
                          style: text.titleMedium?.copyWith(
                              color: s.targetSupportsSpeed ? scheme.onSurface : scheme.onSurfaceVariant)),
                    ),
                    IconButton(iconSize: 40, onPressed: ctl.skipBack, icon: const Icon(Icons.replay_10_rounded)),
                    FilledButton(
                      onPressed: ctl.togglePlay,
                      style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        padding: const EdgeInsets.all(18),
                      ),
                      child: s.isLoading
                          ? SizedBox(
                              width: 36,
                              height: 36,
                              child: CircularProgressIndicator(strokeWidth: 3, color: scheme.onPrimary))
                          : Icon(s.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 36),
                    ),
                    IconButton(iconSize: 40, onPressed: ctl.skipForward, icon: const Icon(Icons.forward_30_rounded)),
                    IconButton(tooltip: 'Nächste', iconSize: 32, onPressed: ctl.next, icon: const Icon(Icons.skip_next_rounded)),
                  ],
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => OutputPicker.show(context),
                  icon: Icon(s.isSonos ? Icons.speaker_rounded : Icons.devices_rounded, size: 18),
                  label: Text(s.targetName),
                ),
                if (s.targetSupportsVolume) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      IconButton(
                        tooltip: s.volume == 0 ? 'Ton an' : 'Stumm',
                        onPressed: () => ctl.setVolume(s.volume == 0 ? 0.5 : 0),
                        icon: Icon(
                          s.volume == 0
                              ? Icons.volume_off_rounded
                              : s.volume < 0.5
                                  ? Icons.volume_down_rounded
                                  : Icons.volume_up_rounded,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: s.volume.clamp(0.0, 1.0),
                          onChanged: (v) => ctl.setVolume(v),
                        ),
                      ),
                      SizedBox(
                        width: 40,
                        child: Text('${(s.volume * 100).round()}%',
                            textAlign: TextAlign.end,
                            style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                      ),
                    ],
                  ),
                ],
                if (s.status.state == PlaybackState.error && s.error != null) ...[
                  const SizedBox(height: 12),
                  Text(s.error!, style: text.bodySmall?.copyWith(color: scheme.error), textAlign: TextAlign.center),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pickSpeed(BuildContext context, double current) async {
    const speeds = [0.8, 1.0, 1.1, 1.2, 1.3, 1.5, 1.75, 2.0];
    final v = await showModalBottomSheet<double>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 420),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Geschwindigkeit', style: Theme.of(ctx).textTheme.titleLarge),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final sp in speeds)
                  ChoiceChip(
                    label: Text('$sp×'),
                    selected: (sp - current).abs() < 0.01,
                    onSelected: (_) => Navigator.pop(ctx, sp),
                  ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
    if (v != null) await ref.read(playbackControllerProvider.notifier).setSpeed(v);
  }
}
