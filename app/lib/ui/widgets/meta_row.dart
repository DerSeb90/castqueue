import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../format.dart';

/// Copies [value] and confirms with a snack.
Future<void> copyToClipboard(BuildContext context, String value, {String what = 'Kopiert'}) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (context.mounted) showSnack(context, what);
}

/// Human labels for feed enumerations.
String podcastTypeLabel(String t) => switch (t) {
      'serial' => 'Serie',
      'episodic' => 'Episodisch',
      _ => '',
    };

String episodeTypeLabel(String t) => switch (t) {
      'trailer' => 'Trailer',
      'bonus' => 'Bonus',
      'full' => 'Folge',
      _ => '',
    };

/// Compact key/value line used in the info sections. Tap copies when [copyable];
/// [onTap] wins if given.
class MetaRow extends StatelessWidget {
  const MetaRow({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.copyable = false,
    this.onTap,
    this.mono = false,
    this.maxLines = 2,
  });

  final String label;
  final String value;
  final IconData? icon;
  final bool copyable;
  final VoidCallback? onTap;
  final bool mono;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final tap = onTap ?? (copyable ? () => copyToClipboard(context, value, what: '$label kopiert') : null);
    return InkWell(
      onTap: tap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 8),
            ],
            SizedBox(
              width: 96,
              child: Text(label, style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                value,
                maxLines: maxLines,
                overflow: TextOverflow.ellipsis,
                style: text.bodySmall?.copyWith(
                  color: scheme.onSurface,
                  fontFamily: mono ? 'Consolas' : null,
                  fontFamilyFallback: mono ? const ['Roboto Mono', 'monospace'] : null,
                ),
              ),
            ),
            if (tap != null) ...[
              const SizedBox(width: 6),
              Icon(copyable && onTap == null ? Icons.copy_rounded : Icons.open_in_new_rounded,
                  size: 14, color: scheme.onSurfaceVariant),
            ],
          ],
        ),
      ),
    );
  }
}

/// Key row whose value is a chip wrap (categories, genres).
class MetaChips extends StatelessWidget {
  const MetaChips({super.key, required this.label, required this.values, this.icon});
  final String label;
  final List<String> values;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
          ],
          SizedBox(
            width: 96,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(label, style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final v in values)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    labelStyle: text.labelSmall,
                    label: Text(v),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small pill, e.g. "Explicit", "Trailer".
class MetaBadge extends StatelessWidget {
  const MetaBadge(this.text, {super.key, this.icon, this.color});
  final String text;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 11, color: c), const SizedBox(width: 3)],
          Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: c, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}
