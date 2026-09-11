import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../state/app_state.dart';
import '../../state/library.dart';
import '../format.dart';
import '../widgets/artwork.dart';
import '../widgets/meta_row.dart';
import 'podcast_detail_screen.dart';

class AddPodcastScreen extends ConsumerStatefulWidget {
  const AddPodcastScreen({super.key});

  @override
  ConsumerState<AddPodcastScreen> createState() => _AddPodcastScreenState();
}

class _AddPodcastScreenState extends ConsumerState<AddPodcastScreen> {
  final _search = TextEditingController();
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  Timer? _debounce;
  List<SearchResult> _results = const [];
  bool _searching = false;
  bool _adding = false;
  bool _showAuth = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  void _onSearchChanged(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() => _results = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _doSearch(q.trim()));
  }

  Future<void> _doSearch(String q) async {
    final api = ref.read(apiClientProvider);
    if (api == null) return;
    setState(() => _searching = true);
    try {
      final r = await api.search(q);
      if (mounted && _search.text.trim() == q) setState(() => _results = r);
    } catch (e) {
      if (mounted) showSnack(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _add(String feedUrl, {String user = '', String pass = ''}) async {
    if (feedUrl.isEmpty) return;
    setState(() => _adding = true);
    try {
      final p = await ref.read(libraryProvider.notifier).addPodcast(
            feedUrl: feedUrl,
            authUsername: user,
            authPassword: pass,
          );
      if (!mounted) return;
      showSnack(context, '„${p.title}“ abonniert');
      Navigator.of(context).pushReplacement(MaterialPageRoute<void>(builder: (_) => PodcastDetailScreen(podcastId: p.id)));
    } catch (e) {
      if (mounted) showSnack(context, e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final subscribed = ref.watch(libraryProvider.select((s) => s.podcasts.values.map((p) => p.feedUrl).toSet()));

    return Scaffold(
      appBar: AppBar(title: const Text('Podcast hinzufügen')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
            children: [
              TextField(
                controller: _search,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                onSubmitted: (v) => _doSearch(v.trim()),
                decoration: InputDecoration(
                  labelText: 'Suchen (Apple Podcasts)',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 8),
              for (final r in _results)
                _SearchResultCard(
                  result: r,
                  subscribed: subscribed.contains(r.feedUrl),
                  busy: _adding,
                  onAdd: () => _add(r.feedUrl),
                ),
              const SizedBox(height: 24),
              Text('Per Feed-URL', style: text.titleMedium),
              const SizedBox(height: 4),
              Text('Für Premium-Feeds mit Benutzername/Passwort (HTTP Basic Auth) Zugangsdaten angeben.',
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'Feed-URL', prefixIcon: Icon(Icons.rss_feed_rounded)),
                onSubmitted: (_) => _add(_url.text.trim(), user: _user.text.trim(), pass: _pass.text),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _showAuth = !_showAuth),
                  icon: Icon(_showAuth ? Icons.expand_less_rounded : Icons.key_rounded, size: 18),
                  label: Text(_showAuth ? 'Zugangsdaten ausblenden' : 'Zugangsdaten (Premium)'),
                ),
              ),
              if (_showAuth) ...[
                TextField(controller: _user, decoration: const InputDecoration(labelText: 'Benutzername')),
                const SizedBox(height: 8),
                TextField(controller: _pass, obscureText: true, decoration: const InputDecoration(labelText: 'Passwort')),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _adding ? null : () => _add(_url.text.trim(), user: _user.text.trim(), pass: _pass.text),
                icon: _adding
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_rounded),
                label: const Text('Abonnieren'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One iTunes hit: artwork, title, author, genre/count/date line and the RSS
/// feed URL (tap = copy). The info button opens the full metadata sheet.
class _SearchResultCard extends StatelessWidget {
  const _SearchResultCard({
    required this.result,
    required this.subscribed,
    required this.busy,
    required this.onAdd,
  });

  final SearchResult result;
  final bool subscribed;
  final bool busy;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final facts = <String>[
      if (r.genres.isNotEmpty) r.genres.take(2).join(', '),
      if (r.episodeCount > 0) '${r.episodeCount} Folgen',
      if (r.latestReleaseAt != null) formatDate(r.latestReleaseAt),
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _showDetails(context),
        onLongPress: () => _showDetails(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Artwork(url: r.imageUrl, size: 56, radius: 10),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(r.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                        ),
                        if (r.explicit) ...[
                          const SizedBox(width: 6),
                          const MetaBadge('E'),
                        ],
                      ],
                    ),
                    if (r.author.isNotEmpty)
                      Text(r.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600)),
                    if (facts.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(facts.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ),
                    const SizedBox(height: 4),
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => copyToClipboard(context, r.feedUrl, what: 'Feed-URL kopiert'),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: [
                            Icon(Icons.rss_feed_rounded, size: 13, color: scheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                _shortFeed(r.feedUrl),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: text.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                  fontFamily: 'Consolas',
                                  fontFamilyFallback: const ['Roboto Mono', 'monospace'],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Column(
                children: [
                  if (subscribed)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Icon(Icons.check_circle_rounded, color: scheme.primary),
                    )
                  else
                    FilledButton.tonal(
                      onPressed: busy ? null : onAdd,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('Abonnieren'),
                    ),
                  IconButton(
                    tooltip: 'Details',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _showDetails(context),
                    icon: Icon(Icons.info_outline_rounded, size: 20, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _shortFeed(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) return url;
    final path = u.path == '/' ? '' : u.path;
    return '${u.host}$path${u.hasQuery ? '?…' : ''}';
  }

  Future<void> _showDetails(BuildContext context) {
    final r = result;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        final text = Theme.of(ctx).textTheme;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Artwork(url: r.imageUrl, size: 72, radius: 12),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(r.title, style: text.titleLarge),
                          if (r.author.isNotEmpty)
                            Text(r.author, style: text.bodyMedium?.copyWith(color: scheme.primary)),
                          if (r.explicit)
                            const Padding(
                              padding: EdgeInsets.only(top: 6),
                              child: MetaBadge('Explicit', icon: Icons.explicit_rounded),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('RSS-Feed', style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: SelectableText(
                    r.feedUrl,
                    style: text.bodySmall?.copyWith(
                      fontFamily: 'Consolas',
                      fontFamilyFallback: const ['Roboto Mono', 'monospace'],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => copyToClipboard(ctx, r.feedUrl, what: 'Feed-URL kopiert'),
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('Feed-URL kopieren'),
                    ),
                    if (r.itunesUrl.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => launchUrl(Uri.parse(r.itunesUrl), mode: LaunchMode.externalApplication),
                        icon: const Icon(Icons.open_in_new_rounded, size: 16),
                        label: const Text('Apple Podcasts'),
                      ),
                    if (!subscribed)
                      FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () {
                                Navigator.pop(ctx);
                                onAdd();
                              },
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Abonnieren'),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      children: [
                        if (r.genres.isNotEmpty) MetaChips(label: 'Genres', values: r.genres, icon: Icons.category_outlined),
                        if (r.episodeCount > 0)
                          MetaRow(label: 'Folgen', value: '${r.episodeCount}', icon: Icons.format_list_numbered_rounded),
                        if (r.latestReleaseAt != null)
                          MetaRow(
                              label: 'Letzte Folge',
                              value: formatDateTime(r.latestReleaseAt),
                              icon: Icons.schedule_rounded),
                        if (r.country.isNotEmpty) MetaRow(label: 'Land', value: r.country, icon: Icons.public_rounded),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
