import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/models.dart';
import '../../state/app_state.dart';

final packageInfoProvider = FutureProvider<PackageInfo>((_) => PackageInfo.fromPlatform());

/// `/api/me` of the current session; null when logged out or unreachable.
final serverInfoProvider = FutureProvider<MeInfo?>((ref) async {
  final api = ref.watch(apiClientProvider);
  if (api == null) return null;
  try {
    return await api.me();
  } catch (_) {
    return null;
  }
});

/// Short app version label ("v0.1.0"), tooltip with build number and server version.
class VersionBadge extends ConsumerWidget {
  const VersionBadge({super.key, this.alignEnd = false});
  final bool alignEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pkg = ref.watch(packageInfoProvider).asData?.value;
    final server = ref.watch(serverInfoProvider).asData?.value;
    if (pkg == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final serverLine = server == null
        ? 'Server: nicht verbunden'
        : 'Server: ${server.serverVersion.isEmpty ? 'unbekannt' : server.serverVersion}';
    return Tooltip(
      message: 'App ${pkg.version} (Build ${pkg.buildNumber})\n$serverLine',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          'v${pkg.version}',
          textAlign: alignEnd ? TextAlign.end : TextAlign.center,
          style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ),
    );
  }
}
