import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../playback/playback_controller.dart';
import '../state/library.dart';
import 'format.dart';
import 'screens/inbox_screen.dart';
import 'screens/podcasts_screen.dart';
import 'screens/queue_screen.dart';
import 'screens/settings_screen.dart';
import 'widgets/mini_player.dart';

/// Responsive shell: NavigationRail (≥ 800 px) or bottom NavigationBar, with
/// the persistent mini player.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  int _index = 0;

  static const _destinations = [
    (icon: Icons.queue_music_outlined, selected: Icons.queue_music_rounded, label: 'Warteschlange'),
    (icon: Icons.podcasts_outlined, selected: Icons.podcasts_rounded, label: 'Abos'),
    (icon: Icons.inbox_outlined, selected: Icons.inbox_rounded, label: 'Neu'),
    (icon: Icons.settings_outlined, selected: Icons.settings_rounded, label: 'Einstellungen'),
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

    final wide = MediaQuery.sizeOf(context).width >= 800;
    final body = IndexedStack(
      index: _index,
      children: const [QueueScreen(), PodcastsScreen(), InboxScreen(), SettingsScreen()],
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
                    destinations: [
                      for (final d in _destinations)
                        NavigationRailDestination(
                          icon: Icon(d.icon),
                          selectedIcon: Icon(d.selected),
                          label: Text(d.label),
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
          : Scaffold(
              body: body,
              bottomNavigationBar: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const MiniPlayer(),
                  NavigationBar(
                    selectedIndex: _index,
                    onDestinationSelected: (i) => setState(() => _index = i),
                    destinations: [
                      for (final d in _destinations)
                        NavigationDestination(icon: Icon(d.icon), selectedIcon: Icon(d.selected), label: d.label),
                    ],
                  ),
                ],
              ),
            ),
    );
  }
}
