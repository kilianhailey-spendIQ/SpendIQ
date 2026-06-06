import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';

/// Loads an asset image with:
/// - size-aware decoding via cacheWidth/cacheHeight
/// - a lightweight placeholder
/// - an optional cross-fade when the first frame arrives
class OptimizedAssetImage extends StatelessWidget {
  final String assetPath;
  final double width;
  final double height;
  final double borderRadius;
  final BoxFit fit;
  final Alignment alignment;
  final Widget fallback;
  final bool fadeIn;

  const OptimizedAssetImage({
    super.key,
    required this.assetPath,
    required this.width,
    required this.height,
    required this.borderRadius,
    required this.fit,
    this.alignment = Alignment.center,
    required this.fallback,
    this.fadeIn = true,
  });

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    // Large source assets (e.g. multi-megapixel PNG screenshots) can be very
    // expensive to decode on Flutter Web because decoding happens on the main
    // thread. Since we typically *display* these assets at small sizes (logo,
    // preview card), we clamp the decode size aggressively.
    // Keep decode sizes modest. On Flutter Web, decoding is often the primary
    // source of jank because it happens on the main thread.
    const maxDecodeDimensionPx = 768;
    // CRITICAL: width/height can be double.infinity when inside Positioned.fill.
    // Calling .round() on Infinity throws "Unsupported operation: Infinity".
    final safeW = width.isFinite ? width : maxDecodeDimensionPx.toDouble();
    final safeH = height.isFinite ? height : maxDecodeDimensionPx.toDouble();
    final cacheW = math.min((safeW * dpr).round(), maxDecodeDimensionPx);
    final cacheH = math.min((safeH * dpr).round(), maxDecodeDimensionPx);

    final provider = ResizeImage.resizeIfNeeded(
        cacheW > 0 ? cacheW : null, cacheH > 0 ? cacheH : null, AssetImage(assetPath));

    final placeholder = SizedBox(
      width: width.isFinite ? width : null,
      height: height.isFinite ? height : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.14),
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(
                  Theme.of(context).colorScheme.primary.withValues(alpha: 0.9),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: Image(
        image: provider,
        width: width,
        height: height,
        fit: fit,
        alignment: alignment,
        // `ResizeImage` above handles decode-time downscaling; avoid extra work.
        // On web, anything beyond "low" tends to cost noticeably more.
        filterQuality: kIsWeb ? FilterQuality.low : FilterQuality.none,
        isAntiAlias: true,
        gaplessPlayback: true,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          // While bytes are still downloading/decoding, show a cheap placeholder.
          // This avoids blocking first paint and prevents layout jumps.
          return placeholder;
        },
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (!fadeIn || wasSynchronouslyLoaded) return child;
          return AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: child,
          );
        },
        errorBuilder: (context, error, stack) {
          debugPrint('OptimizedAssetImage failed to load $assetPath: $error');
          return fallback;
        },
      ),
    );
  }
}
