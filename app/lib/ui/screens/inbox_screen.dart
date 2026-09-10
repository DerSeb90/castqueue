import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sync_service.dart';
import '../../state/library.dart';
import '../widgets/episode_tile.dart';

/// "Neu": episodes published in the last 14 days across all subscriptions.
class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final episodes = ref.watch(libraryProvider.select((s) => s.recent(days: 14)));
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Neu')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(syncServiceProvider).refreshAndSync(),
        child: episodes.isEmpty
            ? ListView(
                children: [
                  SizedBox(height: MediaQuery.sizeOf(context).height * 0.25),
                  Icon(Icons.inbox_rounded, size: 64, color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
                  const SizedBox(height: 16),
                  Text('Nichts Neues', textAlign: TextAlign.center, style: text.titleLarge),
                  const SizedBox(height: 6),
                  Text('Keine Folgen der letzten 14 Tage.',
                      textAlign: TextAlign.center, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              )
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 120),
                    itemCount: episodes.length,
                    itemBuilder: (context, i) => EpisodeTile(episode: episodes[i]),
                  ),
                ),
              ),
      ),
    );
  }
}
