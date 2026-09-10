import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/session.dart';
import '../../state/app_state.dart';
import '../theme.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  late final TextEditingController _server;
  late final TextEditingController _user;
  final _pass = TextEditingController();
  late final TextEditingController _device;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final store = ref.read(sessionStoreProvider);
    _server = TextEditingController(text: store.lastBaseUrl);
    _user = TextEditingController(text: store.lastUsername);
    _device = TextEditingController(text: _defaultDeviceName());
  }

  static String _defaultDeviceName() {
    try {
      if (Platform.isWindows) return '${Platform.localHostname} (Windows)';
      if (Platform.isAndroid) return 'Android-Handy';
      return Platform.localHostname;
    } catch (_) {
      return 'Gerät';
    }
  }

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    _pass.dispose();
    _device.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final base = ApiClient.normalizeBaseUrl(_server.text);
    if (base.isEmpty || _user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Bitte Server, Benutzer und Passwort angeben.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await ApiClient.login(
        baseUrl: base,
        username: _user.text.trim(),
        password: _pass.text,
        deviceName: _device.text.trim().isEmpty ? _defaultDeviceName() : _device.text.trim(),
      );
      await ref.read(sessionProvider.notifier).login(Session(
            baseUrl: base,
            token: r.token,
            deviceId: r.deviceId,
            streamToken: r.streamToken,
            username: _user.text.trim(),
            deviceName: _device.text.trim(),
          ));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: AutofillGroup(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.queue_music_rounded, color: Color(0xFF1B1200)),
                      ),
                      const SizedBox(width: 12),
                      Text('CastQueue', style: text.headlineMedium),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('Mit deinem eigenen Server verbinden.',
                      style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _server,
                    keyboardType: TextInputType.url,
                    autofillHints: const [AutofillHints.url],
                    decoration: const InputDecoration(
                      labelText: 'Server-URL',
                      hintText: 'https://pods.example.com',
                      prefixIcon: Icon(Icons.dns_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _user,
                    autofillHints: const [AutofillHints.username],
                    decoration: const InputDecoration(labelText: 'Benutzer', prefixIcon: Icon(Icons.person_rounded)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pass,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _login(),
                    decoration: const InputDecoration(labelText: 'Passwort', prefixIcon: Icon(Icons.lock_rounded)),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _device,
                    onSubmitted: (_) => _login(),
                    decoration: const InputDecoration(labelText: 'Gerätename', prefixIcon: Icon(Icons.devices_rounded)),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: text.bodySmall?.copyWith(color: scheme.error)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _login,
                    child: _busy
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Anmelden'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
