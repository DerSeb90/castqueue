import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sync_service.dart';
import '../../state/library.dart';
import '../widgets/artwork.dart';
import 'add_podcast_screen.dart';
import 'podcast_detail_screen.dart';

class PodcastsScreen extends ConsumerWidget {
  const PodcastsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final podcasts = ref.watch(podcastsProvider);
    final refreshing = ref.watch(libraryProvider.select((s) => s.refreshing));
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Abos'),
        actions: [
          if (refreshing)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            IconButton(
              tooltip: 'Feeds aktualisieren',
              onPressed: () => ref.read(syncServiceProvider).refreshAndSync(),
              icon: const Icon(Icons.refresh_rounded),
            ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AddPodcastScreen())),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Hinzufügen'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(syncServiceProvider).refreshAndSync(),
        child: podcasts.isEmpty
            ? ListView(
                children: [
                  SizedBox(height: MediaQuery.sizeOf(context).height * 0.25),
                  Icon(Icons.podcasts_rounded, size: 64, color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
                  const SizedBox(height: 16),
                  Text('Noch keine Abos', textAlign: TextAlign.center, style: text.titleLarge),
                  const SizedBox(height: 6),
                  Text(
                    'Füge einen Podcast per Suche oder Feed-URL hinzu.',
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              )
            : LayoutBuilder(
                builder: (context, c) {
                  final cols = (c.maxWidth / 170).floor().clamp(2, 8);
                  return GridView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.72,
                    ),
                    itemCount: podcasts.length,
                    itemBuilder: (context, i) {
                      final p = podcasts[i];
                      return InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () =>
                            Navigator.of(context)
                                .push(MaterialPageRoute<void>(builder: (_) => PodcastDetailScreen(podcastId: p.id))),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.topCenter,
                                child: AspectRatio(
                                  aspectRatio: 1,
                                  child: Stack(
                                    children: [
                                      Artwork(url: p.imageUrl, size: null, radius: 16),
                                      if (p.hasAuth)
                                        Positioned(
                                          right: 8,
                                          top: 8,
                                          child: Container(
                                            padding: const EdgeInsets.all(5),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(alpha: 0.55),
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Icon(Icons.lock_rounded, size: 14, color: scheme.primary),
                                          ),
                                        ),
                                      if (p.lastError.isNotEmpty)
                                        Positioned(
                                          left: 8,
                                          top: 8,
                                          child: Tooltip(
                                            message: p.lastError,
                                            child: Container(
                                              padding: const EdgeInsets.all(5),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withValues(alpha: 0.55),
                                                borderRadius: BorderRadius.circular(8),
                                              ),
                                              child: Icon(Icons.error_outline_rounded, size: 14, color: scheme.error),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              p.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.2),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${p.episodeCount} Folgen',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
      ),
    );
  }
}
