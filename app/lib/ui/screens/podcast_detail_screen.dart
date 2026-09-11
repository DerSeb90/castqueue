import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../state/library.dart';
import '../format.dart';
import '../widgets/artwork.dart';
import '../widgets/episode_tile.dart';
import '../widgets/meta_row.dart';

class PodcastDetailScreen extends ConsumerStatefulWidget {
  const PodcastDetailScreen({super.key, required this.podcastId});
  final String podcastId;

  @override
  ConsumerState<PodcastDetailScreen> createState() => _PodcastDetailScreenState();
}

class _PodcastDetailScreenState extends ConsumerState<PodcastDetailScreen> {
  bool _loading = false;
  bool _expanded = false;
  bool _more = true;
  static const _page = 100;

  @override
  void initState() {
    super.initState();
    Future.microtask(() => _load(offset: 0));
  }

  Future<void> _load({required int offset}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final list = await ref.read(libraryProvider.notifier).loadEpisodes(widget.podcastId, limit: _page, offset: offset);
      if (mounted) setState(() => _more = list.length >= _page);
    } catch (e) {
      if (mounted) showSnack(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editAuth(Podcast p) async {
    final user = TextEditingController();
    final pass = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Feed-Zugangsdaten'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              p.hasAuth
                  ? 'Dieser Feed nutzt HTTP-Basic-Auth. Neue Daten eingeben oder leer lassen zum Entfernen.'
                  : 'Für Premium-Feeds mit HTTP-Basic-Auth.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(controller: user, decoration: const InputDecoration(labelText: 'Benutzername')),
            const SizedBox(height: 8),
            TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Passwort')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Speichern')),
        ],
      ),
    );
    if (result != true || !mounted) return;
    await guarded(
      context,
      () => ref.read(libraryProvider.notifier).updatePodcast(p.id, authUsername: user.text.trim(), authPassword: pass.text),
      success: 'Zugangsdaten gespeichert',
    );
  }

  Future<void> _unsubscribe(Podcast p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Deabonnieren?'),
        content: Text('„${p.title}“ wird entfernt. Alle Episoden fliegen aus der Warteschlange, der Fortschritt geht verloren.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Deabonnieren'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final done = await guarded(context, () => ref.read(libraryProvider.notifier).unsubscribe(p.id));
    if (done && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(podcastProvider(widget.podcastId));
    final episodes = ref.watch(libraryProvider.select((s) => s.episodesOf(widget.podcastId)));
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (p == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('Podcast nicht (mehr) abonniert')));
    }
    final desc = htmlToPlain(p.description);

    return Scaffold(
      appBar: AppBar(
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'refresh':
                  await guarded(context, () => ref.read(libraryProvider.notifier).refreshPodcast(p.id),
                      success: 'Feed aktualisiert');
                  if (mounted) await _load(offset: 0);
                case 'auth':
                  await _editAuth(p);
                case 'web':
                  await launchUrl(Uri.parse(p.website), mode: LaunchMode.externalApplication);
                case 'unsub':
                  await _unsubscribe(p);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'refresh', child: ListTile(leading: Icon(Icons.refresh_rounded), title: Text('Feed aktualisieren'))),
              const PopupMenuItem(value: 'auth', child: ListTile(leading: Icon(Icons.key_rounded), title: Text('Zugangsdaten'))),
              if (p.website.isNotEmpty)
                const PopupMenuItem(value: 'web', child: ListTile(leading: Icon(Icons.open_in_new_rounded), title: Text('Website'))),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'unsub',
                child: ListTile(
                  leading: Icon(Icons.delete_outline_rounded, color: scheme.error),
                  title: Text('Deabonnieren', style: TextStyle(color: scheme.error)),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: RefreshIndicator(
            onRefresh: () async {
              await guarded(context, () => ref.read(libraryProvider.notifier).refreshPodcast(p.id));
              await _load(offset: 0);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Artwork(url: p.imageUrl, size: 128, radius: 18),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.title, style: text.headlineSmall),
                          if (p.author.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(p.author, style: text.bodyMedium?.copyWith(color: scheme.primary)),
                            ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              Chip(
                                visualDensity: VisualDensity.compact,
                                label: Text('${p.episodeCount} Folgen'),
                              ),
                              if (p.hasAuth)
                                const Chip(
                                  visualDensity: VisualDensity.compact,
                                  avatar: Icon(Icons.lock_rounded, size: 14),
                                  label: Text('Premium'),
                                ),
                              if (p.podcastType == 'serial')
                                const Chip(
                                  visualDensity: VisualDensity.compact,
                                  avatar: Icon(Icons.format_list_numbered_rounded, size: 14),
                                  label: Text('Serie'),
                                ),
                              if (p.explicit)
                                const Chip(
                                  visualDensity: VisualDensity.compact,
                                  avatar: Icon(Icons.explicit_rounded, size: 14),
                                  label: Text('Explicit'),
                                ),
                              if (p.lastError.isNotEmpty)
                                Tooltip(
                                  message: p.lastError,
                                  child: Chip(
                                    visualDensity: VisualDensity.compact,
                                    avatar: Icon(Icons.error_outline_rounded, size: 14, color: scheme.error),
                                    label: const Text('Feed-Fehler'),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  InkWell(
                    onTap: () => setState(() => _expanded = !_expanded),
                    borderRadius: BorderRadius.circular(8),
                    child: Text(
                      desc,
                      maxLines: _expanded ? null : 3,
                      overflow: _expanded ? null : TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant, height: 1.45),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Card(
                  child: SwitchListTile(
                    title: const Text('Neue Folgen automatisch einreihen'),
                    subtitle: const Text('Ans Ende der Warteschlange beim Feed-Refresh'),
                    value: p.autoEnqueue,
                    onChanged: (v) => guarded(
                        context, () => ref.read(libraryProvider.notifier).updatePodcast(p.id, autoEnqueue: v)),
                  ),
                ),
                const SizedBox(height: 12),
                _PodcastInfoCard(podcast: p),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Text('Folgen', style: text.titleMedium),
                    const Spacer(),
                    if (_loading) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ),
                const SizedBox(height: 4),
                for (final e in episodes) EpisodeTile(episode: e, showPodcast: false),
                if (episodes.isEmpty && !_loading)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Keine Folgen gefunden.', style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                if (_more && episodes.length >= _page)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: OutlinedButton(
                      onPressed: _loading ? null : () => _load(offset: episodes.length),
                      child: const Text('Ältere Folgen laden'),
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

/// Feed metadata: feed URL (tap = copy), website, language, categories, type,
/// copyright, owner, refresh/subscription dates. Rows without data are omitted.
class _PodcastInfoCard extends StatelessWidget {
  const _PodcastInfoCard({required this.podcast});
  final Podcast podcast;

  @override
  Widget build(BuildContext context) {
    final p = podcast;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final rows = <Widget>[
      MetaRow(label: 'Feed-URL', value: p.feedUrl, icon: Icons.rss_feed_rounded, copyable: true, mono: true),
      if (p.website.isNotEmpty)
        MetaRow(
          label: 'Website',
          value: p.website,
          icon: Icons.language_rounded,
          onTap: () => launchUrl(Uri.parse(p.website), mode: LaunchMode.externalApplication),
        ),
      if (p.language.isNotEmpty) MetaRow(label: 'Sprache', value: p.language, icon: Icons.translate_rounded),
      if (p.categories.isNotEmpty) MetaChips(label: 'Kategorien', values: p.categories, icon: Icons.category_outlined),
      if (podcastTypeLabel(p.podcastType).isNotEmpty)
        MetaRow(label: 'Typ', value: podcastTypeLabel(p.podcastType), icon: Icons.view_agenda_outlined),
      if (p.explicit) const MetaRow(label: 'Inhalt', value: 'Explicit', icon: Icons.explicit_rounded),
      if (p.ownerName.isNotEmpty) MetaRow(label: 'Owner', value: p.ownerName, icon: Icons.person_outline_rounded),
      if (p.copyright.isNotEmpty) MetaRow(label: 'Copyright', value: p.copyright, icon: Icons.copyright_rounded),
      if (p.lastRefreshedAt != null)
        MetaRow(label: 'Aktualisiert', value: formatDateTime(p.lastRefreshedAt), icon: Icons.sync_rounded),
      if (p.createdAt != null)
        MetaRow(label: 'Abonniert seit', value: formatDateTime(p.createdAt), icon: Icons.bookmark_added_outlined),
    ];
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Text('Info', style: text.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          ...rows,
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}
