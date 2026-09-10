import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../playback/playback_controller.dart';
import '../../state/app_state.dart';
import '../format.dart';

/// Bottom sheet to pick the playback output (this device or a Sonos room).
class OutputPicker extends ConsumerStatefulWidget {
  const OutputPicker({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        constraints: const BoxConstraints(maxWidth: 520),
        builder: (_) => const OutputPicker(),
      );

  @override
  ConsumerState<OutputPicker> createState() => _OutputPickerState();
}

class _OutputPickerState extends ConsumerState<OutputPicker> {
  @override
  void initState() {
    super.initState();
    final s = ref.read(playbackControllerProvider);
    if (s.sonosDevices.isEmpty && !s.discovering) {
      Future.microtask(() => ref.read(playbackControllerProvider.notifier).discoverSonos());
    }
  }

  Future<void> _addManual() async {
    final c = TextEditingController();
    final host = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sonos-IP hinzufügen'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'IP-Adresse', hintText: '192.168.1.50'),
          keyboardType: TextInputType.url,
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Hinzufügen')),
        ],
      ),
    );
    if (host == null || host.isEmpty) return;
    await ref.read(appPrefsProvider.notifier).addSonosHost(host);
    if (mounted) await ref.read(playbackControllerProvider.notifier).discoverSonos();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(playbackControllerProvider);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final ctl = ref.read(playbackControllerProvider.notifier);
    final localName = Platform.isWindows ? 'Dieser PC' : 'Dieses Gerät';

    Widget tile({required String id, required String name, required IconData icon, String? subtitle}) {
      final selected = s.targetId == id;
      return ListTile(
        leading: Icon(icon, color: selected ? scheme.primary : null),
        title: Text(name, style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: selected ? Icon(Icons.check_rounded, color: scheme.primary) : null,
        onTap: () async {
          Navigator.of(context).pop();
          await guarded(context, () => ctl.selectTarget(id));
        },
      );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Wiedergabe auf', style: text.titleLarge)),
                if (s.discovering)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else
                  IconButton(tooltip: 'Sonos suchen', onPressed: ctl.discoverSonos, icon: const Icon(Icons.refresh_rounded)),
                IconButton(tooltip: 'IP manuell', onPressed: _addManual, icon: const Icon(Icons.add_rounded)),
              ],
            ),
            const SizedBox(height: 8),
            tile(id: 'local', name: localName, icon: Platform.isWindows ? Icons.computer_rounded : Icons.smartphone_rounded),
            if (s.sonosDevices.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('SONOS', style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 1.2)),
              ),
              for (final d in s.sonosDevices)
                tile(id: 'sonos:${d.uuid}', name: d.roomName, icon: Icons.speaker_rounded, subtitle: '${d.modelName} · ${d.host}'),
            ] else if (!s.discovering)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Keine Sonos-Lautsprecher gefunden. Gleiches WLAN? Sonst IP manuell hinzufügen.',
                    style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ),
          ],
        ),
      ),
    );
  }
}
