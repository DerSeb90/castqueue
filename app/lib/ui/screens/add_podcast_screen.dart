import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/app_state.dart';
import '../../state/library.dart';
import '../format.dart';
import '../widgets/artwork.dart';
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
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: Artwork(url: r.imageUrl, size: 48, radius: 8),
                    title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(r.author, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: subscribed.contains(r.feedUrl)
                        ? Icon(Icons.check_circle_rounded, color: scheme.primary)
                        : FilledButton.tonal(
                            onPressed: _adding ? null : () => _add(r.feedUrl),
                            child: const Text('Abonnieren'),
                          ),
                  ),
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
