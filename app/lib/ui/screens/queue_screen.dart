import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sync_service.dart';
import '../../playback/playback_controller.dart';
import '../../state/library.dart';
import '../format.dart';
import '../widgets/episode_tile.dart';

class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  Future<void> _clear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Warteschlange leeren?'),
        content: const Text('Alle Folgen werden aus der Warteschlange entfernt (auf allen Geräten).'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Leeren')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await guarded(context, () => ref.read(libraryProvider.notifier).clearQueue());
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueProvider);
    final syncing = ref.watch(libraryProvider.select((s) => s.syncing));
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final totalMs = queue.fold<int>(0, (a, e) => a + (e.played ? 0 : (e.durationMs - e.positionMs).clamp(0, 1 << 40)));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Warteschlange'),
        actions: [
          if (syncing)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            IconButton(
              tooltip: 'Synchronisieren',
              onPressed: () => ref.read(syncServiceProvider).syncNow(),
              icon: const Icon(Icons.sync_rounded),
            ),
          if (queue.isNotEmpty)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'clear') _clear(context, ref);
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'clear',
                  child: ListTile(
                    leading: Icon(Icons.delete_sweep_rounded, color: scheme.error),
                    title: Text('Warteschlange leeren', style: TextStyle(color: scheme.error)),
                  ),
                ),
              ],
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(syncServiceProvider).refreshAndSync(),
        child: queue.isEmpty
            ? ListView(
                children: [
                  SizedBox(height: MediaQuery.sizeOf(context).height * 0.25),
                  Icon(Icons.queue_music_rounded, size: 64, color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
                  const SizedBox(height: 16),
                  Text('Warteschlange ist leer', textAlign: TextAlign.center, style: text.titleLarge),
                  const SizedBox(height: 6),
                  Text('Neue Folgen abonnierter Podcasts landen hier automatisch.',
                      textAlign: TextAlign.center, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              )
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${queue.length} Folgen · ${formatDurationShort(Duration(milliseconds: totalMs))}',
                                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: () => ref.read(playbackControllerProvider.notifier).playQueue(),
                              icon: const Icon(Icons.play_arrow_rounded, size: 20),
                              label: const Text('Abspielen'),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: ReorderableListView.builder(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 120),
                          buildDefaultDragHandles: false,
                          itemCount: queue.length,
                          onReorderItem: (oldIndex, newIndex) async {
                            final ids = queue.map((e) => e.id).toList();
                            final id = ids.removeAt(oldIndex);
                            ids.insert(newIndex, id);
                            final ok = await ref.read(libraryProvider.notifier).replaceQueue(ids).catchError((Object e) {
                              if (context.mounted) showSnack(context, e.toString(), error: true);
                              return true;
                            });
                            if (!ok && context.mounted) {
                              showSnack(context, 'Warteschlange wurde woanders geändert – Server-Stand übernommen');
                            }
                          },
                          itemBuilder: (context, i) {
                            final e = queue[i];
                            return Dismissible(
                              key: ValueKey('q-${e.id}'),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 24),
                                decoration: BoxDecoration(
                                  color: scheme.errorContainer,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(Icons.playlist_remove_rounded, color: scheme.onErrorContainer),
                              ),
                              onDismissed: (_) => EpisodeActions.dequeue(context, ref, e),
                              child: EpisodeTile(
                                episode: e,
                                dragHandle: ReorderableDragStartListener(
                                  index: i,
                                  child: Icon(Icons.drag_indicator_rounded, color: scheme.onSurfaceVariant),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
