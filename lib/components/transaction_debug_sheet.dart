import 'package:flutter/material.dart';
import 'package:spendiq/utils/formatters.dart';
import 'package:go_router/go_router.dart';
import 'package:spendiq/models/transaction.dart';
import 'package:spendiq/services/master_spreadsheet_service.dart';
import 'package:spendiq/services/spend_categorizer.dart';
import 'package:spendiq/services/statement_parser.dart';
import 'package:spendiq/theme.dart';

class TransactionDebugSheet extends StatelessWidget {
  final SpendTransaction tx;
  const TransactionDebugSheet({super.key, required this.tx});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: LayoutBuilder(builder: (context, constraints) {
        return Padding(
          padding: EdgeInsets.only(
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            top: AppSpacing.lg,
            bottom: AppSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SizedBox(
            height: constraints.maxHeight,
            child: FutureBuilder<void>(
              future: MasterSpreadsheetService.ensureLoaded(),
              builder: (context, snap) {
                // Match using the same joined input SpendCategorizer uses so we can trace
                // which master row produced both Level 1 and Level 2.
                final joined = '${tx.merchant} ${tx.description}'.trim();
                final explain = MasterSpreadsheetService.explainMerchantCleaning(joined);
                final masterMatch = MasterSpreadsheetService.matchMerchantMaster(joined);
                final catExplain = SpendCategorizer.explain(merchant: tx.merchant, description: tx.description);
                final interestExplain = StatementParserService.explainInterestText(joined);
                final txL2 = (tx.subcategory ?? '').trim().isEmpty ? 'Other' : tx.subcategory!.trim();
                final recomputedL2 = catExplain.level2.label.trim().isEmpty ? 'Other' : catExplain.level2.label.trim();
                final hasMismatch = tx.category.trim() != catExplain.level1.label.trim() || txL2 != recomputedL2;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.bug_report, color: cs.primary),
                        const SizedBox(width: 10),
                        Expanded(child: Text('Level 1 / Level 2 troubleshooting', style: context.textStyles.titleLarge.bold)),
                        IconButton(tooltip: 'Close', onPressed: () => context.pop(), icon: const Icon(Icons.close)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Scrollbar(
                        interactive: true,
                        thickness: 6,
                        radius: const Radius.circular(12),
                        child: SingleChildScrollView(
                          primary: true,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _SectionCard(
                                title: 'Transaction (input)',
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _kv(context, 'Date', '${tx.date.month}/${tx.date.day}/${tx.date.year}'),
                                    _kv(context, 'Amount', Formatters.fixed(tx.amount, decimals: 2)),
                                    _kv(context, 'Merchant', tx.merchant),
                                    _kv(context, 'Description', tx.description),
                                    _kv(context, 'Current Level 1', tx.category),
                                    _kv(context, 'Current Level 2', (tx.subcategory ?? '').isEmpty ? 'Other' : tx.subcategory!),
                                    if ((tx.brand ?? '').isNotEmpty) _kv(context, 'Brand (Level 3)', tx.brand!),
                                    if ((tx.special ?? '').isNotEmpty) _kv(context, 'Special', tx.special!),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              _SectionCard(
                                title: 'Interest detection (why it did/didn\'t trigger)',
                                subtitle: interestExplain['final_is_interest'] == true ? 'Detected as interest' : 'Not detected as interest',
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    _kv(context, 'Joined text used', joined),
                                    _kv(context, 'direct contains("interest")', '${interestExplain['direct_contains_interest']}'),
                                    _kv(context, 'normalized letters-only', '${interestExplain['normalized_letters_only']}'),
                                    _kv(context, 'normalized contains("interest")', '${interestExplain['normalized_contains_interest']}'),
                                    _kv(context, 'regex match', '${interestExplain['regex_match']}'),
                                    const SizedBox(height: 6),
                                    Text('If this should be interest but shows false, copy/paste the "Joined text used" line to me.', style: context.textStyles.bodySmall.withColor(cs.onSurfaceVariant)),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              _SectionCard(
                                title: 'Top Master matches (ranked)',
                                subtitle: snap.connectionState != ConnectionState.done ? 'Loading mapping…' : null,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (masterMatch == null) _kv(context, 'Result', 'No strong match found'),
                                    if (masterMatch != null) ...[
                                      _kv(context, 'Chosen match key', masterMatch.key),
                                      if (masterMatch.row.rowIndex != null) _kv(context, 'Matched row', masterMatch.row.rowIndex.toString()),
                                      _kv(context, 'Standard merchant', masterMatch.row.cleanMerchant),
                                      _kv(context, 'Matched Level 1', (masterMatch.row.level1 ?? '').isEmpty ? 'Other' : masterMatch.row.level1!),
                                      _kv(context, 'Matched Level 2', (masterMatch.row.level2 ?? '').isEmpty ? 'Other' : masterMatch.row.level2!),
                                      _kv(context, 'Match method', '${masterMatch.method.name} (tier ${masterMatch.tier})'),
                                    ],
                                    if (explain.details.isNotEmpty) ...[
                                      const SizedBox(height: 8),
                                      Text('Match details', style: context.textStyles.labelLarge.bold),
                                      const SizedBox(height: 6),
                                      ...explain.details.entries.map((e) => _kv(context, e.key, '${e.value}')),
                                    ],
                                    if (explain.topCandidates.isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      Text('Candidates', style: context.textStyles.labelLarge.bold),
                                      const SizedBox(height: 6),
                                      ...explain.topCandidates.map((c) {
                                        final row = MasterSpreadsheetService.getMerchantMasterRowByKey(c.key);
                                        final l1 = (row?.level1 ?? '').trim().isEmpty ? 'Other' : row!.level1!.trim();
                                        final l2 = (row?.level2 ?? '').trim().isEmpty ? 'Other' : row!.level2!.trim();
                                        return Padding(
                                          padding: const EdgeInsets.only(bottom: 10),
                                          child: Container(
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
                                              borderRadius: BorderRadius.circular(14),
                                              border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.6)),
                                            ),
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(child: Text(c.key, style: context.textStyles.bodyMedium.bold)),
                                                    const SizedBox(width: 8),
                                                    Text(Formatters.fixed(c.score, decimals: 1), style: context.textStyles.labelLarge.bold.withColor(cs.primary)),
                                                  ],
                                                ),
                                                const SizedBox(height: 6),
                                                _kv(context, 'Level 1', l1),
                                                _kv(context, 'Level 2', l2),
                                                if (row != null) _kv(context, 'Standard merchant', row.cleanMerchant),
                                                if (c.notes.isNotEmpty)
                                                  Text(
                                                    'tier ${c.notes['tier'] ?? '-'} • ${c.notes['method'] ?? ''}',
                                                    style: context.textStyles.labelSmall.withColor(cs.onSurfaceVariant),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        );
                                      }),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              _SectionCard(
                                title: 'Final output (what the app uses)',
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (hasMismatch) ...[
                                      Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: BoxDecoration(
                                          color: cs.errorContainer.withValues(alpha: 0.45),
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(color: cs.error.withValues(alpha: 0.35)),
                                        ),
                                        child: Text(
                                          'Mismatch detected: this saved transaction shows "${tx.category} / $txL2", but recomputing against the current Master sheet yields "${catExplain.level1.label} / $recomputedL2". This usually means the transaction was categorized before the latest Master sheet loaded/updated.',
                                          style: context.textStyles.bodySmall.withColor(cs.onErrorContainer),
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                    ],
                                    _kv(context, 'Level 1', catExplain.level1.label),
                                    _kv(context, 'Level 2', catExplain.level2.label),
                                    _kv(context, 'Level 1 source', catExplain.level1.matchGroup),
                                    _kv(context, 'Level 2 source', catExplain.level2.matchGroup),
                                    if (catExplain.level1.matchedKeyword != null) _kv(context, 'Matched key (Level 1)', catExplain.level1.matchedKeyword!),
                                    if (catExplain.level2.matchedKeyword != null) _kv(context, 'Matched key (Level 2)', catExplain.level2.matchedKeyword!),
                                    _kv(context, 'Level 3 (brand)', catExplain.level3.label.isEmpty ? '(empty)' : catExplain.level3.label),
                                    _kv(context, 'Level 3 matched', catExplain.level3.matchedKeyword ?? '(none — heuristic)'),
                                    if (catExplain.special.isNotEmpty) _kv(context, 'Special', catExplain.special),
                                    const SizedBox(height: 8),
                                    Text('Matched against (lowercased input)', style: context.textStyles.labelLarge.bold),
                                    const SizedBox(height: 6),
                                    Text(catExplain.input.joinedLower, style: context.textStyles.bodySmall.withColor(cs.onSurfaceVariant)),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      }),
    );
  }

  static Widget _kv(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(k, style: context.textStyles.labelSmall.withColor(Theme.of(context).colorScheme.onSurfaceVariant)),
            Text(v, style: context.textStyles.bodyMedium),
          ],
        ),
      );
}

class _SectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  const _SectionCard({required this.title, required this.child, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: context.textStyles.titleMedium.bold),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle!, style: context.textStyles.bodySmall.withColor(cs.onSurfaceVariant)),
            ],
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }
}
