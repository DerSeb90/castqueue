import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../downloads/download_manager.dart';
import '../../playback/playback_controller.dart';
import '../../state/library.dart';
import '../format.dart';
import '../widgets/artwork.dart';
import '../widgets/episode_tile.dart';
import '../widgets/meta_row.dart';
import 'podcast_detail_screen.dart';

class EpisodeScreen extends ConsumerWidget {
  const EpisodeScreen({super.key, required this.episodeId});
  final String episodeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(episodeProvider(episodeId));
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (e == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Episode nicht (mehr) vorhanden')));
    }
    final playing = ref.watch(playbackControllerProvider.select((s) => s.hasItem && s.episode?.id == e.id));
    final isPlaying = playing && ref.watch(playbackControllerProvider.select((s) => s.isPlaying));
    final dl = ref.watch(downloadManagerProvider);

    final se = [
      if (e.season > 0) 'Staffel ${e.season}',
      if (e.episodeNumber > 0) 'Folge ${e.episodeNumber}',
    ].join(' · ');
    final meta = [
      if (se.isNotEmpty) se,
      if (e.publishedAt != null) formatDate(e.publishedAt),
      if (e.durationMs > 0) formatDurationShort(e.duration),
      if (e.mediaSize > 0) formatBytes(e.mediaSize),
    ].join(' · ');
    final typeLabel = e.episodeType == 'full' ? '' : episodeTypeLabel(e.episodeType);

    return Scaffold(
      appBar: AppBar(
        actions: [
          PopupMenuButton<String>(
            itemBuilder: (_) => EpisodeActions.menuItems(ref, e),
            onSelected: (a) => EpisodeActions.handle(context, ref, e, a),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 120),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Artwork(url: e.artworkUrl, size: 112, radius: 16),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => PodcastDetailScreen(podcastId: e.podcastId))),
                          child: Text(e.podcastTitle,
                              style: text.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700)),
                        ),
                        const SizedBox(height: 4),
                        Text(e.title, style: text.headlineSmall),
                        if (e.author.isNotEmpty && e.author != e.podcastTitle)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(e.author, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                          ),
                        const SizedBox(height: 6),
                        Text(meta, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        if (typeLabel.isNotEmpty || e.explicit)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Wrap(
                              spacing: 6,
                              children: [
                                if (typeLabel.isNotEmpty)
                                  MetaBadge(typeLabel,
                                      icon: e.episodeType == 'trailer' ? Icons.movie_outlined : Icons.star_outline_rounded,
                                      color: scheme.primary),
                                if (e.explicit) const MetaBadge('Explicit', icon: Icons.explicit_rounded),
                              ],
                            ),
                          ),
                        if (e.played)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Row(children: [
                              Icon(Icons.check_circle_rounded, size: 16, color: scheme.primary),
                              const SizedBox(width: 4),
                              Text('Gehört', style: text.labelMedium?.copyWith(color: scheme.primary)),
                            ]),
                          )
                        else if (e.positionMs > 0 && e.durationMs > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(value: e.progressFraction, minHeight: 4),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () => playing
                        ? ref.read(playbackControllerProvider.notifier).togglePlay()
                        : EpisodeActions.play(context, ref, e),
                    icon: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                    label: Text(isPlaying
                        ? 'Pause'
                        : (e.positionMs > 0 && !e.played ? 'Fortsetzen' : 'Abspielen')),
                  ),
                  if (e.inQueue)
                    OutlinedButton.icon(
                      onPressed: () => EpisodeActions.dequeue(context, ref, e),
                      icon: const Icon(Icons.playlist_remove_rounded),
                      label: const Text('Aus Warteschlange'),
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: () => EpisodeActions.enqueue(context, ref, e),
                      icon: const Icon(Icons.playlist_add_rounded),
                      label: const Text('Warteschlange'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () => EpisodeActions.markPlayed(context, ref, e, played: !e.played),
                    icon: Icon(e.played ? Icons.replay_rounded : Icons.check_rounded),
                    label: Text(e.played ? 'Ungehört' : 'Gehört'),
                  ),
                  if (downloadsSupported)
                    if (dl.has(e.id))
                      OutlinedButton.icon(
                        onPressed: () => ref.read(downloadManagerProvider.notifier).delete(e.id),
                        icon: const Icon(Icons.offline_pin_rounded),
                        label: const Text('Heruntergeladen'),
                      )
                    else if (dl.isActive(e.id))
                      OutlinedButton.icon(
                        onPressed: () => ref.read(downloadManagerProvider.notifier).cancel(e.id),
                        icon: const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        label: Text('${((dl.active[e.id] ?? 0) * 100).clamp(0, 100).round()} %'),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: () => ref.read(downloadManagerProvider.notifier).download(e),
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('Download'),
                      ),
                ],
              ),
              const SizedBox(height: 24),
              if (e.description.isNotEmpty)
                HtmlWidget(
                  e.description,
                  textStyle: text.bodyMedium?.copyWith(height: 1.5),
                  onTapUrl: (url) => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                )
              else
                Text('Keine Beschreibung.', style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
              if (e.link.isNotEmpty) ...[
                const SizedBox(height: 24),
                TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse(e.link), mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_new_rounded, size: 18),
                  label: const Text('Episode im Browser öffnen'),
                ),
              ],
              const SizedBox(height: 16),
              _EpisodeDetails(episode: e),
            ],
          ),
        ),
      ),
    );
  }
}

/// Collapsed technical details: media type/size, media URL, GUID, link.
class _EpisodeDetails extends StatelessWidget {
  const _EpisodeDetails({required this.episode});
  final Episode episode;

  @override
  Widget build(BuildContext context) {
    final e = episode;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final media = [
      if (e.mediaType.isNotEmpty) e.mediaType,
      if (e.mediaSize > 0) formatBytes(e.mediaSize),
    ].join(' · ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Text('Details', style: text.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: [
            if (e.publishedAt != null)
              MetaRow(label: 'Veröffentlicht', value: formatDateTime(e.publishedAt), icon: Icons.event_rounded),
            if (e.durationMs > 0)
              MetaRow(label: 'Dauer', value: formatDuration(e.duration), icon: Icons.timer_outlined),
            if (e.season > 0) MetaRow(label: 'Staffel', value: '${e.season}', icon: Icons.layers_outlined),
            if (e.episodeNumber > 0)
              MetaRow(label: 'Folge Nr.', value: '${e.episodeNumber}', icon: Icons.tag_rounded),
            if (episodeTypeLabel(e.episodeType).isNotEmpty)
              MetaRow(label: 'Typ', value: episodeTypeLabel(e.episodeType), icon: Icons.label_outline_rounded),
            if (e.author.isNotEmpty) MetaRow(label: 'Autor', value: e.author, icon: Icons.person_outline_rounded),
            if (media.isNotEmpty) MetaRow(label: 'Medium', value: media, icon: Icons.audio_file_outlined),
            if (e.mediaUrl.isNotEmpty)
              MetaRow(label: 'Media-URL', value: e.mediaUrl, icon: Icons.link_rounded, copyable: true, mono: true),
            if (e.guid.isNotEmpty) MetaRow(label: 'GUID', value: e.guid, icon: Icons.fingerprint_rounded, copyable: true, mono: true),
            if (e.link.isNotEmpty)
              MetaRow(
                label: 'Link',
                value: e.link,
                icon: Icons.open_in_new_rounded,
                onTap: () => launchUrl(Uri.parse(e.link), mode: LaunchMode.externalApplication),
              ),
          ],
        ),
      ),
    );
  }
}
