import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ipod/rockbox_device.dart';
import '../playback/playback_controller.dart';
import '../state/library.dart';
import 'format.dart';
import 'screens/inbox_screen.dart';
import 'screens/ipod_screen.dart';
import 'screens/podcasts_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/mini_player.dart';
import 'widgets/version_badge.dart';

/// Responsive shell: NavigationRail (≥ 800 px) or bottom NavigationBar, with
/// the persistent mini player.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  /// `label` is used on the wide NavigationRail, `short` on the phone bar,
  /// where four destinations share ~360 dp and long words wrap.
  static const _destinations = [
    (icon: Icons.queue_music_outlined, selected: Icons.queue_music_rounded, label: 'Warteschlange', short: 'Liste'),
    (icon: Icons.podcasts_outlined, selected: Icons.podcasts_rounded, label: 'Abos', short: 'Abos'),
    (icon: Icons.inbox_outlined, selected: Icons.inbox_rounded, label: 'Neu', short: 'Neu'),
    (icon: Icons.settings_outlined, selected: Icons.settings_rounded, label: 'Einstellungen', short: 'Mehr'),
  ];

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.space) return KeyEventResult.ignored;
    final focused = FocusManager.instance.primaryFocus?.context?.widget;
    if (focused is EditableText) return KeyEventResult.ignored;
    ref.read(playbackControllerProvider.notifier).togglePlay();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(libraryProvider.select((s) => s.lastError), (prev, next) {
      if (next != null && next != prev) showSnack(context, next, error: true);
    });
    ref.listen(playbackControllerProvider.select((s) => s.error), (prev, next) {
      if (next != null && next != prev) showSnack(context, next, error: true);
    });
    ref.listen(playbackControllerProvider.select((s) => s.notice), (prev, next) {
      if (next != null && next != prev) {
        showSnack(context, next);
        ref.read(playbackControllerProvider.notifier).clearNotice();
      }
    });

    final wide = MediaQuery.sizeOf(context).width >= 800;
    if (!wide && _index > 3) _index = 3;
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // The iPod page only exists on the desktop rail; on phones the index never
    // reaches it.
    final showIpod = wide && ipodSupported;
    final body = IndexedStack(
      index: _index,
      children: [
        const QueueScreen(),
        const PodcastsScreen(),
        const InboxScreen(),
        const SettingsScreen(),
        if (showIpod) const IpodScreen(),
      ],
    );

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: wide
          ? Scaffold(
              body: Row(
                children: [
                  NavigationRail(
                    selectedIndex: _index,
                    onDestinationSelected: (i) => setState(() => _index = i),
                    minWidth: 84,
                    leading: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.queue_music_rounded, color: Theme.of(context).colorScheme.onPrimary),
                      ),
                    ),
                    trailing: const Expanded(
                      child: Align(alignment: Alignment.bottomCenter, child: VersionBadge()),
                    ),
                    destinations: [
                      for (final d in _destinations)
                        NavigationRailDestination(
                          icon: Icon(d.icon),
                          selectedIcon: Icon(d.selected),
                          label: Text(d.label),
                        ),
                      if (showIpod)
                        const NavigationRailDestination(
                          icon: Icon(Icons.usb_outlined),
                          selectedIcon: Icon(Icons.usb_rounded),
                          label: Text('iPod'),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(child: body),
                        const MiniPlayer(),
                      ],
                    ),
                  ),
                ],
              ),
            )
          : AnnotatedRegion<SystemUiOverlayStyle>(
              value: SystemUiOverlayStyle(
                systemNavigationBarColor: scheme.surfaceContainerLowest,
                systemNavigationBarDividerColor: scheme.surfaceContainerLowest,
                systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
              ),
              child: Scaffold(
                body: body,
                bottomNavigationBar: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const MiniPlayer(),
                    NavigationBar(
                      selectedIndex: _index,
                      onDestinationSelected: (i) => setState(() => _index = i),
                      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                      height: 64,
                      destinations: [
                        for (final d in _destinations)
                          NavigationDestination(
                            icon: Icon(d.icon),
                            selectedIcon: Icon(d.selected),
                            label: d.short,
                            tooltip: d.label,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
