import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:spendiq/nav.dart';
import 'package:spendiq/theme.dart';
import 'package:spendiq/components/disclaimer_banner.dart';
import 'package:url_launcher/url_launcher.dart';

class PricingPage extends StatefulWidget {
  const PricingPage({super.key});

  @override
  State<PricingPage> createState() => _PricingPageState();
}

class _PricingPageState extends State<PricingPage> with SingleTickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  late AnimationController _waveController;

  @override
  void initState() {
    super.initState();
    _waveController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _waveController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text('Choose your plan', style: TextStyle(color: Color(0xFF1F2937), fontWeight: FontWeight.w700)),
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close, color: Color(0xFF1F2937)),
          onPressed: () => context.go(AppRoutes.landing),
        ),
      ),
      bottomNavigationBar: const DisclaimerBanner(
        text:
            'SpendIQ recommends strategies based on your data but cannot guarantee results. Users are responsible for their credit card usage and any associated risks.',
      ),
      body: Stack(
        children: [
          // Animated wave background
          AnimatedBuilder(
            animation: _waveController,
            builder: (context, child) => CustomPaint(
              painter: WaveBackgroundPainter(
                animationValue: _waveController.value,
              ),
              child: Container(),
            ),
          ),
          // Content
          Scrollbar(
            controller: _scrollController,
            interactive: true,
            thickness: 6,
            radius: const Radius.circular(12),
            child: SingleChildScrollView(
              controller: _scrollController,
              primary: false,
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: LayoutBuilder(builder: (context, c) {
                    final isWide = c.maxWidth > 900;
                    final children = [
                      _PlanCard(
                        title: 'Free',
                        price: '\$0',
                        features: const ['1 credit card upload', '1 recommendation', 'Basic breakdown'],
                        cta: 'Start Free',
                        onTap: () => context.go(AppRoutes.upload),
                        isPremium: false,
                      ),
                      _PlanCard(
                        title: 'Annually',
                        price: '\$19 / year',
                        features: const ['Unlimited credit card uploads', 'Unlimited OptimIQ simulations', '1 person'],
                        cta: 'Unlock Pro',
                        onTap: () async {
                          final url = Uri.parse('https://buy.stripe.com/aFadR36M8eCu0HU7UU');
                          if (await canLaunchUrl(url)) {
                            await launchUrl(url, mode: LaunchMode.externalApplication);
                          }
                        },
                        isPremium: true,
                      ),
                    ];

                    if (isWide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: children.map((e) => Expanded(child: e)).toList(),
                      );
                    }

                    return Column(
                      children: [
                        for (int i = 0; i < children.length; i++) ...[
                          if (i != 0) const SizedBox(height: 16),
                          children[i],
                        ],
                      ],
                    );
                  }),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class WaveBackgroundPainter extends CustomPainter {
  final double animationValue;

  WaveBackgroundPainter({required this.animationValue});

  @override
  void paint(Canvas canvas, Size size) {
    // Ribbon 1 - Purple gradient
    final paint1 = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0x0A6366F1),
          const Color(0x0F6366F1),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    // Ribbon 2 - Indigo gradient
    final paint2 = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [
          const Color(0x088B5CF6),
          const Color(0x0D8B5CF6),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    // Ribbon 3 - Teal gradient
    final paint3 = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          const Color(0x0806B6D4),
          const Color(0x0C06B6D4),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    // Ribbon 4 - Light purple gradient
    final paint4 = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [
          const Color(0x07A78BFA),
          const Color(0x0AA78BFA),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    // Smooth flowing ribbon 1 (top-middle)
    final path1 = Path();
    final wave1Offset = animationValue * size.width * 0.5;
    path1.moveTo(0, size.height * 0.2);
    
    final numWaves1 = 3;
    final waveWidth1 = size.width / numWaves1;
    for (int i = 0; i < numWaves1; i++) {
      final x = i * waveWidth1;
      final peakY = size.height * 0.15 + math.sin((i + animationValue * 2 * math.pi) * 0.8) * 30;
      final troughY = size.height * 0.25 + math.cos((i + animationValue * 2 * math.pi) * 0.8) * 30;
      
      path1.quadraticBezierTo(
        x + waveWidth1 * 0.25 + wave1Offset,
        peakY,
        x + waveWidth1 * 0.5 + wave1Offset,
        (peakY + troughY) / 2,
      );
      path1.quadraticBezierTo(
        x + waveWidth1 * 0.75 + wave1Offset,
        troughY,
        x + waveWidth1 + wave1Offset,
        size.height * 0.2,
      );
    }
    
    path1.lineTo(size.width, size.height);
    path1.lineTo(0, size.height);
    path1.close();
    canvas.drawPath(path1, paint1);

    // Smooth flowing ribbon 2 (middle)
    final path2 = Path();
    final wave2Offset = animationValue * size.width * 0.3;
    path2.moveTo(0, size.height * 0.5);
    
    final numWaves2 = 4;
    final waveWidth2 = size.width / numWaves2;
    for (int i = 0; i < numWaves2; i++) {
      final x = i * waveWidth2;
      final peakY = size.height * 0.45 + math.sin((i + animationValue * 2 * math.pi) * 1.2) * 40;
      final troughY = size.height * 0.55 + math.cos((i + animationValue * 2 * math.pi) * 1.2) * 40;
      
      path2.quadraticBezierTo(
        x + waveWidth2 * 0.25 - wave2Offset,
        peakY,
        x + waveWidth2 * 0.5 - wave2Offset,
        (peakY + troughY) / 2,
      );
      path2.quadraticBezierTo(
        x + waveWidth2 * 0.75 - wave2Offset,
        troughY,
        x + waveWidth2 - wave2Offset,
        size.height * 0.5,
      );
    }
    
    path2.lineTo(size.width, size.height);
    path2.lineTo(0, size.height);
    path2.close();
    canvas.drawPath(path2, paint2);

    // Smooth flowing ribbon 3 (lower-middle)
    final path3 = Path();
    final wave3Offset = animationValue * size.width * 0.4;
    path3.moveTo(0, size.height * 0.7);
    
    final numWaves3 = 3;
    final waveWidth3 = size.width / numWaves3;
    for (int i = 0; i < numWaves3; i++) {
      final x = i * waveWidth3;
      final peakY = size.height * 0.65 + math.sin((i + animationValue * 2 * math.pi) * 0.9) * 35;
      final troughY = size.height * 0.75 + math.cos((i + animationValue * 2 * math.pi) * 0.9) * 35;
      
      path3.quadraticBezierTo(
        x + waveWidth3 * 0.25 + wave3Offset,
        peakY,
        x + waveWidth3 * 0.5 + wave3Offset,
        (peakY + troughY) / 2,
      );
      path3.quadraticBezierTo(
        x + waveWidth3 * 0.75 + wave3Offset,
        troughY,
        x + waveWidth3 + wave3Offset,
        size.height * 0.7,
      );
    }
    
    path3.lineTo(size.width, size.height);
    path3.lineTo(0, size.height);
    path3.close();
    canvas.drawPath(path3, paint3);

    // Smooth flowing ribbon 4 (top)
    final path4 = Path();
    final wave4Offset = animationValue * size.width * 0.6;
    path4.moveTo(0, 0);
    path4.lineTo(0, size.height * 0.1);
    
    final numWaves4 = 5;
    final waveWidth4 = size.width / numWaves4;
    for (int i = 0; i < numWaves4; i++) {
      final x = i * waveWidth4;
      final peakY = size.height * 0.05 + math.sin((i + animationValue * 2 * math.pi) * 1.5) * 25;
      final troughY = size.height * 0.15 + math.cos((i + animationValue * 2 * math.pi) * 1.5) * 25;
      
      path4.quadraticBezierTo(
        x + waveWidth4 * 0.25 - wave4Offset,
        peakY,
        x + waveWidth4 * 0.5 - wave4Offset,
        (peakY + troughY) / 2,
      );
      path4.quadraticBezierTo(
        x + waveWidth4 * 0.75 - wave4Offset,
        troughY,
        x + waveWidth4 - wave4Offset,
        size.height * 0.1,
      );
    }
    
    path4.lineTo(size.width, 0);
    path4.close();
    canvas.drawPath(path4, paint4);
  }

  @override
  bool shouldRepaint(WaveBackgroundPainter oldDelegate) => oldDelegate.animationValue != animationValue;
}

class _PlanCard extends StatelessWidget {
  final String title;
  final String price;
  final List<String> features;
  final String cta;
  final VoidCallback onTap;
  final bool isPremium;

  const _PlanCard({
    required this.title,
    required this.price,
    required this.features,
    required this.cta,
    required this.onTap,
    required this.isPremium,
  });

  @override
  Widget build(BuildContext context) {
    const purpleColor = Color(0xFF6366F1);
    const darkTextColor = Color(0xFF1F2937);
    const mediumTextColor = Color(0xFF4B5563);
    
    return Container(
      margin: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: isPremium ? Border.all(color: purpleColor, width: 2) : Border.all(color: const Color(0xFFE5E7EB), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          children: [
            // Glassmorphism background
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(16),
              ),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
            // Content
            Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.stars, color: isPremium ? purpleColor : mediumTextColor, size: 24),
                      const SizedBox(width: 8),
                      Text(title, style: context.textStyles.titleLarge.bold.withColor(darkTextColor)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    price,
                    style: context.textStyles.headlineSmall.bold.withColor(isPremium ? purpleColor : darkTextColor),
                  ),
                  const SizedBox(height: 12),
                  ...features.map((f) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle, color: isPremium ? purpleColor : const Color(0xFF10B981), size: 22),
                        const SizedBox(width: 8),
                        Expanded(child: Text(f, style: context.textStyles.bodyMedium.withColor(mediumTextColor))),
                      ],
                    ),
                  )),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: isPremium
                        ? Container(
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF6366F1), Color(0xFF7C3AED)],
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                              ),
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF6366F1).withValues(alpha: 0.3),
                                  blurRadius: 8,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: ElevatedButton(
                              onPressed: onTap,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                foregroundColor: Colors.white,
                                shadowColor: Colors.transparent,
                                padding: const EdgeInsets.symmetric(vertical: 16),
                              ),
                              child: Text(cta, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                            ),
                          )
                        : OutlinedButton(
                            onPressed: onTap,
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              side: const BorderSide(color: Color(0xFF6B7280), width: 1.5),
                              foregroundColor: darkTextColor,
                            ),
                            child: Text(cta, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                          ),
                  ),
                ],
              ),
            ),
            // Best Value badge for premium card
            if (isPremium)
              Positioned(
                top: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6366F1), Color(0xFF7C3AED)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF6366F1).withValues(alpha: 0.3),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    'BEST VALUE',
                    style: context.textStyles.labelSmall.bold.withColor(Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
