import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:spendiq/core/optimiq.dart';
import 'package:spendiq/services/master_spreadsheet_service.dart';
import 'package:spendiq/services/user_service.dart';
import 'package:spendiq/models/transaction.dart';
import 'package:spendiq/models/recommendation.dart';
import 'package:spendiq/nav.dart';
import 'package:spendiq/theme.dart';
import 'package:spendiq/utils/formatters.dart';
import 'package:spendiq/components/disclaimer_banner.dart';
import 'package:spendiq/components/transaction_debug_sheet.dart';
import 'package:spendiq/components/glass_panel.dart';
import 'package:spendiq/components/optimized_asset_image.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
// Note: We pass transactions into this page via the router (see nav.dart).

class ResultsPage extends StatefulWidget {
  final List<SpendTransaction> transactions;
  /// The number of months represented by the uploaded statements.
  /// Used for annualized projections and per-month calculations.
  final int monthsInUpload;

  const ResultsPage({super.key, required this.transactions, this.monthsInUpload = 1});

  @override
  State<ResultsPage> createState() => _ResultsPageState();
}

class _ResultsPageState extends State<ResultsPage> {
  bool _isPro = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkSubscription();
  }

  Future<void> _checkSubscription() async {
    try {
      final userService = UserService();
      final currentUser = Supabase.instance.client.auth.currentUser;
      if (currentUser != null) {
        final appUser = await userService.getCurrentUser();
        if (mounted) {
          setState(() {
            _isPro = appUser?.hasActiveSubscription ?? false;
            _isLoading = false;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isPro = false;
            _isLoading = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error checking subscription: $e');
      if (mounted) {
        setState(() {
          _isPro = false;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (_isLoading) {
      return Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF000000),
                Color(0xFF0A0E12),
                Color(0xFF000000),
              ],
            ),
          ),
          child: Center(
            child: CircularProgressIndicator(color: cs.primary),
          ),
        ),
      );
    }

    // Use actual uploaded transactions without replication
    final m = widget.monthsInUpload.clamp(1, 12);
    final rawTxCount = widget.transactions.length;

    final engine = OptimIQEngine(cards: MasterSpreadsheetService.getCardModelsOrFallback());
    final rec = engine.recommend(widget.transactions, monthsInUpload: m);
    
    // Phase 2: per-transaction routing (use actual transactions)
    final perTx = engine.perTransactionRecords(widget.transactions);
    
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Card Review', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        centerTitle: true,
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => context.go(AppRoutes.landing),
        ),
        actions: [
          IconButton(
            tooltip: 'More',
            icon: const Icon(Icons.more_horiz, color: Colors.white),
            onPressed: () {},
          ),
          const SizedBox(width: 6),
        ],
      ),
      bottomNavigationBar: const DisclaimerBanner(
        text:
            'SpendIQ recommends strategies based on your data but cannot guarantee results. Users are responsible for their credit card usage and any associated risks.',
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF000000),
              Color(0xFF0A0E12),
              Color(0xFF000000),
            ],
          ),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
            children: [
              _CardReviewHero(rec: rec, txCount: rawTxCount, monthsInUpload: m),
              const SizedBox(height: 16),
              _SectionHeader(title: 'ALL CARD RANKINGS'),
              const SizedBox(height: 10),
              _AllCardRankingsSection(rankings: rec.allCardRankings, isPro: _isPro),
              const SizedBox(height: 16),
              _SectionHeader(title: 'TRANSACTION TABLE'),
              const SizedBox(height: 10),
              _TransactionTableSection(transactions: widget.transactions),
              const SizedBox(height: 16),
              _SectionHeader(
                title: 'SPEND BY CATEGORY',
                trailing: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _formatMonthYear(DateTime.now()),
                      style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.5)),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      m == 1 ? 'From uploaded month' : 'From $m months uploaded',
                      style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.4)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              GlassPanel(
                borderRadius: AppRadius.xl,
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: rec.spendByCategory.entries.where((e) => e.value > 0).take(10).map((e) {
                    return _MetricRow(
                      icon: _iconForCategory(e.key),
                      title: e.key,
                      value: _moneyNum(e.value),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 14),
              if (!_isPro) ...[
                GlassPanel(
                  borderRadius: AppRadius.xl,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFF6366F1),
                              Color(0xFF8B5CF6),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF6366F1).withValues(alpha: 0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Text('Save 33%', style: context.textStyles.labelSmall.bold.withColor(Colors.white)),
                      ),
                      const SizedBox(height: 10),
                      Text('Simulate every card, every transaction', style: context.textStyles.titleMedium.bold),
                      const SizedBox(height: 6),
                      Text(
                        "See exactly what you'd earn on any card in our database — plus multi-card picks matched to each transaction type.",
                        style: context.textStyles.bodyMedium.withColor(Colors.white.withValues(alpha: 0.7)),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFF6366F1),
                                Color(0xFF4F46E5),
                              ],
                            ),
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF6366F1).withValues(alpha: 0.4),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
                              elevation: 0,
                              shadowColor: Colors.transparent,
                            ),
                            onPressed: () => context.go(AppRoutes.pricing),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Text(
                                      'Subscribe — \$19/yr →',
                                      style: TextStyle(
                                        color: cs.onPrimary,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 18,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '\$1.58 / mo · billed yearly',
                                      style: TextStyle(
                                        color: cs.onPrimary.withValues(alpha: 0.9),
                                        fontSize: 14,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
              GlassPanel(
                borderRadius: AppRadius.xl,
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  collapsedIconColor: Colors.white.withValues(alpha: 0.7),
                  iconColor: Colors.white.withValues(alpha: 0.7),
                  shape: const Border(),
                  collapsedShape: const Border(),
                  leading: Icon(Icons.route, color: cs.primary),
                  title: Text('Per-transaction best routing', style: context.textStyles.titleMedium.bold.withColor(Colors.white)),
                  children: [
                    const SizedBox(height: 6),
                    if (perTx.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text('No transactions to route', style: context.textStyles.bodyMedium.withColor(Colors.white.withValues(alpha: 0.7))),
                      )
                    else ...perTx.take(40).map((p) {
                      final d = '${p.date.month.toString().padLeft(2, '0')}/${p.date.day.toString().padLeft(2, '0')}/${p.date.year}';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: InkWell(
                          splashFactory: NoSplash.splashFactory,
                          highlightColor: Colors.transparent,
                          borderRadius: BorderRadius.circular(16),
                          onTap: () {
                            final tx = widget.transactions.firstWhere(
                              (t) => t.id == p.transactionId,
                              orElse: () => SpendTransaction(
                                id: p.transactionId,
                                date: p.date,
                                description: p.merchant,
                                merchant: p.merchant,
                                category: p.category,
                                amount: p.amount,
                                createdAt: p.date,
                                updatedAt: p.date,
                              ),
                            );
                            showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              showDragHandle: true,
                              builder: (ctx) => TransactionDebugSheet(tx: tx),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                            child: Row(
                              children: [
                                Icon(Icons.receipt_long, color: Colors.white.withValues(alpha: 0.7)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text('${p.merchant} • ${p.category}', overflow: TextOverflow.ellipsis, style: context.textStyles.bodyMedium.bold.withColor(Colors.white)),
                                      const SizedBox(height: 2),
                                      Text('${p.cardDisplay} — ${p.rationale}', maxLines: 2, overflow: TextOverflow.ellipsis, style: context.textStyles.bodySmall.withColor(Colors.white.withValues(alpha: 0.7))),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(_money(p.estimatedReward), style: context.textStyles.labelLarge.bold.withColor(cs.primary)),
                                    Text(d, style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.7))),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    }),
                    if (perTx.length > 40)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text('Showing 40 of ${perTx.length}.', style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.7))),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              GlassPanel(
                borderRadius: AppRadius.xl,
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  collapsedIconColor: Colors.white.withValues(alpha: 0.7),
                  iconColor: Colors.white.withValues(alpha: 0.7),
                  shape: const Border(),
                  collapsedShape: const Border(),
                  leading: Icon(Icons.info_outline, color: cs.primary),
                  title: Text('Calculation Debug Info', style: context.textStyles.titleMedium.bold.withColor(Colors.white)),
                  subtitle: Text('Tap to see how we calculated these numbers', style: context.textStyles.bodySmall.withColor(Colors.white.withValues(alpha: 0.7))),
                  children: [
                    const SizedBox(height: 6),
                    _KeyValueLine(k: 'Raw transactions uploaded', v: '$rawTxCount'),
                    _KeyValueLine(k: 'Months in upload', v: '$m'),
                    _KeyValueLine(k: 'Total transactions analyzed', v: '${widget.transactions.length}'),
                    const SizedBox(height: 10),
                    Divider(color: cs.outline.withValues(alpha: 0.2)),
                    const SizedBox(height: 10),
                    Text('Category spend (annual)', style: context.textStyles.titleSmall.bold.withColor(Colors.white)),
                    const SizedBox(height: 8),
                    ...rec.spendByCategory.entries.where((e) => e.value > 0).take(10).map((e) {
                      return _KeyValueLine(k: e.key, v: _moneyNum(e.value));
                    }),
                    const SizedBox(height: 14),
                    Text('Category earnings', style: context.textStyles.titleSmall.bold.withColor(Colors.white)),
                    const SizedBox(height: 8),
                    ...rec.categoryEarnings.entries.take(8).map((e) => _KeyValueLine(k: e.key, v: _moneyNum(e.value))),
                    const SizedBox(height: 14),
                    Text('Estimated rewards per card', style: context.textStyles.titleSmall.bold.withColor(Colors.white)),
                    const SizedBox(height: 8),
                    ...rec.perCardRewards.entries.take(8).map((e) => _KeyValueLine(k: e.key, v: _moneyNum(e.value))),
                    if (rec.bestCombo != null) ...[
                      const SizedBox(height: 14),
                      Text('Best multi-card combo', style: context.textStyles.titleSmall.bold.withColor(Colors.white)),
                      const SizedBox(height: 8),
                      _KeyValueLine(k: 'Cards', v: (rec.bestCombo!['cards'] as List).join(' + ')),
                      _KeyValueLine(k: 'Rewards', v: _moneyNum(rec.bestCombo!['rewards'] as num)),
                      _KeyValueLine(k: 'Net value', v: _moneyNum(rec.bestCombo!['netValue'] as num)),
                    ],
                    if (rec.capsNotes.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Text('Caps & limitations applied', style: context.textStyles.titleSmall.bold.withColor(Colors.white)),
                      const SizedBox(height: 8),
                      ...rec.capsNotes.take(5).map((n) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.info_outline, size: 18, color: Colors.white.withValues(alpha: 0.7)),
                            const SizedBox(width: 8),
                            Expanded(child: Text(n, style: context.textStyles.bodySmall.withColor(Colors.white.withValues(alpha: 0.7)))),
                          ],
                        ),
                      )),
                    ],
                    const SizedBox(height: 10),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              DecoratedBox(
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(28), gradient: AppGradients.primarySheen(cs)),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: () {},
                  icon: Icon(Icons.link, color: cs.onPrimary),
                  label: Text('Apply via affiliate link', style: TextStyle(color: cs.onPrimary, fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(height: 10),
              Text('Note: We will route you via CJ, Impact, Rakuten, or Partnerize as available.', style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.6))),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});
  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.5)).copyWith(
              letterSpacing: 1.3,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.icon, required this.title, required this.value});
  final IconData icon;
  final String title;
  final String value;

  Color _colorForCategory(String category) {
    final c = category.toLowerCase();
    if (c.contains('dining') || c.contains('restaurant') || c.contains('food')) return const Color(0xFFFF6B6B);
    if (c.contains('grocery')) return const Color(0xFFA8C69F);
    if (c.contains('travel') || c.contains('air') || c.contains('hotel')) return const Color(0xFF2F5BFF);
    if (c.contains('gas') || c.contains('fuel')) return const Color(0xFFFFB74D);
    if (c.contains('shopping') || c.contains('retail')) return const Color(0xFFBA68C8);
    if (c.contains('health')) return const Color(0xFF4DD0E1);
    if (c.contains('entertain')) return const Color(0xFFFF8A80);
    return const Color(0xFF9FA8DA);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final categoryColor = _colorForCategory(title);
    
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  categoryColor.withValues(alpha: 0.3),
                  categoryColor.withValues(alpha: 0.15),
                ],
              ),
              border: Border.all(color: categoryColor.withValues(alpha: 0.4), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: categoryColor.withValues(alpha: 0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(icon, size: 18, color: categoryColor),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: context.textStyles.bodyMedium.bold.withColor(Colors.white), overflow: TextOverflow.ellipsis)),
          Text(value, style: context.textStyles.labelLarge.bold.withColor(categoryColor)),
        ],
      ),
    );
  }
}

class _KeyValueLine extends StatelessWidget {
  const _KeyValueLine({required this.k, required this.v});
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(k, style: context.textStyles.bodySmall.withColor(Colors.white.withValues(alpha: 0.7)), overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 12),
          Flexible(child: Text(v, style: context.textStyles.bodySmall.bold.withColor(Colors.white), textAlign: TextAlign.right, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

class _CardReviewHero extends StatelessWidget {
  const _CardReviewHero({required this.rec, required this.txCount, required this.monthsInUpload});
  final RecommendationResult rec;
  final int txCount;
  final int monthsInUpload;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final brand = context.brand;

    return GlassPanel(
      borderRadius: AppRadius.xl,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  height: 34,
                  width: 54,
                  child: OptimizedAssetImage(
                    assetPath: 'assets/images/credit_card.jpg',
                    width: 54,
                    height: 34,
                    borderRadius: 0,
                    fit: BoxFit.contain,
                    alignment: Alignment.center,
                    fadeIn: true,
                    fallback: Container(color: cs.surfaceContainerHighest.withValues(alpha: 0.18)),
                  ),
                ),
              ),
              _Pill(
                icon: Icons.auto_awesome,
                text: 'TOP RECOMMENDATION',
                foreground: cs.onPrimary,
                background: LinearGradient(
                  colors: [
                    brand.accent.withValues(alpha: 0.98),
                    brand.accent2.withValues(alpha: 0.92),
                  ],
                ),
              ),
              if (monthsInUpload < 12)
                _Pill(
                  icon: Icons.timeline,
                  text: 'Projected from $monthsInUpload mo',
                  foreground: Colors.white,
                  background: LinearGradient(colors: [cs.surfaceContainerHighest.withValues(alpha: 0.75), cs.surfaceContainerHighest.withValues(alpha: 0.35)]),
                ),
              _ValueChip(value: rec.estimatedAnnualValue),
            ],
          ),
          const SizedBox(height: 16),
          Text(rec.cardName, style: context.textStyles.headlineSmall.bold.withColor(Colors.white)),
          const SizedBox(height: 12),
          // Main value breakdown
          _ValueBreakdownCard(
            rewards: rec.totalRewards,
            credits: rec.totalCredits,
            benefits: rec.totalBenefits,
            annualFee: rec.annualFee,
            netValue: rec.estimatedAnnualValue,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _HeroStat(
                  label: 'Transactions',
                  valueText: '$txCount',
                  icon: Icons.swap_horiz,
                ),
              ),
              const SizedBox(width: 10),
              if (rec.firstYearBonus > 0)
                Expanded(
                  child: _FirstYearBonusChip(bonus: rec.firstYearBonus),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, required this.foreground, required this.background});
  final IconData icon;
  final String text;
  final Color foreground;
  final LinearGradient background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: background,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 16, offset: const Offset(0, 10)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 6),
          Text(
            text,
            style: Theme.of(context).textTheme.labelSmall!.copyWith(
              color: foreground,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _ValueChip extends StatelessWidget {
  const _ValueChip({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outline.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt, size: 16, color: cs.primary),
          const SizedBox(width: 6),
          Text('${_money(value)}/yr', style: Theme.of(context).textTheme.labelMedium!.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.label, required this.valueText, required this.icon});
  final String label;
  final String valueText;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF6366F1),
            Color(0xFF8B5CF6),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6366F1).withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Container(
        margin: const EdgeInsets.all(2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E2E),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: AppGradients.primarySheen(cs),
            ),
            child: Icon(icon, size: 18, color: cs.onPrimary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.7))),
                const SizedBox(height: 2),
                Text(valueText, style: context.textStyles.titleMedium.bold.withColor(Colors.white), overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}

IconData _iconForCategory(String category) {
  final c = category.toLowerCase();
  if (c.contains('dining') || c.contains('restaurant') || c.contains('food')) return Icons.local_dining;
  if (c.contains('grocery')) return Icons.local_grocery_store;
  if (c.contains('travel') || c.contains('air') || c.contains('hotel')) return Icons.flight_takeoff;
  if (c.contains('gas') || c.contains('fuel')) return Icons.local_gas_station;
  if (c.contains('shopping') || c.contains('retail')) return Icons.shopping_bag;
  if (c.contains('health')) return Icons.health_and_safety;
  if (c.contains('entertain')) return Icons.movie;
  return Icons.category;
}

String _money(double v, {int decimals = 2}) {
  if (!v.isFinite) {
    debugPrint('Non-finite money value encountered: $v');
    return '—';
  }
  // Use shared formatter so we never risk a non-finite crash if logic changes.
  return Formatters.money(v, decimals: decimals);
}

String _moneyNum(num v, {int decimals = 2}) {
  final d = v.toDouble();
  return _money(d, decimals: decimals);
}

String _formatMonthYear(DateTime dt) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${months[dt.month - 1]} ${dt.year}';
}

class _ValueBreakdownCard extends StatefulWidget {
  const _ValueBreakdownCard({
    required this.rewards,
    required this.credits,
    required this.benefits,
    required this.annualFee,
    required this.netValue,
  });
  
  final double rewards;
  final double credits;
  final double benefits;
  final double annualFee;
  final double netValue;

  @override
  State<_ValueBreakdownCard> createState() => _ValueBreakdownCardState();
}

class _ValueBreakdownCardState extends State<_ValueBreakdownCard> with SingleTickerProviderStateMixin {
  late AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat();
  }

  @override
  void dispose() {
    _shimmerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final totalPositive = widget.rewards + widget.credits + widget.benefits;
    
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        children: [
          // Mountain background image filling entire card
          Positioned.fill(
            child: OptimizedAssetImage(
              assetPath: 'assets/images/mountain.jpg',
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              borderRadius: 0,
              fadeIn: false,
              fallback: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      const Color(0xFF1A2540).withValues(alpha: 0.8),
                      const Color(0xFF2A3A5A).withValues(alpha: 0.6),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // Dark overlay for text readability
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.black.withValues(alpha: 0.7),
                    Colors.black.withValues(alpha: 0.5),
                  ],
                ),
              ),
            ),
          ),
          // Animated gradient border
          AnimatedBuilder(
            animation: _shimmerController,
            builder: (context, child) {
              return Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.lerp(const Color(0xFF6366F1), const Color(0xFF8B5CF6), (_shimmerController.value * 2) % 1.0)!,
                      Color.lerp(const Color(0xFF8B5CF6), const Color(0xFF6366F1), (_shimmerController.value * 2) % 1.0)!,
                    ],
                    stops: [
                      (_shimmerController.value * 0.5),
                      (_shimmerController.value * 0.5) + 0.5,
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                    BoxShadow(
                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.15),
                      blurRadius: 40,
                      offset: const Offset(0, 20),
                    ),
                  ],
                ),
                child: Container(
                  margin: const EdgeInsets.all(2),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    color: Colors.black.withValues(alpha: 0.4),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFA8E6C0).withValues(alpha: 0.15),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: LinearGradient(
                            colors: [
                              Colors.white.withValues(alpha: 0.2),
                              Colors.white.withValues(alpha: 0.1),
                            ],
                          ),
                        ),
                        child: Center(
                          child: Icon(
                            Icons.account_balance_wallet,
                            size: 20,
                            color: Colors.white.withValues(alpha: 0.95),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Annual Value',
                      style: context.textStyles.titleMedium.bold.withColor(Colors.white),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _BreakdownRow(label: 'Total Rewards + Benefits', value: totalPositive, isPositive: true, isDark: true),
                _BreakdownRow(label: 'Annual Fee', value: widget.annualFee, isPositive: false, isDark: true),
                const SizedBox(height: 10),
                Container(
                  height: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0.0),
                        Colors.white.withValues(alpha: 0.4),
                        Colors.white.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0.15),
                        Colors.white.withValues(alpha: 0.10),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFFA8E6C0).withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Net Value',
                            style: context.textStyles.titleSmall.withColor(
                              Colors.white.withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Per Year',
                            style: context.textStyles.headlineSmall.bold.withColor(Colors.white),
                          ),
                        ],
                      ),
                      Text(
                        _money(widget.netValue),
                        style: context.textStyles.headlineMedium.bold.copyWith(
                          color: const Color(0xFFA8E6C0),
                          fontSize: 36,
                        ),
                      ),
                      ],
                    ),
                  ),
                ],
              ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.label,
    required this.value,
    required this.isPositive,
    this.isBold = false,
    this.isDark = false,
  });
  
  final String label;
  final double value;
  final bool isPositive;
  final bool isBold;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    final labelColor = isDark ? Colors.white.withValues(alpha: 0.8) : cs.onSurfaceVariant;
    final valueColor = isDark 
      ? (isPositive ? const Color(0xFFA8E6C0) : const Color(0xFFF0997B))
      : (isPositive ? cs.primary : cs.error);
    
    final textStyle = isBold 
      ? context.textStyles.bodyMedium.bold.withColor(labelColor)
      : context.textStyles.bodyMedium.withColor(labelColor);
    
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: textStyle),
          Text(
            '${isPositive ? '+' : '-'}${_money(value.abs())}',
            style: textStyle.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}

class _FirstYearBonusChip extends StatelessWidget {
  const _FirstYearBonusChip({required this.bonus});
  final double bonus;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            cs.primaryContainer.withValues(alpha: 0.85),
            cs.primaryContainer.withValues(alpha: 0.65),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: cs.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.card_giftcard, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'First Year Bonus',
                  style: context.textStyles.labelSmall.bold.withColor(cs.primary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _money(bonus),
            style: context.textStyles.titleMedium.bold.withColor(cs.primary),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _AllCardRankingsSection extends StatelessWidget {
  const _AllCardRankingsSection({required this.rankings, this.isPro = false});
  final List<CardRankingDetail> rankings;
  final bool isPro;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    if (rankings.isEmpty) {
      return GlassPanel(
        borderRadius: AppRadius.xl,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'No cards analyzed',
              style: context.textStyles.bodyMedium.withColor(Colors.white.withValues(alpha: 0.7)),
            ),
          ),
        ),
      );
    }
    
    return _AnimatedGradientBorder(
      child: GlassPanel(
        borderRadius: AppRadius.xl,
        padding: const EdgeInsets.all(14),
        borderColor: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFFD700).withValues(alpha: 0.6),
                      blurRadius: 16,
                      spreadRadius: 2,
                    ),
                    BoxShadow(
                      color: const Color(0xFFFFA500).withValues(alpha: 0.4),
                      blurRadius: 24,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFFFFD700), // Gold
                      Color(0xFFFFA500), // Orange
                      Color(0xFFFFD700), // Gold
                    ],
                  ).createShader(bounds),
                  child: const Icon(
                    Icons.emoji_events,
                    size: 24,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Top ${rankings.length} Cards for Your Spend',
                  style: context.textStyles.titleMedium.bold.withColor(Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...rankings.take(10).toList().asMap().entries.map((entry) {
            final rank = entry.key + 1;
            final card = entry.value;
            final isTop = rank == 1;
            final isBlurred = !isPro && rank > 1 && rank <= 3;
            
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xFF6366F1),
                            Color(0xFF8B5CF6),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0xFF6366F1).withValues(alpha: 0.15),
                            blurRadius: 16,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Container(
                        margin: const EdgeInsets.all(2),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E2E),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 28,
                                  height: 28,
                                  decoration: BoxDecoration(
                                    color: isTop 
                                      ? const Color(0xFFA8E6C0).withValues(alpha: 0.15)
                                      : Colors.white.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isTop 
                                        ? const Color(0xFFA8E6C0).withValues(alpha: 0.4)
                                        : Colors.white.withValues(alpha: 0.25),
                                      width: isTop ? 2 : 1,
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '#$rank',
                                    style: context.textStyles.labelSmall.bold.withColor(
                                      isTop ? const Color(0xFFA8E6C0) : Colors.white.withValues(alpha: 0.7),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        card.cardName,
                                        style: context.textStyles.titleSmall.bold.withColor(Colors.white),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      if (card.annualFee > 0)
                                        Text(
                                          '${_money(card.annualFee)} annual fee',
                                          style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.6)),
                                        ),
                                    ],
                                  ),
                                ),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      _money(card.netValue),
                                      style: context.textStyles.titleMedium.bold.withColor(
                                        card.netValue >= 0 ? const Color(0xFFA8E6C0) : const Color(0xFFFF6B6B),
                                      ),
                                    ),
                                    Text(
                                      'Net Value/yr',
                                      style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.6)),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Divider(color: cs.outline.withValues(alpha: 0.15), height: 1),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    _CardStatChip(
                                      label: 'Rewards',
                                      value: _money(card.totalRewards),
                                      color: cs.primary,
                                    ),
                                    if (card.totalBenefits > 0) ...[
                                      const SizedBox(width: 24),
                                      _CardStatChip(
                                        label: 'Benefits',
                                        value: _money(card.totalBenefits),
                                        color: cs.secondary,
                                      ),
                                    ],
                                  ],
                                ),
                                _CardStatChip(
                                  label: 'Total',
                                  value: _money(card.totalRewards + card.totalCredits + card.totalBenefits),
                                  color: const Color(0xFFA8E6C0),
                                ),
                              ],
                            ),
                            if (card.firstYearBonus > 0) ...[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: cs.tertiaryContainer.withValues(alpha: 0.3),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: cs.tertiary.withValues(alpha: 0.2)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.card_giftcard, size: 14, color: cs.tertiary),
                                    const SizedBox(width: 6),
                                    Text(
                                      'First Year: +${_money(card.firstYearBonus)} bonus',
                                      style: context.textStyles.labelSmall.bold.withColor(cs.tertiary),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    if (isBlurred)
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black.withValues(alpha: 0.15),
                                    Colors.black.withValues(alpha: 0.2),
                                  ],
                                ),
                              ),
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    rank == 2 ? '#2 Best Card' : '#3 Third Pick',
                                    style: context.textStyles.headlineSmall.bold.withColor(Colors.white),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    rank == 2 ? 'Runner Up' : 'Top Alternative',
                                    style: context.textStyles.bodyMedium.withColor(Colors.white.withValues(alpha: 0.85)),
                                  ),
                                  const SizedBox(height: 16),
                                  DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [
                                          Color(0xFF6366F1),
                                          Color(0xFF8B5CF6),
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(12),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFF6366F1).withValues(alpha: 0.5),
                                          blurRadius: 16,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: OutlinedButton.icon(
                                      style: OutlinedButton.styleFrom(
                                        backgroundColor: Colors.transparent,
                                        side: const BorderSide(color: Colors.transparent),
                                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      ),
                                      onPressed: () => context.go(AppRoutes.pricing),
                                      icon: const Icon(Icons.lock_outline, color: Colors.white, size: 20),
                                      label: const Text(
                                        'UNLOCK PRO',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.8,
                                          fontSize: 15,
                                        ),
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
              ),
            );
          }),
          if (rankings.length > 10)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '+ ${rankings.length - 10} more cards analyzed',
                style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.7)),
                textAlign: TextAlign.center,
              ),
            ),
        ],
        ),
      ),
    );
  }
}

class _CardStatChip extends StatelessWidget {
  const _CardStatChip({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.6)),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: context.textStyles.labelMedium.bold.withColor(const Color(0xFFA8E6C0)),
        ),
      ],
    );
  }
}

class _TransactionTableSection extends StatefulWidget {
  const _TransactionTableSection({required this.transactions});
  final List<SpendTransaction> transactions;

  @override
  State<_TransactionTableSection> createState() => _TransactionTableSectionState();
}

class _TransactionTableSectionState extends State<_TransactionTableSection> {
  String _sortBy = 'date'; // 'date', 'amount', 'category', 'merchant'
  bool _showExcluded = true;

  List<SpendTransaction> get _sortedTransactions {
    final txs = widget.transactions.toList();
    switch (_sortBy) {
      case 'date':
        txs.sort((a, b) => b.date.compareTo(a.date)); // newest first
        break;
      case 'amount':
        txs.sort((a, b) => b.amount.abs().compareTo(a.amount.abs())); // largest first
        break;
      case 'category':
        txs.sort((a, b) {
          final catCompare = a.category.compareTo(b.category);
          if (catCompare != 0) return catCompare;
          return b.amount.abs().compareTo(a.amount.abs());
        });
        break;
      case 'merchant':
        txs.sort((a, b) {
          final merchCompare = a.merchant.compareTo(b.merchant);
          if (merchCompare != 0) return merchCompare;
          return b.date.compareTo(a.date);
        });
        break;
    }
    return txs;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sorted = _sortedTransactions;
    final spendTxs = sorted.where((t) => t.amount > 0).toList();
    final excludedTxs = sorted.where((t) => t.amount <= 0).toList();
    final displayTxs = _showExcluded ? sorted : spendTxs;
    
    return _AnimatedGradientBorder(
      child: GlassPanel(
        borderRadius: AppRadius.xl,
        padding: const EdgeInsets.all(14),
        borderColor: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.table_chart, size: 20, color: const Color(0xFFA8E6C0)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'All Transactions',
                  style: context.textStyles.titleSmall.bold.withColor(Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Summary stats
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              _TransactionStatChip(
                label: 'Total',
                value: '${sorted.length}',
                icon: Icons.receipt_long,
                color: Colors.white.withValues(alpha: 0.9),
              ),
              _TransactionStatChip(
                label: 'Spend',
                value: '${spendTxs.length}',
                icon: Icons.shopping_cart,
                color: const Color(0xFFA8E6C0),
              ),
              _TransactionStatChip(
                label: 'Excluded',
                value: '${excludedTxs.length}',
                icon: Icons.block,
                color: const Color(0xFFFF6B6B),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Sort & filter controls
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      Text('Sort by:', style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.7))),
                      const SizedBox(width: 8),
                      _SortChip(
                        label: 'Date',
                        isSelected: _sortBy == 'date',
                        onTap: () => setState(() => _sortBy = 'date'),
                      ),
                      const SizedBox(width: 6),
                      _SortChip(
                        label: 'Amount',
                        isSelected: _sortBy == 'amount',
                        onTap: () => setState(() => _sortBy = 'amount'),
                      ),
                      const SizedBox(width: 6),
                      _SortChip(
                        label: 'Category',
                        isSelected: _sortBy == 'category',
                        onTap: () => setState(() => _sortBy = 'category'),
                      ),
                      const SizedBox(width: 6),
                      _SortChip(
                        label: 'Merchant',
                        isSelected: _sortBy == 'merchant',
                        onTap: () => setState(() => _sortBy = 'merchant'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Checkbox(
                value: _showExcluded,
                onChanged: (v) => setState(() => _showExcluded = v ?? true),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
              Text('Show excluded transactions', style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.7))),
            ],
          ),
          const SizedBox(height: 12),
          Divider(color: Colors.white.withValues(alpha: 0.15), height: 1),
          const SizedBox(height: 12),
          // Transaction rows
          ...displayTxs.map((tx) {
            final isExcluded = tx.amount <= 0;
            return _TransactionRow(
              transaction: tx,
              isExcluded: isExcluded,
            );
          }),
          if (displayTxs.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(
                  _showExcluded ? 'No transactions' : 'No spend transactions (all excluded)',
                  style: context.textStyles.bodyMedium.withColor(Colors.white.withValues(alpha: 0.6)),
                ),
              ),
            ),
        ],
        ),
      ),
    );
  }
}

class _TransactionStatChip extends StatelessWidget {
  const _TransactionStatChip({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text('$value $label', style: Theme.of(context).textTheme.labelSmall!.copyWith(color: color, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _SortChip extends StatelessWidget {
  const _SortChip({required this.label, required this.isSelected, required this.onTap});
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFA8E6C0).withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? const Color(0xFFA8E6C0).withValues(alpha: 0.5) : Colors.white.withValues(alpha: 0.2),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: isSelected ? const Color(0xFFA8E6C0) : Colors.white.withValues(alpha: 0.8),
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _TransactionRow extends StatelessWidget {
  const _TransactionRow({required this.transaction, required this.isExcluded});
  final SpendTransaction transaction;
  final bool isExcluded;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dateStr = '${transaction.date.month.toString().padLeft(2, '0')}/${transaction.date.day.toString().padLeft(2, '0')}/${transaction.date.year}';
    
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          gradient: isExcluded
            ? null
            : const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF6366F1),
                  Color(0xFF8B5CF6),
                ],
              ),
          color: isExcluded ? const Color(0xFFFF6B6B).withValues(alpha: 0.2) : null,
          boxShadow: isExcluded
            ? null
            : [
                BoxShadow(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
        ),
        child: Container(
          margin: isExcluded ? EdgeInsets.zero : const EdgeInsets.all(2),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isExcluded ? Colors.transparent : const Color(0xFF1E1E2E),
            borderRadius: BorderRadius.circular(isExcluded ? 12 : 10),
          ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        transaction.merchant,
                        style: context.textStyles.bodyMedium.bold.withColor(
                          isExcluded ? Colors.white.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0.95),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        transaction.description,
                        style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.6)),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _money(transaction.amount.abs()),
                      style: context.textStyles.titleSmall.bold.withColor(
                        isExcluded ? const Color(0xFFFF6B6B) : const Color(0xFFA8E6C0),
                      ),
                    ),
                    Text(
                      dateStr,
                      style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.7)),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isExcluded 
                      ? const Color(0xFFFF6B6B).withValues(alpha: 0.2)
                      : const Color(0xFFA8E6C0).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isExcluded 
                        ? const Color(0xFFFF6B6B).withValues(alpha: 0.4)
                        : const Color(0xFFA8E6C0).withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    transaction.category,
                    style: context.textStyles.labelSmall.bold.withColor(
                      isExcluded ? const Color(0xFFFF6B6B) : const Color(0xFFA8E6C0),
                    ),
                  ),
                ),
                if (transaction.subcategory != null && transaction.subcategory!.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      transaction.subcategory!,
                      style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.9)),
                    ),
                  ),
                ],
                const Spacer(),
                if (isExcluded)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6B6B).withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFFF6B6B).withValues(alpha: 0.5)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.block, size: 12, color: Color(0xFFFF6B6B)),
                        const SizedBox(width: 4),
                        Text(
                          'EXCLUDED',
                          style: context.textStyles.labelSmall.bold.withColor(const Color(0xFFFF6B6B)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
          ),
        ),
      );
  }
}

/// Animated gradient border wrapper for glass panels
class _AnimatedGradientBorder extends StatefulWidget {
  const _AnimatedGradientBorder({required this.child});
  final Widget child;

  @override
  State<_AnimatedGradientBorder> createState() => _AnimatedGradientBorderState();
}

class _AnimatedGradientBorderState extends State<_AnimatedGradientBorder> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.xl),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.lerp(const Color(0xFF6366F1), const Color(0xFF8B5CF6), (_controller.value * 2) % 1.0)!,
                Color.lerp(const Color(0xFF8B5CF6), const Color(0xFF6366F1), (_controller.value * 2) % 1.0)!,
              ],
              stops: [
                (_controller.value * 0.5) % 1.0,
                ((_controller.value * 0.5) + 0.5) % 1.0,
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Container(
            margin: const EdgeInsets.all(1.5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.xl - 1.5),
            ),
            child: widget.child,
          ),
        );
      },
    );
  }
}
