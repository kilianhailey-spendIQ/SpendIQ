import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:spendiq/nav.dart';
import 'package:spendiq/components/contact_team_section.dart';
import 'package:spendiq/theme.dart';
import 'package:spendiq/components/optimized_asset_image.dart';
import 'package:spendiq/components/disclaimer_banner.dart';
import 'package:flutter/scheduler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class LandingPage extends StatefulWidget {
  const LandingPage({super.key});

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage> {
  // Expected uploaded assets (safe fallbacks added via errorBuilder)
  static const String _logoPath =
      'assets/images/Screen_Shot_2026-02-09_at_10.29.02_PM.jpg';
  static const String _previewImg = 'assets/images/credit_card.jpg';
  static const String _contactPhoto =
      'assets/images/pexels-edmond-dantes-4345357.jpg';
  static const String _featuresBg =
      'assets/images/pexels-sora-shimazaki-5935744.jpg';
  static const String _glidePhoto =
      'assets/images/pexels-sora-shimazaki-5926252.jpg';

  bool _didPrecache = false;
  late final ScrollController _scrollController;
  User? _currentUser;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _currentUser = Supabase.instance.client.auth.currentUser;
    
    // Listen to auth state changes
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      if (mounted) {
        setState(() => _currentUser = data.session?.user);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didPrecache) return;
    _didPrecache = true;

    // NOTE:
    // We intentionally do NOT precache large assets here.
    // On web and lower-end devices, precaching can block the main thread during
    // startup/hot restart because the decode work still happens on the UI thread.
    // Instead, we rely on OptimizedAssetImage to:
    //  - decode at an appropriate size (cacheWidth/cacheHeight)
    //  - show a lightweight placeholder until the first frame arrives
    //
    // If you ever want to warm images after first paint, do it behind a delay.
    if (!kIsWeb) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        // No-op for now (kept as a hook for future warmup if needed).
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      bottomNavigationBar: const DisclaimerBanner(
        text:
            'SpendIQ recommends strategies based on your data but cannot guarantee results. Users are responsible for their credit card usage.',
      ),
      body: Stack(
        children: [
          // Background gradient texture
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0E1114),
                  Color(0xFF14181C),
                  Color(0xFF0F1418),
                ],
              ),
            ),
          ),
          // Content
          SafeArea(
            child: Scrollbar(
              controller: _scrollController,
              // Attach Scrollbar to the primary scroll view for consistent
              // wheel/trackpad scrolling behavior across platforms.
              interactive: true,
              thickness: 6,
              radius: const Radius.circular(12),
              child: CustomScrollView(
                controller: _scrollController,
                primary: false,
                // Keep cache extent modest so below-the-fold images don't start
                // decoding during first paint.
                cacheExtent: 320,
                physics: const BouncingScrollPhysics(
                    parent: AlwaysScrollableScrollPhysics()),
                slivers: [
                  const SliverPadding(
                    padding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg, vertical: AppSpacing.lg),
                    sliver: SliverToBoxAdapter(child: SizedBox.shrink()),
                  ),

                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.lg, vertical: 0),
                    sliver: SliverToBoxAdapter(
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 940),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Top bar
                              Row(
                                children: [
                                  OptimizedAssetImage(
                                      assetPath: _logoPath,
                                      width: 32,
                                      height: 32,
                                      borderRadius: 12,
                                      fit: BoxFit.cover,
                                      fallback: Container(
                                          width: 32,
                                          height: 32,
                                          decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(12),
                                              gradient: const LinearGradient(
                                                  colors: [
                                                    Color(0xFF2A9D8F),
                                                    Color(0xFF6EE7B7)
                                                  ])),
                                          child: const Icon(
                                              Icons.shield_rounded,
                                              color: Colors.black87,
                                              size: 20))),
                                  const SizedBox(width: 8),
                                  Text('SpendIQ',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.copyWith(
                                              color: const Color(0xFFE0DADA))),
                                  const Spacer(),
                                  IconButton(
                                    onPressed: () => context.go(_currentUser == null ? AppRoutes.auth : AppRoutes.account),
                                    icon: Icon(
                                      _currentUser == null ? Icons.login : Icons.account_circle,
                                      color: const Color(0xFFD2D0D0),
                                    ),
                                    tooltip: _currentUser == null ? 'Sign In' : 'Account',
                                  ),
                                  IconButton(
                                    onPressed: () =>
                                        context.go(AppRoutes.pricing),
                                    icon: const Icon(
                                      Icons.menu_rounded,
                                      color: Color(0xFFD2D0D0),
                                    ),
                                    color: cs.onSurface,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              // Headline
                              Text(
                                'See How Much Value Your Cards Could Unlock ',
                                style: context.textStyles.headlineLarge.bold
                                    .withColor(Colors.white),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Upload your transactions. SpendIQ tells you which card maximizes rewards.',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyLarge
                                    ?.copyWith(color: const Color(0xFF93A3BA)),
                              ),
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  FilledButton.icon(
                                    onPressed: () =>
                                        context.go(AppRoutes.upload),
                                    icon:
                                        const Icon(Icons.file_upload_outlined),
                                    label: const Text('Upload Transactions'),
                                  ),
                                  const SizedBox(width: 12),
                                  Text('100% secure',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelLarge
                                          ?.copyWith(
                                              color: const Color(0xFF93A3BA))),
                                ],
                              ),
                              const SizedBox(height: 1),
                              // Preview card
                              _GlideItem(
                                scrollController: _scrollController,
                                verticalIntensity: 90,
                                child: const _ResultsPreviewCard(
                                    previewImg: _previewImg),
                              ),
                              const SizedBox(height: 20),
                              // Feature tiles
                              _GlideItem(
                                scrollController: _scrollController,
                                verticalIntensity: 76,
                                mobileReserveFactor: 0,
                                child: const _FeatureTile(
                                  icon: Icons.stacked_bar_chart_rounded,
                                  title: 'Maximize Rewards',
                                  subtitle: 'Find the best card for spending',
                                ),
                              ),
                              const SizedBox(height: 10),
                              _GlideItem(
                                scrollController: _scrollController,
                                verticalIntensity: 76,
                                invertDirection: true,
                                mobileReserveFactor: 0,
                                child: const _FeatureTile(
                                  icon: Icons.visibility_rounded,
                                  title: 'See True Value',
                                  subtitle:
                                      'Understand what you’re actually earning',
                                ),
                              ),
                              const SizedBox(height: 10),
                              _GlideItem(
                                scrollController: _scrollController,
                                verticalIntensity: 76,
                                mobileReserveFactor: 0,
                                child: const _FeatureTile(
                                  icon: Icons.auto_awesome_rounded,
                                  title: 'Optimize Your Wallet',
                                  subtitle:
                                      'Get personalized recommendations',
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Key Features (lazy: won't build until user scrolls near it)
                  SliverPadding(
                    // Spacing rules:
                    // - Web/desktop: add a bit of space ABOVE so the section doesn't feel cramped.
                    // - Small phones: give the gliding elements much more vertical “reserve”
                    //   around this section (top + bottom) so transforms never visually overlap.
                    padding: () {
                      final size = MediaQuery.sizeOf(context);
                      final isPhone = size.width < 520;
                      final mobileBreathingRoom =
                          (size.height * 0.20).clamp(60.0, 180.0);
                      return EdgeInsets.only(
                        left: AppSpacing.lg,
                        right: AppSpacing.lg,
                        top: isPhone ? mobileBreathingRoom : 24,
                        bottom: isPhone ? mobileBreathingRoom : 44,
                      );
                    }(),
                    sliver: SliverToBoxAdapter(
                      child: _GlideSection(
                        scrollController: _scrollController,
                        verticalIntensity: 200,
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 940),
                            child: _KeyFeaturesSection(
                              backgroundAssetPath: _featuresBg,
                              scrollController: _scrollController,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // How it works (moved after Key Features)
                  SliverPadding(
                    padding: const EdgeInsets.only(
                        left: AppSpacing.lg,
                        right: AppSpacing.lg,
                        top: 0,
                        bottom: 44),
                    sliver: SliverToBoxAdapter(
                      child: _GlideSection(
                        scrollController: _scrollController,
                        verticalIntensity: 170,
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 940),
                            child: _HowItWorksSection(
                                scrollController: _scrollController),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Upload Tips Section
                  SliverPadding(
                    padding: const EdgeInsets.only(
                        left: AppSpacing.lg,
                        right: AppSpacing.lg,
                        top: 0,
                        bottom: 44),
                    sliver: SliverToBoxAdapter(
                      child: _GlideSection(
                        scrollController: _scrollController,
                        verticalIntensity: 150,
                        invertDirection: true,
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 940),
                            child: _UploadTipsSection(
                                scrollController: _scrollController),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Photo break (glides opposite direction for contrast)
                  SliverPadding(
                    padding: const EdgeInsets.only(
                        left: AppSpacing.lg,
                        right: AppSpacing.lg,
                        top: 0,
                        bottom: 44),
                    sliver: SliverToBoxAdapter(
                      child: _GlideSection(
                        scrollController: _scrollController,
                        verticalIntensity: 150,
                        horizontalIntensity: 44,
                        invertDirection: true,
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 940),
                            child: _GlidePhotoPanel(
                              assetPath: _glidePhoto,
                              scrollController: _scrollController,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Contact (also lazy)
                  SliverPadding(
                    padding: const EdgeInsets.only(
                        left: AppSpacing.lg,
                        right: AppSpacing.lg,
                        top: 0,
                        bottom: 0),
                    sliver: SliverToBoxAdapter(
                      child: _GlideSection(
                        scrollController: _scrollController,
                        verticalIntensity: 140,
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 940),
                            child: Container(
                              padding:
                                  const EdgeInsets.only(top: AppSpacing.xxl),
                              child: const ContactTeamSection(
                                  imageAssetPath: _contactPhoto),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  const SliverPadding(
                    padding: EdgeInsets.only(bottom: 60),
                    sliver: SliverToBoxAdapter(child: SizedBox.shrink()),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      backgroundColor: Color(0xFF637A8F),
    );
  }
}

class _ResultsPreviewCard extends StatelessWidget {
  final String previewImg;
  const _ResultsPreviewCard({required this.previewImg});

  static const String _previewBackgroundImg = 'assets/images/bag.jpg';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Credit-card-like aspect ratio (approx 85.6mm x 54.0mm).
    const cardAspectRatio = 1.586;
    const cardHeight = 86.0;
    final cardWidth = cardHeight * cardAspectRatio;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                // Stronger so it reads as a real background (not a faint cutout).
                opacity: 0.48,
                child: LayoutBuilder(
                  builder: (context, constraints) => OptimizedAssetImage(
                    assetPath: _previewBackgroundImg,
                    width: constraints.maxWidth.isFinite
                        ? constraints.maxWidth
                        : 1,
                    height: constraints.maxHeight.isFinite
                        ? constraints.maxHeight
                        : 1,
                    fit: BoxFit.cover,
                    borderRadius: 0,
                    fallback:
                        Container(color: Colors.white.withValues(alpha: 0.04)),
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      // A bit more contrast for text, but still lets the image show.
                      Colors.black.withValues(alpha: 0.36),
                      Colors.black.withValues(alpha: 0.16),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // No blur: keep the background crisp so it doesn't look like a masked cutout.
          Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(AppRadius.xl),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Your Transaction Results',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Flexible(
                            fit: FlexFit.loose,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                '\$1,472*',
                                maxLines: 1,
                                style: context.textStyles.headlineMedium.bold
                                    .withColor(cs.primary),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Net Value',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelLarge
                                  ?.copyWith(color: cs.primary),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Rewards Earned: \$1,920',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: cs.primary),
                      ),
                      Text(
                        'Annual Fee Paid: \$448',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: cs.primary),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 64,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: const [
                            _Bar(height: 18),
                            SizedBox(width: 6),
                            _Bar(height: 28),
                            SizedBox(width: 6),
                            _Bar(height: 40),
                            SizedBox(width: 6),
                            _Bar(height: 52),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(Icons.credit_card_rounded,
                              size: 18, color: cs.primary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Multi-Card Recommendations *For illustrative purposes only',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(color: const Color(0xFF93A3BA)),
                              softWrap: true,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  child: SizedBox(
                    width: cardWidth,
                    height: cardHeight,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Opacity(
                          opacity: 0.46,
                          child: OptimizedAssetImage(
                            assetPath: _previewBackgroundImg,
                            width: cardWidth,
                            height: cardHeight,
                            borderRadius: 0,
                            fit: BoxFit.cover,
                            fallback: Container(
                                color: Colors.white.withValues(alpha: 0.06)),
                          ),
                        ),
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.10),
                                  Colors.black.withValues(alpha: 0.24),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.all(0),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            child: Transform.scale(
                              // Many card PNG/JPGs ship with a few pixels of safe padding.
                              // Scaling slightly crops that padding to avoid “black strips”
                              // (letterboxing) without affecting the background photo layer.
                              scale: 1.06,
                              child: OptimizedAssetImage(
                                assetPath: previewImg,
                                width: cardWidth,
                                height: cardHeight,
                                borderRadius: 0,
                                fit: BoxFit.cover,
                                fallback: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(AppRadius.md),
                                    color: Colors.white.withValues(alpha: 0.06),
                                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                                  ),
                                  alignment: Alignment.center,
                                  child: Icon(Icons.image_outlined, color: Colors.white.withValues(alpha: 0.35)),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Adds a subtle scroll-linked "glide" effect to landing page sections.
/// The motion eases (fast departure, slow arrival) and is intentionally small
/// to avoid feeling like a gimmick.
class _GlideSection extends StatefulWidget {
  final ScrollController scrollController;
  final Widget child;
  final double verticalIntensity;
  final double horizontalIntensity;
  final bool invertDirection;
  const _GlideSection(
      {required this.scrollController,
      required this.child,
      required this.verticalIntensity,
      this.horizontalIntensity = 0,
      this.invertDirection = false});

  @override
  State<_GlideSection> createState() => _GlideSectionState();
}

/// A lightweight wrapper around [_GlideSection] for animating individual items
/// (feature tiles, steps, etc.) so *everything* participates in the scroll
/// glide—not just the big sections.
class _GlideItem extends StatelessWidget {
  final ScrollController scrollController;
  final Widget child;
  final double verticalIntensity;
  final bool invertDirection;
  /// Mobile-only extra vertical padding factor (relative to [verticalIntensity])
  /// to prevent scroll-linked transforms from visually overlapping.
  ///
  /// Set to `0` to keep spacing tight for stacked elements.
  final double mobileReserveFactor;
  const _GlideItem(
      {required this.scrollController,
      required this.child,
      required this.verticalIntensity,
      this.invertDirection = false,
      this.mobileReserveFactor = 0.10});

  @override
  Widget build(BuildContext context) {
    // On small phones, scroll-linked transforms can make adjacent items
    // temporarily overlap visually (because they translate outside their
    // original layout bounds). Reserve a bit of extra vertical space so each
    // item has room to glide without colliding.
    final w = MediaQuery.sizeOf(context).width;
    final isPhone = w < 520;
    final reserve = (!isPhone || mobileReserveFactor <= 0)
        ? 0.0
        : (verticalIntensity * mobileReserveFactor).clamp(10.0, 26.0);

    return _GlideSection(
      scrollController: scrollController,
      verticalIntensity: verticalIntensity,
      invertDirection: invertDirection,
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: reserve / 2),
        child: child,
      ),
    );
  }
}

class _GlideSectionState extends State<_GlideSection> {
  Offset _computeOffset() {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return Offset.zero;
    final topLeft = ro.localToGlobal(Offset.zero);
    final viewportH = MediaQuery.sizeOf(context).height;
    final centerY = topLeft.dy + ro.size.height / 2;

    // Normalize distance from the visual center of the viewport.
    // Using a smaller denominator makes the effect noticeably stronger.
    final normalized =
        ((centerY - viewportH * 0.52) / (viewportH * 0.70)).clamp(-1.25, 1.25);

    // "Fast departure, slow arrival":
    // - close to center: gentle
    // - away from center: ramps up quickly
    // We also multiply by `normalized` (not just its sign) so the motion keeps
    // increasing as the section travels further from center.
    final t = normalized.abs().clamp(0.0, 1.0);
    final eased = Curves.easeInExpo.transform(t);

    final dir = widget.invertDirection ? -1.0 : 1.0;
    final dy = -normalized * eased * widget.verticalIntensity * dir;

    // A small horizontal drift reads as more cinematic, especially on wide
    // layouts (used for the photo panel).
    final dx =
        normalized * eased * widget.horizontalIntensity * (dir * -1.0);
    return Offset(dx, dy);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.scrollController,
      builder: (context, child) {
        final offset = _computeOffset();
        final intensityMag =
            (widget.verticalIntensity + widget.horizontalIntensity).clamp(1, 999);
        final fade =
            (1.0 - (offset.distance / (intensityMag * 0.95))).clamp(0.0, 1.0);
        // Make "appearance" happen sooner (reach high opacity earlier) without
        // changing scroll speed.
        //
        // Gamma < 1 lifts low values (so it fades in earlier) but keeps
        // 0 -> 0 (so it can still fully disappear off-screen).
        final fastAppear = math.pow(fade, 0.45).toDouble().clamp(0.0, 1.0);
        final opacity = Curves.easeOutExpo.transform(fastAppear);
        // A bit more dramatic so the motion reads even on short sections.
        final scale = 0.94 + 0.06 * fade;
        return RepaintBoundary(
          child: Transform.translate(
            offset: offset,
            child: Transform.scale(
              scale: scale,
              child: Opacity(opacity: opacity, child: child),
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Applies a scroll-linked parallax/zoom effect to photos.
///
/// This is intentionally separate from [_GlideSection] so we can move the
/// *image layer* independently from the content layer (more cinematic and much
/// more noticeable).
class _ScrollLinkedPhotoTransform extends StatefulWidget {
  final ScrollController scrollController;
  final Widget child;
  final double maxTranslateY;
  final double maxTranslateX;
  final bool invertDirection;
  final double baseScale;
  final double extraScale;

  const _ScrollLinkedPhotoTransform({
    required this.scrollController,
    required this.child,
    required this.maxTranslateY,
    this.maxTranslateX = 0,
    this.invertDirection = false,
    this.baseScale = 1.10,
    this.extraScale = 0.08,
  });

  @override
  State<_ScrollLinkedPhotoTransform> createState() =>
      _ScrollLinkedPhotoTransformState();
}

class _ScrollLinkedPhotoTransformState
    extends State<_ScrollLinkedPhotoTransform> {
  double _normalized() {
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return 0;
    final topLeft = ro.localToGlobal(Offset.zero);
    final viewportH = MediaQuery.sizeOf(context).height;
    final centerY = topLeft.dy + ro.size.height / 2;
    return ((centerY - viewportH * 0.52) / (viewportH * 0.78)).clamp(-1.2, 1.2);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.scrollController,
      builder: (context, child) {
        final n = _normalized();
        final t = n.abs().clamp(0.0, 1.0);
        // Faster departure, slower arrival (but for images, make it punchier).
        final eased = Curves.easeInExpo.transform(t);
        final dir = widget.invertDirection ? -1.0 : 1.0;

        // Parallax: translate a fraction of the section motion.
        final dy = n * eased * widget.maxTranslateY * dir;
        final dx = -n * eased * widget.maxTranslateX * dir;

        // Always a bit zoomed-in; zoom increases slightly as it departs.
        final scale = widget.baseScale + widget.extraScale * eased;

        return Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.center,
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _GlidePhotoPanel extends StatelessWidget {
  final String assetPath;
  final ScrollController scrollController;
  const _GlidePhotoPanel({required this.assetPath, required this.scrollController});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final w = MediaQuery.sizeOf(context).width;
    final isPhone = w < 520;
    // Desktop-only layout tweak: spread the caption overlay more evenly across the image.
    final isDesktop = w >= 1024;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.xl),
      child: AspectRatio(
        // Wide + cinematic on larger screens; give phones more height so the
        // bottom-left caption card never overflows.
        aspectRatio: isPhone ? (4 / 3) : (16 / 7),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _ScrollLinkedPhotoTransform(
              scrollController: scrollController,
              // More noticeable parallax for the photo itself.
              maxTranslateY: 72,
              maxTranslateX: 22,
              invertDirection: true,
              // Start slightly zoomed in, then “breathes” as it moves.
              baseScale: 1.12,
              extraScale: 0.10,
              child: OptimizedAssetImage(
                assetPath: assetPath,
                width: 940,
                height: 420,
                borderRadius: 0,
                fit: BoxFit.cover,
                // Heavy crop focus (feel free to adjust if the subject is off).
                alignment: const Alignment(0.25, -0.25),
                fallback: Container(color: Colors.white.withValues(alpha: 0.04)),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.black.withValues(alpha: 0.60),
                    Colors.black.withValues(alpha: 0.18),
                    Colors.black.withValues(alpha: 0.48),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(isPhone ? AppSpacing.md : AppSpacing.lg),
              child: Align(
                alignment: isDesktop ? Alignment.bottomCenter : Alignment.bottomLeft,
                child: FractionallySizedBox(
                  widthFactor: isDesktop ? 0.92 : null,
                  alignment: isDesktop ? Alignment.bottomCenter : Alignment.bottomLeft,
                  child: ConstrainedBox(
                    constraints: isDesktop
                        ? const BoxConstraints()
                        : const BoxConstraints(maxWidth: 560),
                    child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.26),
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      border:
                          Border.all(color: Colors.white.withValues(alpha: 0.12)),
                    ),
                    padding: EdgeInsets.symmetric(
                        horizontal: isPhone ? AppSpacing.md : AppSpacing.lg,
                        vertical: isPhone ? 10 : AppSpacing.md),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            color: cs.primary.withValues(alpha: 0.16),
                            border: Border.all(
                                color: cs.primary.withValues(alpha: 0.22)),
                          ),
                          alignment: Alignment.center,
                          child: Icon(Icons.auto_awesome_rounded,
                              color: cs.primary, size: 18),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Built for everyday card decisions',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: context.textStyles.titleSmall.bold
                                    .withColor(Colors.white),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'See which card wins for groceries, travel, dining, and more — without spreadsheets.',
                                maxLines: isPhone ? 2 : 3,
                                overflow: TextOverflow.ellipsis,
                                style: context.textStyles.bodySmall.withColor(
                                    Colors.white.withValues(alpha: 0.74)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HowItWorksSection extends StatelessWidget {
  final ScrollController scrollController;
  const _HowItWorksSection({required this.scrollController});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _GlideItem(
          scrollController: scrollController,
          verticalIntensity: 70,
          child: Text('How it works',
              style:
                  context.textStyles.titleLarge.bold.withColor(Colors.white)),
        ),
        const SizedBox(height: 10),
        _GlideItem(
          scrollController: scrollController,
          verticalIntensity: 58,
          invertDirection: true,
          child: Text(
            'A simple flow to turn a statement into card-by-card recommendations.',
            style: context.textStyles.bodyMedium
                .withColor(Colors.white.withValues(alpha: 0.72)),
          ),
        ),
        const SizedBox(height: 16),
        _GlideItem(
          scrollController: scrollController,
          verticalIntensity: 88,
          child: const _HowItWorksStep(
            icon: Icons.file_upload_outlined,
            title: '1) Upload',
            subtitle: 'CSV or statement file — takes seconds.',
          ),
        ),
        const SizedBox(height: 10),
        _GlideItem(
          scrollController: scrollController,
          verticalIntensity: 88,
          invertDirection: true,
          child: const _HowItWorksStep(
            icon: Icons.category_outlined,
            title: '2) Categorize',
            subtitle:
                'We map merchants → categories (with debug transparency).',
          ),
        ),
        const SizedBox(height: 10),
        _GlideItem(
          scrollController: scrollController,
          verticalIntensity: 88,
          child: const _HowItWorksStep(
            icon: Icons.workspace_premium_outlined,
            title: '3) Optimize',
            subtitle: 'See which card wins for each category + totals.',
          ),
        ),
      ]),
    );
  }
}

class _HowItWorksStep extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _HowItWorksStep(
      {required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: cs.primary.withValues(alpha: 0.16),
            border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: cs.primary, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style:
                    context.textStyles.titleSmall.bold.withColor(Colors.white)),
            const SizedBox(height: 2),
            Text(subtitle,
                style: context.textStyles.bodySmall
                    .withColor(Colors.white.withValues(alpha: 0.68))),
          ]),
        ),
      ]),
    );
  }
}

class _Bar extends StatelessWidget {
  final double height;
  const _Bar({required this.height});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [cs.primary, cs.inversePrimary],
            ),
          ),
        ),
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _FeatureTile(
      {required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style:
                    context.textStyles.titleSmall.bold.withColor(Colors.white)),
            const SizedBox(height: 2),
            Text(subtitle,
                style: context.textStyles.bodySmall.withColor(Colors.white70)),
          ]),
        ),
      ]),
    );
  }
}

class _KeyFeaturesSection extends StatelessWidget {
  final String backgroundAssetPath;
  final ScrollController scrollController;
  const _KeyFeaturesSection({required this.backgroundAssetPath, required this.scrollController});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final isWide = w >= 760;
        final contentMaxWidth = isWide ? 860.0 : w;

        return ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          child: Stack(
            children: [
              // Background image (fills whatever height the content needs).
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final bgW =
                        (box.maxWidth > 0 ? box.maxWidth : (w > 0 ? w : 940))
                            .toDouble();
                    final bgH =
                        (box.maxHeight > 0 ? box.maxHeight : 560).toDouble();

                    return ClipRect(
                      child: _ScrollLinkedPhotoTransform(
                        scrollController: scrollController,
                        // Keep it subtle-ish but clearly visible.
                        maxTranslateY: isWide ? 54 : 68,
                        maxTranslateX: isWide ? 0 : 10,
                        invertDirection: false,
                        // Always slightly zoomed so the parallax never reveals edges.
                        baseScale: isWide ? 1.06 : 1.20,
                        extraScale: isWide ? 0.06 : 0.08,
                        child: OptimizedAssetImage(
                          assetPath: backgroundAssetPath,
                          width: bgW,
                          height: bgH,
                          borderRadius: 0,
                          fit: BoxFit.cover,
                          fadeIn: true,
                          fallback: Container(
                            color: Colors.white.withValues(alpha: 0.04),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

              // Readability overlay
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.68),
                        Colors.black.withValues(alpha: 0.50),
                        Colors.black.withValues(alpha: 0.64),
                      ],
                    ),
                  ),
                ),
              ),

              // Content (drives the section height so tiles + CTA never overlap).
              Padding(
                padding: EdgeInsets.all(isWide ? AppSpacing.xl : AppSpacing.lg),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: contentMaxWidth),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: isWide ? 560 : 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            'KEY FEATURES',
                            style:
                                context.textStyles.labelLarge.semiBold.copyWith(
                              letterSpacing: 1.2,
                              color: Colors.white.withValues(alpha: 0.75),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            'Effortless card analysis\nfor personal spending',
                            textAlign: TextAlign.center,
                            style: context.textStyles.displaySmall.bold
                                .withColor(Colors.white)
                                .copyWith(height: 1.05),
                          ),
                          const SizedBox(height: 22),
                          Align(
                            alignment: Alignment.topCenter,
                            child: _KeyFeaturesGrid(
                                isWide: isWide,
                                scrollController: scrollController),
                          ),
                          const SizedBox(height: 18),
                          SizedBox(
                            width: isWide ? 220 : double.infinity,
                            child: FilledButton(
                              onPressed: () => context.go(AppRoutes.upload),
                              style: FilledButton.styleFrom(
                                backgroundColor: cs.primary,
                                foregroundColor: cs.onPrimary,
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(14),
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.flash_on_rounded,
                                      color: cs.onPrimary, size: 18),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Start now',
                                    style: context
                                        .textStyles.labelLarge.semiBold
                                        .withColor(cs.onPrimary),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _KeyFeaturesGrid extends StatelessWidget {
  final bool isWide;
  final ScrollController scrollController;
  const _KeyFeaturesGrid({required this.isWide, required this.scrollController});

  @override
  Widget build(BuildContext context) {
    final features = const [
      _KeyFeature(
        icon: Icons.file_upload_outlined,
        title: 'PDF statement upload',
        subtitle:
            'Upload your credit card PDFs for fast, automated extraction.',
      ),
      _KeyFeature(
        icon: Icons.stacked_bar_chart_rounded,
        title: 'Spending pattern review',
        subtitle: 'Analyze transactions to uncover trends and habits.',
      ),
      _KeyFeature(
        icon: Icons.table_chart_outlined,
        title: 'Spreadsheet data matching',
        subtitle:
            'Compare your history with curated card data for precise results.',
      ),
      _KeyFeature(
        icon: Icons.check_circle_outline_rounded,
        title: 'Tailored recommendations',
        subtitle: 'Get options matched to your spending habits.',
      ),
      _KeyFeature(
        icon: Icons.lock_outline_rounded,
        title: 'Confidential security',
        subtitle: 'All financial data is encrypted and handled securely.',
      ),
      _KeyFeature(
        icon: Icons.auto_awesome_rounded,
        title: 'Maximize rewards',
        subtitle: 'Find cards that maximize rewards and benefits.',
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = isWide ? 3 : 1;
        final tileW = (constraints.maxWidth - (columns - 1) * 16) / columns;

        return Wrap(
          alignment: WrapAlignment.center,
          runAlignment: WrapAlignment.start,
          spacing: 16,
          runSpacing: 16,
          children: [
            for (var i = 0; i < features.length; i++)
              SizedBox(
                width: tileW,
                child: _GlideItem(
                  scrollController: scrollController,
                  verticalIntensity: isWide ? 72 : 92,
                  invertDirection: i.isOdd,
                  child: _KeyFeatureTile(feature: features[i]),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _KeyFeature {
  final IconData icon;
  final String title;
  final String subtitle;
  const _KeyFeature(
      {required this.icon, required this.title, required this.subtitle});
}

class _KeyFeatureTile extends StatelessWidget {
  final _KeyFeature feature;
  const _KeyFeatureTile({required this.feature});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.30),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: cs.primary.withValues(alpha: 0.22),
              border: Border.all(color: cs.primary.withValues(alpha: 0.22)),
            ),
            alignment: Alignment.center,
            child: Icon(feature.icon, color: cs.primary, size: 22),
          ),
          const SizedBox(height: 10),
          Text(
            feature.title,
            textAlign: TextAlign.center,
            style: context.textStyles.titleSmall.semiBold
                .withColor(Colors.white)
                .copyWith(height: 1.2),
          ),
          const SizedBox(height: 6),
          Text(
            feature.subtitle,
            textAlign: TextAlign.center,
            style: context.textStyles.bodySmall
                .withColor(Colors.white.withValues(alpha: 0.78))
                .copyWith(height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _UploadTipsSection extends StatelessWidget {
  final ScrollController scrollController;
  const _UploadTipsSection({required this.scrollController});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: cs.primary.withValues(alpha: 0.16),
                  border: Border.all(color: cs.primary.withValues(alpha: 0.22)),
                ),
                child: Icon(Icons.lightbulb_outline, color: cs.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Upload Tips',
                  style: context.textStyles.titleLarge.bold.withColor(Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Having trouble uploading PDFs on iPhone? Follow these tips:',
            style: context.textStyles.bodyMedium.withColor(Colors.white.withValues(alpha: 0.85)),
          ),
          const SizedBox(height: 16),
          _GlideItem(
            scrollController: scrollController,
            verticalIntensity: 70,
            child: _UploadTip(
              icon: Icons.download_outlined,
              title: 'Save to Files app first',
              subtitle: 'Download your credit card statement PDF and save it to the Files app on your iPhone. Browser-saved PDFs may not work correctly.',
            ),
          ),
          const SizedBox(height: 10),
          _GlideItem(
            scrollController: scrollController,
            verticalIntensity: 70,
            invertDirection: true,
            child: _UploadTip(
              icon: Icons.folder_open,
              title: 'Upload from Files',
              subtitle: 'When prompted to select a file, choose "Browse" or "Files" instead of selecting directly from a browser like Edge or Safari.',
            ),
          ),
          const SizedBox(height: 10),
          _GlideItem(
            scrollController: scrollController,
            verticalIntensity: 70,
            child: _UploadTip(
              icon: Icons.picture_as_pdf,
              title: 'Use actual PDF files',
              subtitle: 'Make sure the file is a true PDF credit card statement, not a screenshot or web page saved as PDF.',
            ),
          ),
          const SizedBox(height: 10),
          _GlideItem(
            scrollController: scrollController,
            verticalIntensity: 70,
            invertDirection: true,
            child: _UploadTip(
              icon: Icons.delete_outline,
              title: 'Remove conflicting apps',
              subtitle: 'If PDFs keep opening in Edge or another browser, consider temporarily removing that app to force the Files app to be used.',
            ),
          ),
        ],
      ),
    );
  }
}

class _UploadTip extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _UploadTip({required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: cs.primary.withValues(alpha: 0.16),
              border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: cs.primary, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.textStyles.titleSmall.bold.withColor(Colors.white)),
                const SizedBox(height: 2),
                Text(subtitle, style: context.textStyles.bodySmall.withColor(Colors.white.withValues(alpha: 0.68))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
