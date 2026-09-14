import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/app_update.dart';
import '../../core/diagnostics.dart';
import '../../core/sync_service.dart';
import '../../downloads/download_manager.dart';
import '../../ipod/rockbox_device.dart';
import '../../playback/playback_controller.dart';
import '../../state/app_state.dart';
import '../../state/library.dart';
import '../format.dart';
import '../widgets/app_update_flow.dart';
import '../widgets/version_badge.dart';
import 'devices_screen.dart';
import 'ipod_screen.dart';

const _kRepoUrl = 'https://github.com/$kUpdateRepository';


class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _showDiagnostics(BuildContext context) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Diagnose'),
          content: SizedBox(
            width: 520,
            child: ListenableBuilder(
              listenable: Diagnostics.instance,
              builder: (_, _) {
                final lines = Diagnostics.instance.lines;
                if (lines.isEmpty) return const Text('Noch keine Einträge.');
                return SingleChildScrollView(
                  child: SelectableText(
                    lines.join('\n'),
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: Diagnostics.instance.lines.join('\n')));
                showSnack(ctx, 'Kopiert');
              },
              child: const Text('Kopieren'),
            ),
            TextButton(onPressed: Diagnostics.instance.clear, child: const Text('Leeren')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Schließen')),
          ],
        ),
      );

  Future<void> _logout(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Abmelden?'),
        content: const Text('Der lokale Cache wird gelöscht. Fortschritt und Abos bleiben auf dem Server.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Abmelden')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(playbackControllerProvider.notifier).stop();
    try {
      await ref.read(apiClientProvider)?.logout();
    } catch (_) {}
    await ref.read(sessionProvider.notifier).clear();
  }

  Future<void> _addSonosHost(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController();
    final host = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sonos-IP hinzufügen'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'IP-Adresse', hintText: '192.168.1.50'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Hinzufügen')),
        ],
      ),
    );
    if (host != null && host.isNotEmpty) await ref.read(appPrefsProvider.notifier).addSonosHost(host);
  }

  Future<void> _pickInterval(BuildContext context, WidgetRef ref, int current) async {
    const options = [15, 30, 60, 120, 360];
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Feed-Aktualisierung'),
        children: [
          RadioGroup<int>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final o in options)
                  RadioListTile<int>(
                    value: o,
                    title: Text(o < 60 ? 'alle $o Minuten' : 'alle ${o ~/ 60} Stunden'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (v != null && context.mounted) {
      await guarded(context, () => ref.read(libraryProvider.notifier).updateSettings(refreshIntervalMinutes: v));
    }
  }

  Future<void> _checkForUpdates(BuildContext context, WidgetRef ref) async {
    // On Windows the app exits for the installer: flush progress first.
    final flow = AppUpdateFlow(
      onBeforeInstall: () => ref.read(playbackControllerProvider.notifier).onAppPaused(),
    );
    try {
      await flow.check(context);
    } finally {
      flow.close();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final prefs = ref.watch(appPrefsProvider);
    final lib = ref.watch(libraryProvider);
    final pkg = ref.watch(packageInfoProvider);
    final server = ref.watch(serverInfoProvider);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    Widget section(String title, List<Widget> children) => Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Text(title.toUpperCase(),
                    style: text.labelSmall?.copyWith(color: scheme.primary, letterSpacing: 1.2, fontWeight: FontWeight.w700)),
              ),
              Card(child: Column(children: children)),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Einstellungen'),
        actions: const [Padding(padding: EdgeInsets.only(right: 8), child: Center(child: VersionBadge(alignEnd: true)))],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
            children: [
              section('Server', [
                ListTile(
                  leading: const Icon(Icons.dns_rounded),
                  title: Text(session?.baseUrl ?? ''),
                  subtitle: Text([
                    if (session != null && session.username.isNotEmpty) session.username,
                    if (session != null && session.deviceName.isNotEmpty) session.deviceName,
                  ].join(' · ')),
                ),
                ListTile(
                  leading: const Icon(Icons.sync_rounded),
                  title: const Text('Jetzt synchronisieren'),
                  subtitle: Text(lib.lastSync == null ? 'Noch nie' : 'Zuletzt ${formatDateTime(lib.lastSync)}'),
                  trailing: lib.syncing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : null,
                  onTap: () => ref.read(syncServiceProvider).syncNow(full: true),
                ),
                ListTile(
                  leading: const Icon(Icons.devices_rounded),
                  title: const Text('Geräte verwalten'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DevicesScreen())),
                ),
              ]),
              section('Warteschlange & Feeds', [
                SwitchListTile(
                  secondary: const Icon(Icons.playlist_remove_rounded),
                  title: const Text('Gehörte Folgen automatisch entfernen'),
                  subtitle: const Text('Aus der Warteschlange, sobald eine Folge fertig ist'),
                  value: lib.settings.autoRemovePlayed,
                  onChanged: (v) =>
                      guarded(context, () => ref.read(libraryProvider.notifier).updateSettings(autoRemovePlayed: v)),
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.playlist_add_rounded),
                  title: const Text('Neue Abos: Folgen automatisch einreihen'),
                  subtitle: const Text('Standard für neu hinzugefügte Podcasts'),
                  value: lib.settings.autoEnqueueDefault,
                  onChanged: (v) =>
                      guarded(context, () => ref.read(libraryProvider.notifier).updateSettings(autoEnqueueDefault: v)),
                ),
                ListTile(
                  leading: const Icon(Icons.schedule_rounded),
                  title: const Text('Feed-Aktualisierung auf dem Server'),
                  subtitle: Text(lib.settings.refreshIntervalMinutes < 60
                      ? 'alle ${lib.settings.refreshIntervalMinutes} Minuten'
                      : 'alle ${lib.settings.refreshIntervalMinutes ~/ 60} Stunden'),
                  onTap: () => _pickInterval(context, ref, lib.settings.refreshIntervalMinutes),
                ),
              ]),
              section('Wiedergabe', [
                // Slider and segmented button get their own full-width row:
                // as ListTile trailings they squeezed the title on phones.
                ListTile(
                  leading: const Icon(Icons.speed_rounded),
                  title: const Text('Standard-Geschwindigkeit'),
                  trailing: Text(
                    '${prefs.defaultSpeed.toStringAsFixed(1)}×',
                    style: text.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: Slider(
                    value: prefs.defaultSpeed.clamp(0.8, 2.0),
                    min: 0.8,
                    max: 2.0,
                    divisions: 12,
                    label: '${prefs.defaultSpeed.toStringAsFixed(1)}×',
                    onChanged: (v) => ref.read(playbackControllerProvider.notifier).setSpeed((v * 10).round() / 10),
                  ),
                ),
                const ListTile(
                  leading: Icon(Icons.dark_mode_rounded),
                  title: Text('Design'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    expandedInsets: EdgeInsets.zero,
                    segments: const [
                      ButtonSegment(value: ThemeMode.dark, label: Text('Dunkel')),
                      ButtonSegment(value: ThemeMode.light, label: Text('Hell')),
                      ButtonSegment(value: ThemeMode.system, label: Text('System')),
                    ],
                    selected: {prefs.themeMode},
                    onSelectionChanged: (s) => ref.read(appPrefsProvider.notifier).setThemeMode(s.first),
                  ),
                ),
              ]),
              section('Sonos', [
                ListTile(
                  leading: const Icon(Icons.speaker_group_rounded),
                  title: const Text('Manuelle IP-Adressen'),
                  subtitle: const Text('Falls die automatische Suche im LAN nichts findet'),
                  trailing: IconButton(onPressed: () => _addSonosHost(context, ref), icon: const Icon(Icons.add_rounded)),
                ),
                for (final h in prefs.sonosHosts)
                  ListTile(
                    leading: const SizedBox(width: 24),
                    title: Text(h),
                    trailing: IconButton(
                      onPressed: () => ref.read(appPrefsProvider.notifier).removeSonosHost(h),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
              ]),
              if (downloadsSupported)
                section('Downloads', [
                  SwitchListTile(
                    secondary: const Icon(Icons.download_rounded),
                    title: const Text('Warteschlange automatisch herunterladen'),
                    value: prefs.autoDownload,
                    onChanged: (v) async {
                      await ref.read(appPrefsProvider.notifier).setAutoDownload(v);
                      await ref.read(downloadManagerProvider.notifier).reconcile();
                    },
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.auto_delete_rounded),
                    title: const Text('Downloads automatisch löschen'),
                    subtitle: const Text('Wenn gehört oder aus der Warteschlange entfernt'),
                    value: prefs.autoDeleteDownloads,
                    onChanged: (v) => ref.read(appPrefsProvider.notifier).setAutoDeleteDownloads(v),
                  ),
                ]),
              if (ipodSupported)
                section('iPod', [
                  ListTile(
                    leading: const Icon(Icons.usb_rounded),
                    title: const Text('iPod (Rockbox) synchronisieren'),
                    subtitle: const Text('Folgen mit Cover auf einen Rockbox-Player kopieren'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const IpodScreen())),
                  ),
                ]),
              section('OPML', [
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('Abos exportieren'),
                  subtitle: Text('${session?.baseUrl ?? ''}/api/opml (im Browser, angemeldet)'),
                  trailing: const Icon(Icons.copy_rounded),
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: '${session?.baseUrl ?? ''}/api/opml'));
                    if (context.mounted) showSnack(context, 'URL kopiert');
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.file_upload_outlined),
                  title: const Text('OPML importieren'),
                  subtitle: const Text('OPML-Text aus der Zwischenablage einfügen'),
                  onTap: () async {
                    final data = await Clipboard.getData('text/plain');
                    final xml = data?.text ?? '';
                    if (!context.mounted) return;
                    if (!xml.contains('<opml')) {
                      showSnack(context, 'Kein OPML in der Zwischenablage', error: true);
                      return;
                    }
                    final api = ref.read(apiClientProvider);
                    if (api == null) return;
                    await guarded(context, () async {
                      final r = await api.importOpml(xml);
                      await ref.read(syncServiceProvider).syncNow();
                      if (context.mounted) {
                        showSnack(context,
                            '${r.added} hinzugefügt, ${r.skipped} übersprungen${r.failed.isEmpty ? '' : ', ${r.failed.length} fehlgeschlagen'}');
                      }
                    });
                  },
                ),
              ]),
              section('App', [
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('Version'),
                  subtitle: Text(pkg.when(
                    data: (p) => '${p.version} (Build ${p.buildNumber})',
                    loading: () => '…',
                    error: (_, _) => 'unbekannt',
                  )),
                ),
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Server'),
                  subtitle: Text(server.when(
                    data: (m) => m == null
                        ? 'nicht verbunden'
                        : '${m.serverVersion.isEmpty ? 'Version unbekannt' : m.serverVersion} · ${m.publicUrl}',
                    loading: () => '…',
                    error: (_, _) => 'nicht erreichbar',
                  )),
                  onTap: () => ref.invalidate(serverInfoProvider),
                ),
                ListTile(
                  leading: const Icon(Icons.system_update_alt_rounded),
                  title: const Text('Nach Updates suchen'),
                  subtitle: Text(Platform.isWindows
                      ? 'Lädt das Setup direkt von GitHub und installiert es'
                      : AppUpdateService.supported
                          ? 'Lädt die neue APK direkt von GitHub'
                          : 'Öffnet das neueste Release auf GitHub'),
                  onTap: () => _checkForUpdates(context, ref),
                ),
                ListTile(
                  leading: const Icon(Icons.bug_report_outlined),
                  title: const Text('Diagnose'),
                  subtitle: const Text('Protokoll für Mediensteuerung und Sonos'),
                  onTap: () => _showDiagnostics(context),
                ),
                ListTile(
                  leading: const Icon(Icons.code_rounded),
                  title: const Text('GitHub'),
                  subtitle: const Text(_kRepoUrl),
                  trailing: const Icon(Icons.open_in_new_rounded),
                  onTap: () => launchUrl(Uri.parse(_kRepoUrl), mode: LaunchMode.externalApplication),
                ),
              ]),
              section('Konto', [
                ListTile(
                  leading: Icon(Icons.logout_rounded, color: scheme.error),
                  title: Text('Abmelden', style: TextStyle(color: scheme.error)),
                  onTap: () => _logout(context, ref),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
