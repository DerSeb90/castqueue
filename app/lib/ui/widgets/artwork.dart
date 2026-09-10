import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Rounded podcast/episode artwork with a graceful placeholder.
class Artwork extends StatelessWidget {
  const Artwork({super.key, required this.url, this.size = 56, this.radius = 10, this.fit = BoxFit.cover});

  final String url;
  final double? size;
  final double radius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = Container(
      color: scheme.surfaceContainerHigh,
      alignment: Alignment.center,
      child: Icon(Icons.podcasts_rounded, color: scheme.onSurfaceVariant.withValues(alpha: 0.5), size: (size ?? 80) * 0.45),
    );
    Widget img;
    if (url.isEmpty || Uri.tryParse(url)?.hasScheme != true) {
      img = placeholder;
    } else {
      img = CachedNetworkImage(
        imageUrl: url,
        fit: fit,
        fadeInDuration: const Duration(milliseconds: 200),
        placeholder: (_, _) => placeholder,
        errorWidget: (_, _, _) => placeholder,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: size == null ? AspectRatio(aspectRatio: 1, child: img) : SizedBox(width: size, height: size, child: img),
    );
  }
}
