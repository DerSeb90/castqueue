import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../playback/playback_controller.dart';
import '../../playback/playback_target.dart';
import '../format.dart';
import '../widgets/artwork.dart';
import '../widgets/output_picker.dart';
import 'episode_screen.dart';

/// Full-screen player. The artwork sets the mood: a blurred, darkened copy of
/// it fills the background and fades into the surface where the controls sit.
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
    final posMs = (_dragValue ?? s.position.inMilliseconds.toDouble())
        .clamp(0.0, totalMs > 0 ? totalMs : double.infinity)
        .toDouble();
    final position = Duration(milliseconds: posMs.round());

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        leading: IconButton(
          tooltip: 'Schließen',
          icon: const Icon(Icons.expand_more_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('Läuft gerade', style: text.titleMedium),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Episode',
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => EpisodeScreen(episodeId: ep.id))),
            icon: const Icon(Icons.info_outline_rounded),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          _Background(url: ep.artworkUrl),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                  child: Column(
                    children: [
                      Expanded(child: _ArtworkCard(url: ep.artworkUrl)),
                      const SizedBox(height: 28),
                      Text(
                        ep.title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        ep.podcastTitle,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodyMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 20),
                      _ProgressBar(
                        position: position,
                        total: total,
                        onChanged: totalMs > 0 ? (v) => setState(() => _dragValue = v) : null,
                        onChangeEnd: (v) async {
                          setState(() => _dragValue = null);
                          await ctl.seek(Duration(milliseconds: v.round()));
                        },
                      ),
                      const SizedBox(height: 12),
                      _Controls(
                        state: s,
                        onSpeed: s.targetSupportsSpeed ? () => _pickSpeed(context, s.speed) : null,
                        onBack: ctl.skipBack,
                        onToggle: ctl.togglePlay,
                        onForward: ctl.skipForward,
                        onNext: ctl.next,
                      ),
                      const SizedBox(height: 20),
                      _OutputRow(
                        state: s,
                        onVolume: ctl.setVolume,
                        onSleep: () => _pickSleep(context, s.sleepTimer),
                      ),
                      if (s.status.state == PlaybackState.error && s.error != null) ...[
                        const SizedBox(height: 12),
                        Text(s.error!, style: text.bodySmall?.copyWith(color: scheme.error), textAlign: TextAlign.center),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
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
                    label: Text(_fmtSpeed(sp)),
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

extension on _NowPlayingScreenState {
  Future<void> _pickSleep(BuildContext context, SleepTimer? current) async {
    const minutes = [15, 30, 45, 60, 90];
    final ctl = ref.read(playbackControllerProvider.notifier);
    final active = current != null;
    final choice = await showModalBottomSheet<String>(
      context: context,
      constraints: const BoxConstraints(maxWidth: 420),
      builder: (ctx) {
        final text = Theme.of(ctx).textTheme;
        final scheme = Theme.of(ctx).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text('Sleep-Timer', style: text.titleLarge),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  active
                      ? (current.endOfEpisode
                          ? 'Aktiv: Wiedergabe endet mit dieser Folge.'
                          : 'Aktiv: noch ${formatDuration(current.remaining ?? Duration.zero)}.')
                      : 'Wiedergabe nach einer Zeit oder am Ende der Folge pausieren.',
                  style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in minutes)
                      ChoiceChip(
                        label: Text('$m Min.'),
                        selected: false,
                        onSelected: (_) => Navigator.pop(ctx, 'm$m'),
                      ),
                    ChoiceChip(
                      label: const Text('Ende der Folge'),
                      selected: current?.endOfEpisode == true,
                      onSelected: (_) => Navigator.pop(ctx, 'end'),
                    ),
                    if (active && !current.endOfEpisode)
                      ActionChip(
                        avatar: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('15 Min.'),
                        onPressed: () => Navigator.pop(ctx, 'plus'),
                      ),
                    if (active)
                      ActionChip(
                        avatar: Icon(Icons.close_rounded, size: 18, color: scheme.error),
                        label: const Text('Aus'),
                        onPressed: () => Navigator.pop(ctx, 'off'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
    if (choice == null) return;
    if (choice == 'off') {
      ctl.cancelSleepTimer();
    } else if (choice == 'end') {
      ctl.setSleepAtEpisodeEnd();
    } else if (choice == 'plus') {
      ctl.extendSleepTimer(const Duration(minutes: 15));
    } else if (choice.startsWith('m')) {
      ctl.setSleepTimer(Duration(minutes: int.parse(choice.substring(1))));
    }
  }
}

/// "1×", "1.2×", "1.75×".
String _fmtSpeed(double v) {
  var s = v.toStringAsFixed(2);
  s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return '$s×';
}

/// Blurred artwork behind everything, fading into the scaffold colour so the
/// lower half (text and controls) always sits on a calm, readable surface.
class _Background extends StatelessWidget {
  const _Background({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = Theme.of(context).scaffoldBackgroundColor;
    final hasImage = url.isNotEmpty && Uri.tryParse(url)?.hasScheme == true;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: bg),
        if (hasImage)
          ClipRect(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 48, sigmaY: 48, tileMode: TileMode.clamp),
              child: Transform.scale(
                scale: 1.4,
                child: CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  fadeInDuration: const Duration(milliseconds: 400),
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          )
        else
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.6),
                radius: 1.1,
                colors: [scheme.primary.withValues(alpha: 0.22), bg],
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0, 0.45, 0.78, 1],
              colors: [
                bg.withValues(alpha: 0.35),
                bg.withValues(alpha: 0.72),
                bg.withValues(alpha: 0.97),
                bg,
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Square artwork that shrinks with the available height, lifted by a soft
/// shadow so it reads as an object on top of the blurred wash.
class _ArtworkCard extends StatelessWidget {
  const _ArtworkCard({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380, maxHeight: 380),
        child: AspectRatio(
          aspectRatio: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 48, offset: const Offset(0, 20)),
                BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 12, offset: const Offset(0, 4)),
              ],
            ),
            child: Artwork(url: url, size: null, radius: 22),
          ),
        ),
      ),
    );
  }
}

class _ProgressBar extends StatelessWidget {
  const _ProgressBar({
    required this.position,
    required this.total,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final Duration position;
  final Duration total;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final totalMs = total.inMilliseconds.toDouble();
    final known = totalMs > 0;
    final remaining = known ? total - position : Duration.zero;
    final timeStyle = text.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 4,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7, elevation: 0),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.14),
            trackShape: const RoundedRectSliderTrackShape(),
          ),
          child: Slider(
            value: known ? position.inMilliseconds.toDouble().clamp(0.0, totalMs) : 0,
            max: known ? totalMs : 1,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Text(formatDuration(position), style: timeStyle),
              const Spacer(),
              Text(known ? '-${formatDuration(remaining)}' : '--:--', style: timeStyle),
            ],
          ),
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.state,
    required this.onSpeed,
    required this.onBack,
    required this.onToggle,
    required this.onForward,
    required this.onNext,
  });

  final PlaybackUiState state;
  final VoidCallback? onSpeed;
  final VoidCallback onBack;
  final VoidCallback onToggle;
  final VoidCallback onForward;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final s = state;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        SizedBox(
          width: 64,
          child: Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: onSpeed,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                minimumSize: const Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: const StadiumBorder(),
                side: BorderSide(color: scheme.onSurface.withValues(alpha: 0.18)),
                foregroundColor: s.targetSupportsSpeed ? scheme.onSurface : scheme.onSurfaceVariant,
              ),
              child: Text(_fmtSpeed(s.speed), style: text.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
            ),
          ),
        ),
        IconButton(
          tooltip: '10 Sekunden zurück',
          iconSize: 36,
          onPressed: onBack,
          icon: const Icon(Icons.replay_10_rounded),
        ),
        _PlayButton(isPlaying: s.isPlaying, isLoading: s.isLoading, onPressed: onToggle),
        IconButton(
          tooltip: '30 Sekunden vor',
          iconSize: 36,
          onPressed: onForward,
          icon: const Icon(Icons.forward_30_rounded),
        ),
        SizedBox(
          width: 64,
          child: Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: 'Nächste Folge',
              iconSize: 30,
              onPressed: onNext,
              icon: const Icon(Icons.skip_next_rounded),
            ),
          ),
        ),
      ],
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.isPlaying, required this.isLoading, required this.onPressed});
  final bool isPlaying;
  final bool isLoading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: scheme.primary.withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 8)),
        ],
      ),
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          fixedSize: const Size(72, 72),
        ),
        child: isLoading
            ? SizedBox(
                width: 30,
                height: 30,
                child: CircularProgressIndicator(strokeWidth: 3, color: scheme.onPrimary),
              )
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 150),
                child: Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  key: ValueKey(isPlaying),
                  size: 40,
                ),
              ),
      ),
    );
  }
}

/// Output target pill plus, when the target supports it, the volume row.
class _OutputRow extends StatelessWidget {
  const _OutputRow({required this.state, required this.onVolume, required this.onSleep});
  final PlaybackUiState state;
  final ValueChanged<double> onVolume;
  final VoidCallback onSleep;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final s = state;
    final vol = s.volume.clamp(0.0, 1.0);
    final volIcon = vol == 0
        ? Icons.volume_off_rounded
        : vol < 0.5
            ? Icons.volume_down_rounded
            : Icons.volume_up_rounded;

    final sleep = s.sleepTimer;
    ButtonStyle pill(Color fg) => OutlinedButton.styleFrom(
          shape: const StadiumBorder(),
          side: BorderSide(color: scheme.onSurface.withValues(alpha: 0.18)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          foregroundColor: fg,
        );

    return Column(
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () => OutputPicker.show(context),
              style: pill(s.isSonos ? scheme.primary : scheme.onSurface),
              icon: Icon(s.isSonos ? Icons.speaker_rounded : Icons.devices_rounded, size: 18),
              label: Text(s.targetName, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            OutlinedButton.icon(
              onPressed: onSleep,
              style: pill(sleep != null ? scheme.primary : scheme.onSurfaceVariant),
              icon: Icon(sleep != null ? Icons.bedtime_rounded : Icons.bedtime_outlined, size: 18),
              label: sleep == null
                  ? const Text('Sleep-Timer')
                  : sleep.endOfEpisode
                      ? const Text('Bis Folgenende')
                      : _SleepCountdown(timer: sleep),
            ),
          ],
        ),
        if (s.targetSupportsVolume) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              IconButton(
                tooltip: vol == 0 ? 'Ton an' : 'Stumm',
                onPressed: () => onVolume(vol == 0 ? 0.5 : 0),
                icon: Icon(volIcon, color: scheme.onSurfaceVariant),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                    inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.14),
                  ),
                  child: Slider(value: vol, onChanged: onVolume),
                ),
              ),
              SizedBox(
                width: 40,
                child: Text(
                  '${(vol * 100).round()}%',
                  textAlign: TextAlign.end,
                  style: text.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Remaining sleep time, ticking once a second (the player state alone does
/// not update while paused).
class _SleepCountdown extends StatefulWidget {
  const _SleepCountdown({required this.timer});
  final SleepTimer timer;

  @override
  State<_SleepCountdown> createState() => _SleepCountdownState();
}

class _SleepCountdownState extends State<_SleepCountdown> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.timer.remaining ?? Duration.zero;
    return Text(
      formatDuration(r),
      style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
    );
  }
}
