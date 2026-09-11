import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ipod/ipod_selection.dart';
import '../../ipod/ipod_sync.dart';
import '../../ipod/rockbox_device.dart';
import '../../state/library.dart';
import '../format.dart';

/// Windows-only: copy a selection of episodes to a Rockbox player (iPod
/// Classic etc.), keep a manifest, write a playlist, read back listening
/// state from Rockbox's database changelog.
class IpodScreen extends ConsumerStatefulWidget {
  const IpodScreen({super.key});

  @override
  ConsumerState<IpodScreen> createState() => _IpodScreenState();
}

class _IpodScreenState extends ConsumerState<IpodScreen> {
  List<RockboxDevice> _devices = const [];
  bool _scanning = false;
  final _manual = TextEditingController();

  @override
  void initState() {
    super.initState();
    _manual.text = ref.read(ipodSelectionProvider).manualRoot ?? '';
    Future.microtask(_scan);
  }

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    try {
      final found = await RockboxDevice.scanDrives();
      final manual = ref.read(ipodSelectionProvider).manualRoot;
      if (manual != null && manual.isNotEmpty && !found.any((d) => d.root == manual)) {
        try {
          found.add(await RockboxDevice.fromPath(manual, label: 'Ordner'));
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _devices = found);
      final sync = ref.read(ipodSyncProvider.notifier);
      final current = ref.read(ipodSyncProvider).device;
      if (current == null && found.isNotEmpty) sync.selectDevice(found.first);
      if (current != null && !found.any((d) => d.root == current.root)) sync.selectDevice(null);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _useManual() async {
    final path = _manual.text.trim();
    if (path.isEmpty) return;
    try {
      final dev = await RockboxDevice.fromPath(path, label: 'Ordner');
      await ref.read(ipodSelectionProvider.notifier).update(ref.read(ipodSelectionProvider).copyWith(manualRoot: dev.root));
      if (!mounted) return;
      setState(() {
        _devices = [..._devices.where((d) => d.root != dev.root), dev];
      });
      ref.read(ipodSyncProvider.notifier).selectDevice(dev);
    } catch (e) {
      if (mounted) showSnack(context, e.toString(), error: true);
    }
  }

  Future<void> _import() async {
    final msg = await ref.read(ipodSyncProvider.notifier).importChangelog();
    if (mounted) showSnack(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    final sync = ref.watch(ipodSyncProvider);
    final sel = ref.watch(ipodSelectionProvider);
    final selN = ref.read(ipodSelectionProvider.notifier);
    final podcasts = ref.watch(podcastsProvider);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final dev = sync.device;

    Widget section(String title, List<Widget> children, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(title.toUpperCase(),
                          style: text.labelSmall
                              ?.copyWith(color: scheme.primary, letterSpacing: 1.2, fontWeight: FontWeight.w700)),
                    ),
                    ?trailing,
                  ],
                ),
              ),
              Card(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children)),
            ],
          ),
        );

    final overCapacity = dev?.freeBytes != null && sync.plan.bytesToCopy - sync.plan.bytesToDelete > dev!.freeBytes!;

    return Scaffold(
      appBar: AppBar(title: const Text('iPod (Rockbox)')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
            children: [
              section(
                'Gerät',
                [
                  if (_devices.isEmpty)
                    ListTile(
                      leading: const Icon(Icons.usb_off_rounded),
                      title: const Text('Kein Rockbox-Gerät gefunden'),
                      subtitle: const Text('Laufwerk mit „.rockbox“-Ordner anschließen oder unten einen Ordner angeben.'),
                    )
                  else
                    RadioGroup<String>(
                      groupValue: dev?.root,
                      onChanged: (root) => ref
                          .read(ipodSyncProvider.notifier)
                          .selectDevice(_devices.firstWhere((d) => d.root == root)),
                      child: Column(
                        children: [
                          for (final d in _devices)
                            RadioListTile<String>(
                              value: d.root,
                              title: Text('${d.label} · ${d.root}'),
                              subtitle: Text([
                                if (d.version.isNotEmpty) 'Rockbox ${d.version}',
                                if (d.freeBytes != null && d.totalBytes != null)
                                  '${formatBytes(d.freeBytes!)} frei von ${formatBytes(d.totalBytes!)}',
                              ].join(' · ')),
                            ),
                        ],
                      ),
                    ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _manual,
                            decoration: const InputDecoration(
                              labelText: 'Ordner (Test oder manuell)',
                              hintText: r'D:\fake-ipod  – muss einen .rockbox-Ordner enthalten',
                              prefixIcon: Icon(Icons.folder_open_rounded),
                            ),
                            onSubmitted: (_) => _useManual(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(onPressed: _useManual, child: const Text('Verwenden')),
                      ],
                    ),
                  ),
                ],
                trailing: IconButton(
                  tooltip: 'Neu suchen',
                  onPressed: _scanning ? null : _scan,
                  icon: _scanning
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.refresh_rounded, size: 20),
                ),
              ),
              section('Auswahl', [
                SwitchListTile(
                  secondary: const Icon(Icons.queue_music_rounded),
                  title: const Text('Warteschlange'),
                  subtitle: const Text('Alle ungehörten Folgen der Warteschlange, in Reihenfolge'),
                  value: sel.includeQueue,
                  onChanged: (v) => selN.update(sel.copyWith(includeQueue: v)),
                ),
                if (podcasts.isNotEmpty) const Divider(),
                for (final p in podcasts)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.podcasts_rounded),
                    title: Text(p.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: const Text('neueste ungehörte Folgen'),
                    trailing: DropdownButton<int>(
                      value: sel.perPodcastLatest[p.id] ?? 0,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('–')),
                        DropdownMenuItem(value: 1, child: Text('1')),
                        DropdownMenuItem(value: 2, child: Text('2')),
                        DropdownMenuItem(value: 3, child: Text('3')),
                        DropdownMenuItem(value: 5, child: Text('5')),
                        DropdownMenuItem(value: 10, child: Text('10')),
                      ],
                      onChanged: (v) => selN.setPodcastLatest(p.id, v ?? 0),
                    ),
                  ),
              ]),
              section('Optionen', [
                SwitchListTile(
                  secondary: const Icon(Icons.image_rounded),
                  title: const Text('Cover in MP3 einbetten'),
                  subtitle: const Text('200×200 JPEG im ID3-Tag'),
                  value: sel.embedCover,
                  onChanged: (v) => selN.update(sel.copyWith(embedCover: v)),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.folder_rounded),
                  title: const Text('cover.jpg pro Podcast-Ordner'),
                  subtitle: const Text('Für M4A/OGG, die kein eingebettetes Cover bekommen'),
                  value: sel.folderCover,
                  onChanged: (v) => selN.update(sel.copyWith(folderCover: v)),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.playlist_play_rounded),
                  title: const Text('Playlist „CastQueue.m3u8“ schreiben'),
                  value: sel.writePlaylist,
                  onChanged: (v) => selN.update(sel.copyWith(writePlaylist: v)),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.check_circle_outline_rounded),
                  title: const Text('Gehörte Folgen löschen'),
                  value: sel.removePlayed,
                  onChanged: (v) => selN.update(sel.copyWith(removePlayed: v)),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.playlist_remove_rounded),
                  title: const Text('Nicht mehr ausgewählte Folgen löschen'),
                  subtitle: const Text('Sonst bleiben sie auf dem iPod, bis sie gehört sind'),
                  value: sel.removeUnselected,
                  onChanged: (v) => selN.update(sel.copyWith(removeUnselected: v)),
                ),
              ]),
              section(
                'Plan',
                [
                  if (sync.phase == IpodPhase.idle || sync.plan.isEmpty && sync.phase == IpodPhase.ready)
                    ListTile(
                      leading: const Icon(Icons.info_outline_rounded),
                      title: Text(sync.phase == IpodPhase.ready ? 'Nichts zu tun – iPod ist aktuell.' : 'Noch kein Plan.'),
                    ),
                  if (sync.plan.copy.isNotEmpty)
                    _PlanGroup(
                      title: 'Kopieren',
                      icon: Icons.download_rounded,
                      color: scheme.primary,
                      items: sync.plan.copy,
                      bytes: sync.plan.bytesToCopy,
                    ),
                  if (sync.plan.delete.isNotEmpty)
                    _PlanGroup(
                      title: 'Löschen',
                      icon: Icons.delete_outline_rounded,
                      color: scheme.error,
                      items: sync.plan.delete,
                      bytes: sync.plan.bytesToDelete,
                    ),
                  if (sync.plan.keep.isNotEmpty)
                    _PlanGroup(
                      title: 'Bleibt',
                      icon: Icons.check_rounded,
                      color: scheme.onSurfaceVariant,
                      items: sync.plan.keep,
                      bytes: sync.plan.keep.fold(0, (a, b) => a + b.size),
                      collapsed: true,
                    ),
                  if (overCapacity)
                    ListTile(
                      leading: Icon(Icons.warning_amber_rounded, color: scheme.error),
                      title: Text('Nicht genug Platz', style: TextStyle(color: scheme.error)),
                      subtitle: Text(
                          '${formatBytes(sync.plan.bytesToCopy)} nötig, ${formatBytes(dev.freeBytes! + sync.plan.bytesToDelete)} frei'),
                    ),
                ],
                trailing: TextButton.icon(
                  onPressed: dev == null || sync.busy ? null : () => ref.read(ipodSyncProvider.notifier).makePlan(),
                  icon: const Icon(Icons.rule_rounded, size: 18),
                  label: const Text('Plan erstellen'),
                ),
              ),
              section('Sync', [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          FilledButton.icon(
                            onPressed: dev == null || sync.busy || sync.phase != IpodPhase.ready || sync.plan.isEmpty
                                ? null
                                : () => ref.read(ipodSyncProvider.notifier).run(),
                            icon: const Icon(Icons.sync_rounded),
                            label: const Text('Synchronisieren'),
                          ),
                          const SizedBox(width: 8),
                          if (sync.phase == IpodPhase.syncing)
                            OutlinedButton(
                              onPressed: () => ref.read(ipodSyncProvider.notifier).cancel(),
                              child: const Text('Abbrechen'),
                            ),
                        ],
                      ),
                      if (sync.phase == IpodPhase.syncing || sync.phase == IpodPhase.done) ...[
                        const SizedBox(height: 12),
                        LinearProgressIndicator(value: sync.progress),
                        const SizedBox(height: 6),
                        Text(sync.current, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        if (sync.phase == IpodPhase.syncing && sync.fileProgress >= 0) ...[
                          const SizedBox(height: 4),
                          LinearProgressIndicator(value: sync.fileProgress, minHeight: 2),
                        ],
                      ],
                      if (sync.error != null) ...[
                        const SizedBox(height: 8),
                        Text(sync.error!, style: text.bodySmall?.copyWith(color: scheme.error)),
                      ],
                      if (sync.log.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Container(
                          constraints: const BoxConstraints(maxHeight: 180),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          padding: const EdgeInsets.all(10),
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final l in sync.log.reversed)
                                Text(l, style: text.bodySmall?.copyWith(fontFamily: 'Consolas', height: 1.4)),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ]),
              section('Rückkanal', [
                ListTile(
                  leading: const Icon(Icons.history_rounded),
                  title: const Text('Gehört-Status vom iPod einlesen'),
                  subtitle: const Text('Auf dem iPod: Database → Export modifications, dann hier einlesen. '
                      'Positionen und gehörte Folgen werden zum Server übertragen.'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: dev == null || sync.busy ? null : _import,
                ),
              ]),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Rockbox-Einstellungen für Podcasts: Settings → Playback → Automatic Resume: Yes, '
                  'Resume paths: /Podcasts · Settings → General → Database → Gather Runtime Data: Yes, '
                  'einmal Initialize Now.',
                  style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanGroup extends StatefulWidget {
  const _PlanGroup({
    required this.title,
    required this.icon,
    required this.color,
    required this.items,
    required this.bytes,
    this.collapsed = false,
  });

  final String title;
  final IconData icon;
  final Color color;
  final List<PlanItem> items;
  final int bytes;
  final bool collapsed;

  @override
  State<_PlanGroup> createState() => _PlanGroupState();
}

class _PlanGroupState extends State<_PlanGroup> {
  late bool _open = !widget.collapsed;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          leading: Icon(widget.icon, color: widget.color),
          title: Text('${widget.title} · ${widget.items.length}'),
          subtitle: widget.bytes > 0 ? Text(formatBytes(widget.bytes)) : null,
          trailing: Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded),
          onTap: () => setState(() => _open = !_open),
        ),
        if (_open)
          for (final it in widget.items)
            ListTile(
              dense: true,
              leading: const SizedBox(width: 24),
              title: Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [
                  if (it.podcastTitle.isNotEmpty) it.podcastTitle,
                  if (it.size > 0) formatBytes(it.size),
                  if (it.reason.isNotEmpty) it.reason,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
      ],
    );
  }
}
