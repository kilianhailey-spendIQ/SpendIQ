import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:spendiq/theme.dart';

/// A reusable glassmorphism-style container.
///
/// Uses a [BackdropFilter] blur with a subtle gradient + border.
/// Keep it purely visual; no business logic should live here.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding,
    this.borderRadius,
    this.backgroundOpacity,
    this.borderColor,
    this.borderWidth,
  });

  final Widget child;
  final EdgeInsets? padding;
  final double? borderRadius;

  /// Optional override for the surface tint opacity.
  final double? backgroundOpacity;

  /// Optional override for border color/width (purely visual).
  ///
  /// Defaults match the previous implementation so existing callers are
  /// unchanged.
  final Color? borderColor;
  final double? borderWidth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = BorderRadius.circular(borderRadius ?? AppRadius.xl);
    final opacity = backgroundOpacity ?? 0.12;
    final effectiveBorderColor = borderColor ?? cs.outline.withValues(alpha: 0.18);
    final effectiveBorderWidth = borderWidth ?? 1;

    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: r,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                cs.onSurface.withValues(alpha: opacity),
                cs.onSurface.withValues(alpha: opacity * 0.55),
              ],
            ),
            border: Border.all(color: effectiveBorderColor, width: effectiveBorderWidth),
          ),
          child: Padding(
            padding: padding ?? const EdgeInsets.all(AppSpacing.lg),
            child: child,
          ),
        ),
      ),
    );
  }
}
