import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../state/app_state.dart';
import '../format.dart';

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});

  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  List<DeviceInfo>? _devices;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(apiClientProvider);
    if (api == null) return;
    try {
      final d = await api.devices();
      if (mounted) setState(() => _devices = d);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _delete(DeviceInfo d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Gerät abmelden?'),
        content: Text(d.current
            ? 'Das ist dieses Gerät – du wirst abgemeldet.'
            : '„${d.name}“ verliert den Zugriff und muss sich neu anmelden.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Abmelden')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final api = ref.read(apiClientProvider);
    if (api == null) return;
    final done = await guarded(context, () => api.deleteDevice(d.id));
    if (!done) return;
    if (d.current) {
      await ref.read(sessionProvider.notifier).clear();
    } else {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final devices = _devices;
    return Scaffold(
      appBar: AppBar(title: const Text('Geräte')),
      body: _error != null
          ? Center(child: Text(_error!, style: TextStyle(color: scheme.error)))
          : devices == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final d in devices)
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Icon(d.current ? Icons.phonelink_ring_rounded : Icons.devices_rounded,
                                color: d.current ? scheme.primary : null),
                            title: Text(d.name.isEmpty ? 'Unbenannt' : d.name),
                            subtitle: Text([
                              if (d.current) 'Dieses Gerät',
                              if (d.lastSeenAt != null) 'zuletzt ${formatDateTime(d.lastSeenAt)}',
                              if (d.createdAt != null) 'seit ${formatDate(d.createdAt)}',
                            ].join(' · ')),
                            trailing: IconButton(
                              tooltip: 'Abmelden',
                              onPressed: () => _delete(d),
                              icon: const Icon(Icons.logout_rounded),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }
}
