import 'package:spendiq/models/transaction.dart';
import 'package:spendiq/models/card_offer.dart';
import 'package:spendiq/models/recommendation.dart';
import 'package:spendiq/core/categories.dart';
import 'package:flutter/foundation.dart';
import 'package:spendiq/utils/formatters.dart';

/// Reward cap period type
enum CapPeriod { monthly, quarterly, annual, none }

class RewardCap {
  final double? amount; // e.g., 1500 spend cap per period (null = no cap)
  final CapPeriod period;
  const RewardCap({this.amount, this.period = CapPeriod.none});
}

/// Match level for credit merchant matching (v106 schema)
enum CreditMatchLevel { l1, l2, l3, none }

/// Card credit/benefit that applies to specific categories or merchants
class CardCredit {
  final String category; // Level1 category this credit applies to
  final double creditValue; // Dollar value of the credit
  final CapPeriod frequency; // How often the credit is awarded
  final double? spendRequirement; // Minimum spend to qualify (null = no requirement)
  
  // v106: Explicit merchant matching columns
  final CreditMatchLevel matchLevel; // Which level to use for merchant matching
  final String? merchantL1; // Credit_Merchant_L1 (category-level match)
  final String? merchantL2; // Credit_Merchant_L2 (subcategory-level match)
  final String? merchantL3; // Credit_Merchant_L3 (specific merchant/brand match)
  
  const CardCredit({
    required this.category,
    required this.creditValue,
    required this.frequency,
    this.spendRequirement,
    this.matchLevel = CreditMatchLevel.none,
    this.merchantL1,
    this.merchantL2,
    this.merchantL3,
  });
  
  /// Check if this credit applies to a transaction based on match level
  bool appliesTo(SpendTransaction tx) {
    // Category must always match
    if (tx.category.toLowerCase() != category.toLowerCase()) return false;
    
    // If no merchant matching required, category match is sufficient
    if (matchLevel == CreditMatchLevel.none) return true;
    
    // Apply strict merchant matching based on match level
    switch (matchLevel) {
      case CreditMatchLevel.l1:
        if (merchantL1 == null || merchantL1!.isEmpty) return true;
        // L1 already matched via category check above
        return true;
      case CreditMatchLevel.l2:
        if (merchantL2 == null || merchantL2!.isEmpty) return true;
        // L2 match: transaction.subcategory must contain the merchant L2 string
        return tx.subcategory != null && 
               tx.subcategory!.toLowerCase().contains(merchantL2!.toLowerCase());
      case CreditMatchLevel.l3:
        if (merchantL3 == null || merchantL3!.isEmpty) return true;
        // L3 match: transaction.merchant (raw) must contain the FULL merchant L3 string
        // Strict matching: "LYFT" will NOT match "LYF"
        return tx.merchant.toLowerCase().contains(merchantL3!.toLowerCase());
      case CreditMatchLevel.none:
        return true;
    }
  }
}

/// Rule describing how a card earns on a category.
class CategoryRule {
  final String category; // Level1 category
  final double multiplier; // cashback rate (e.g., 0.05 for 5%) or point value applied post conversion
  final RewardCap cap; // optional cap
  const CategoryRule({required this.category, required this.multiplier, this.cap = const RewardCap()});
}

/// Rotating category set (by quarter)
class RotatingCategoriesConfig {
  final Map<int, List<String>> categoriesByQuarter; // Q1..Q4 -> categories
  final double multiplier;
  final RewardCap cap;
  const RotatingCategoriesConfig({required this.categoriesByQuarter, required this.multiplier, this.cap = const RewardCap()});
}

class BenefitPreferences {
  final bool loungeAccess;
  final bool tsaPre;
  final bool travelInsurance;
  final bool cellPhoneProtection;
  final bool extendedWarranty;
  final bool noFtf;
  final bool introApr;
  final bool signupBonus;
  final bool freeHotelNight;

  const BenefitPreferences({
    this.loungeAccess = true,
    this.tsaPre = true,
    this.travelInsurance = true,
    this.cellPhoneProtection = false,
    this.extendedWarranty = true,
    this.noFtf = true,
    this.introApr = false,
    this.signupBonus = true,
    this.freeHotelNight = false,
  });
}

class CardModel {
  final CardOffer meta; // original meta
  final double baseRate; // flat rate when no category rule applies
  final List<CategoryRule> categoryRules;
  final List<CardCredit> credits; // Card-specific credits (e.g., dining credit, travel credit)
  final RotatingCategoriesConfig? rotating;
  final double pointsToCash; // convert points to USD: 1 point * pointsToCash
  final double travelPortalMultiplier; // e.g., 1.25x via portal
  final Map<String, double> benefitValues; // per-benefit annual $ value
  final double signupBonus; // first-year signup bonus value (USD)

  const CardModel({
    required this.meta,
    required this.baseRate,
    required this.categoryRules,
    this.credits = const [],
    this.rotating,
    this.pointsToCash = 1.0,
    this.travelPortalMultiplier = 1.0,
    this.benefitValues = const {},
    this.signupBonus = 0,
  });
}

class OptimIQEngine {
  final List<CardModel> cards;
  final BenefitPreferences prefs;
  const OptimIQEngine({required this.cards, this.prefs = const BenefitPreferences()});

  double _finite(double v, {String? label}) {
    if (v.isFinite) return v;
    debugPrint('OptimIQ produced non-finite value${label == null ? '' : ' for $label'}: $v');
    return 0;
  }

  Map<String, double> _finiteMap(Map<String, double> m, {String? label}) =>
      m.map((k, v) => MapEntry(k, _finite(v, label: label == null ? k : '$label.$k')));

  String _fixed0(double v) {
    return Formatters.fixed(v, decimals: 0);
  }

  RecommendationResult recommend(List<SpendTransaction> txs, {int monthsInUpload = 1}) {
    debugPrint('OptimIQ.recommend: input=${txs.length} transactions, monthsInUpload=$monthsInUpload');
    
    // 1) Aggregate spend by Level 1 category (actual spend from uploaded data)
    final Map<String, double> spendByCategory = {for (final c in Level1Categories.all) c: 0};
    final Map<String, double> storeSpecificSpend = {};
    int excludedCount = 0;
    
    for (final t in txs) {
      // Only count actual spend. Credits/payments/fees we forced negative (e.g. "Interest") are excluded.
      if (t.amount <= 0) {
        excludedCount++;
        continue;
      }
      final amt = t.amount;
      spendByCategory.update(t.category, (v) => v + amt, ifAbsent: () => amt);
      
      for (final brand in StoreBrands.names) {
        if (t.merchant.toLowerCase().contains(brand.toLowerCase())) {
          storeSpecificSpend.update(brand, (v) => v + amt, ifAbsent: () => amt);
        }
      }
    }
    
    debugPrint('OptimIQ.recommend: excluded $excludedCount non-spend txs, counted ${txs.length - excludedCount} spend txs');
    final topCategories = spendByCategory.entries.where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    for (var i = 0; i < topCategories.take(5).length; i++) {
      final e = topCategories[i];
      debugPrint('  Category ${i + 1}: ${e.key} = \$${e.value.toStringAsFixed(2)}');
    }

    // 2) Compute single-card values (pass transactions and monthsInUpload for proper credit/earnings calculation)
    final singleCardResults = <String, _CardComputation>{};
    for (final c in cards) {
      final comp = _computeForSingleCard(c, spendByCategory, txs, monthsInUpload);
      singleCardResults[c.meta.id] = comp;
    }

    // 3) Sort all cards by net value (descending) and find the best
    final rankedCards = singleCardResults.values.toList()..sort((a, b) => b.netValue.compareTo(a.netValue));
    final bestSingle = rankedCards.isEmpty ? null : rankedCards.first;
    
    debugPrint('\n🏆 CARD RANKINGS (Top ${rankedCards.take(10).length}):');
    for (var i = 0; i < rankedCards.take(10).length; i++) {
      final comp = rankedCards[i];
      debugPrint('  #${i + 1}: ${comp.card.meta.issuer} ${comp.card.meta.name} = ${Formatters.money(comp.netValue)}/yr');
    }

    // 4) Best multi-card combo (up to 2 cards for tractability here)
    final bestCombo = _bestTwoCardCombo(cards, txs, monthsInUpload);

    // 5) Store-specific projection (simple 5% assumption if user had that store card)
    final storeCardProjections = <String, double>{};
    storeSpecificSpend.forEach((brand, spend) {
      storeCardProjections[brand] = spend * 0.05; // 5% typical baseline
    });

    // 6) Build RecommendationResult
    final now = DateTime.now();
    if (bestSingle == null) {
      return RecommendationResult(
        cardId: 'none',
        cardName: 'No Cards Available',
        estimatedAnnualValue: 0,
        totalRewards: 0,
        totalCredits: 0,
        totalBenefits: 0,
        annualFee: 0,
        firstYearBonus: 0,
        categoryEarnings: const {},
        spendByCategory: spendByCategory,
        storeSpecificSpend: storeSpecificSpend,
        perCardRewards: const {},
        allCardRankings: const [],
        capsNotes: const [],
        bestCombo: null,
        storeCardProjections: storeCardProjections,
        createdAt: now,
        updatedAt: now,
      );
    }

    return RecommendationResult(
      cardId: bestSingle.card.meta.id,
      cardName: '${bestSingle.card.meta.issuer} ${bestSingle.card.meta.name}',
      estimatedAnnualValue: _finite(bestSingle.netValue, label: 'estimatedAnnualValue'),
      totalRewards: _finite(bestSingle.rewards, label: 'totalRewards'),
      totalCredits: _finite(bestSingle.creditsApplied, label: 'totalCredits'),
      totalBenefits: _finite(bestSingle.benefits, label: 'totalBenefits'),
      annualFee: _finite(bestSingle.card.meta.annualFee, label: 'annualFee'),
      firstYearBonus: _finite(bestSingle.card.signupBonus, label: 'firstYearBonus'),
      categoryEarnings: _finiteMap(bestSingle.earnByCategory, label: 'categoryEarnings'),
      spendByCategory: spendByCategory,
      storeSpecificSpend: storeSpecificSpend,
      perCardRewards: singleCardResults.map((k, v) => MapEntry('${v.card.meta.issuer} ${v.card.meta.name}', _finite(v.rewards, label: 'perCardRewards.${v.card.meta.id}'))),
      allCardRankings: rankedCards.map((comp) => CardRankingDetail(
        cardId: comp.card.meta.id,
        cardName: '${comp.card.meta.issuer} ${comp.card.meta.name}',
        netValue: _finite(comp.netValue, label: 'netValue'),
        totalRewards: _finite(comp.rewards, label: 'rewards'),
        totalCredits: _finite(comp.creditsApplied, label: 'credits'),
        totalBenefits: _finite(comp.benefits, label: 'benefits'),
        annualFee: _finite(comp.card.meta.annualFee, label: 'annualFee'),
        firstYearBonus: _finite(comp.card.signupBonus, label: 'signupBonus'),
      )).toList(),
      capsNotes: bestSingle.capsNotes,
      bestCombo: bestCombo.toDisplay(),
      storeCardProjections: storeCardProjections,
      createdAt: now,
      updatedAt: now,
    );
  }

  _CardComputation _computeForSingleCard(CardModel card, Map<String, double> spendByCategory, List<SpendTransaction> txs, int monthsInUpload) {
    // Detailed output for debugging
    debugPrint('\n${'='*60}');
    debugPrint('${card.meta.issuer} ${card.meta.name}:');
    debugPrint('  Base rate: ${Formatters.percent(card.baseRate)}');
    debugPrint('  Category rules: ${card.categoryRules.length}');
    for (final rule in card.categoryRules) {
      debugPrint('    - ${rule.category}: ${Formatters.percent(rule.multiplier)}${rule.cap.amount != null ? ' (cap: \$${rule.cap.amount}/${rule.cap.period.name})' : ''}');
    }
    debugPrint('  Credits: ${card.credits.length}');
    for (final credit in card.credits) {
      debugPrint('    - ${credit.category}: \$${credit.creditValue}/${credit.frequency.name}${credit.matchLevel != CreditMatchLevel.none ? ' (match: ${credit.matchLevel.name} = ${credit.merchantL3 ?? credit.merchantL2 ?? credit.merchantL1 ?? 'any'})' : ''}');
    }
    
    double rewards = 0;
    double totalCreditsApplied = 0;
    final earnByCategory = <String, double>{};
    final capsNotes = <String>[];

    // Track cap consumption per rule
    final capUsed = <CategoryRule, double>{};

    // Helper to apply cap
    double _applyCap(CategoryRule rule, double spend) {
      if (rule.cap.amount == null) return spend;
      final used = capUsed[rule] ?? 0;
      final left = (rule.cap.amount! - used).clamp(0, double.infinity) as double;
      final applied = spend.clamp(0, left) as double;
      capUsed[rule] = used + applied;
      if (applied < spend) {
        capsNotes.add('${card.meta.name}: ${rule.category} capped at ${rule.cap.amount} per ${rule.cap.period.name}. Excess earns base rate.');
      }
      return applied;
    }

    // STEP 1: Apply merchant-level credits FIRST using transaction-level matching
    // Calculate how much qualifying spend exists for each credit (with merchant matching)
    final spendAfterCredits = <String, double>{};
    for (final entry in spendByCategory.entries) {
      spendAfterCredits[entry.key] = entry.value;
    }

    for (final credit in card.credits) {
      final category = credit.category;
      if (!spendAfterCredits.containsKey(category)) continue;
      
      // Calculate credit value for the upload period (NOT annualized)
      double creditValueForPeriod = 0;
      switch (credit.frequency) {
        case CapPeriod.monthly:
          creditValueForPeriod = credit.creditValue * monthsInUpload;
          break;
        case CapPeriod.quarterly:
          // For quarterly credits, calculate based on how many quarters in upload period
          final quartersInPeriod = (monthsInUpload / 3).clamp(0, 4);
          creditValueForPeriod = credit.creditValue * quartersInPeriod;
          break;
        case CapPeriod.annual:
          // Annual credits only apply if upload covers full year
          creditValueForPeriod = monthsInUpload >= 12 ? credit.creditValue : 0;
          break;
        case CapPeriod.none:
          creditValueForPeriod = credit.creditValue;
          break;
      }
      
      // Find qualifying spend for this credit (apply merchant matching)
      double qualifyingSpend = 0;
      final List<String> matchedMerchants = [];
      for (final tx in txs) {
        if (tx.amount <= 0) continue; // Skip refunds/fees
        if (credit.appliesTo(tx)) {
          qualifyingSpend += tx.amount;
          if (matchedMerchants.length < 3) matchedMerchants.add('${tx.merchant} (\$${tx.amount.toStringAsFixed(2)})');
        }
      }
      
      debugPrint('    Credit check: $category (${credit.frequency.name})');
      debugPrint('      Match level: ${credit.matchLevel.name}${credit.matchLevel != CreditMatchLevel.none ? ' = ${credit.merchantL3 ?? credit.merchantL2 ?? credit.merchantL1 ?? 'any'}' : ''}');
      debugPrint('      Qualifying spend: ${Formatters.money(qualifyingSpend)} from ${matchedMerchants.isEmpty ? 'no matches' : matchedMerchants.join(', ')}${matchedMerchants.length >= 3 ? '...' : ''}');
      debugPrint('      Credit value (${monthsInUpload}mo): ${Formatters.money(creditValueForPeriod)}');
      
      // Check if spend requirement is met (if any)
      if (credit.spendRequirement != null && qualifyingSpend < credit.spendRequirement!) {
        debugPrint('      ❌ NOT APPLIED: Requires ${Formatters.money(credit.spendRequirement!)} spend, found ${Formatters.money(qualifyingSpend)}');
        capsNotes.add('${card.meta.name}: ${Formatters.money(creditValueForPeriod)} ${credit.frequency.name} $category credit not applied (requires ${Formatters.money(credit.spendRequirement!)} qualifying spend, found ${Formatters.money(qualifyingSpend)})');
        continue;
      }
      
      // Reduce eligible spend by credit amount (credits offset spend, reducing rewards eligibility)
      final creditApplied = creditValueForPeriod.clamp(0, spendAfterCredits[category]!) as double;
      spendAfterCredits[category] = (spendAfterCredits[category]! - creditApplied).clamp(0, double.infinity) as double;
      totalCreditsApplied += creditApplied;
      
      if (creditApplied > 0) {
        debugPrint('      ✅ APPLIED: ${Formatters.money(creditApplied)}');
        final merchantInfo = credit.matchLevel != CreditMatchLevel.none 
          ? ' (matched ${matchedMerchants.isEmpty ? 'category only' : matchedMerchants.take(2).join(', ')})'
          : '';
        capsNotes.add('${card.meta.name}: ${Formatters.money(creditApplied)} ${credit.frequency.name} $category credit applied$merchantInfo');
      }
    }

    // STEP 2: Calculate rewards on remaining spend (after credits)
    debugPrint('\n  Category earnings (${monthsInUpload}mo actual spend):');
    for (final entry in spendAfterCredits.entries) {
      final cat = entry.key;
      var spend = entry.value;
      
      // Skip categories with no spend
      if (spend <= 0) continue;
      
      double earned = 0;
      // Match all rules for this category
      final rules = card.categoryRules.where((r) => r.category == cat).toList();
      
      if (rules.isEmpty) {
        // No special rule for this category - use base rate
        earned = spend * card.baseRate;
        debugPrint('    $cat: ${Formatters.money(spend)} × ${Formatters.percent(card.baseRate)} (base) = ${Formatters.money(earned)}');
      } else {
        final originalSpend = spend;
        for (final rule in rules) {
          final eligibleSpend = _applyCap(rule, spend);
          final ruleEarned = eligibleSpend * rule.multiplier;
          earned += ruleEarned;
          debugPrint('    $cat: ${Formatters.money(eligibleSpend)} × ${Formatters.percent(rule.multiplier)} = ${Formatters.money(ruleEarned)}');
          spend -= eligibleSpend;
        }
        // Remaining spend earns base rate
        if (spend > 0) {
          final baseEarned = spend * card.baseRate;
          earned += baseEarned;
          debugPrint('    $cat (excess): ${Formatters.money(spend)} × ${Formatters.percent(card.baseRate)} (base) = ${Formatters.money(baseEarned)}');
        }
      }
      
      earnByCategory[cat] = earned;
      rewards += earned;
    }

    // Rotating categories (assume two quarters benefit realized; simplification)
    if (card.rotating != null) {
      final rot = card.rotating!;
      // Approximate: sum all rotating categories' spend and apply cap across year
      final rotatingCats = rot.categoriesByQuarter.values.expand((e) => e).toSet();
      double totalRotSpend = 0;
      for (final c in rotatingCats) {
        totalRotSpend += spendByCategory[c] ?? 0;
      }
      final capAmt = rot.cap.amount ?? double.infinity;
      final applied = totalRotSpend.clamp(0, capAmt) as double;
      final extraOverBase = applied * (rot.multiplier - card.baseRate);
      rewards += extraOverBase; // add lift over base already counted
      capsNotes.add('${card.meta.name}: rotating categories up to ${_fixed0(capAmt)} per ${rot.cap.period.name}.');
    }

    // Benefit values from preferences
    double benefits = 0;
    benefits += prefs.loungeAccess ? (card.benefitValues['lounge'] ?? 0) : 0;
    benefits += prefs.tsaPre ? (card.benefitValues['tsa_pre'] ?? 0) : 0;
    benefits += prefs.travelInsurance ? (card.benefitValues['travel_ins'] ?? 0) : 0;
    benefits += prefs.cellPhoneProtection ? (card.benefitValues['cell'] ?? 0) : 0;
    benefits += prefs.extendedWarranty ? (card.benefitValues['warranty'] ?? 0) : 0;
    benefits += prefs.noFtf ? (card.benefitValues['no_ftf'] ?? 0) : 0;
    benefits += prefs.introApr ? (card.benefitValues['intro_apr'] ?? 0) : 0;
    benefits += prefs.signupBonus ? (card.benefitValues['signup'] ?? 0) : 0;
    benefits += prefs.freeHotelNight ? (card.benefitValues['free_night'] ?? 0) : 0;

    // STEP 3: Annualize all values for consistent comparison
    // Annualize rewards and credits (multiply by 12/monthsInUpload)
    final annualizationFactor = 12.0 / monthsInUpload;
    final annualRewards = rewards * annualizationFactor;
    final annualCredits = totalCreditsApplied * annualizationFactor;
    
    // Benefits are already annual values
    // Fee is already annual
    final net = (annualRewards + annualCredits + benefits) - card.meta.annualFee;
    
    final totalPositive = annualRewards + annualCredits + benefits;
    
    debugPrint('\n  📊 ANNUAL VALUE BREAKDOWN:');
    debugPrint('    ├─ Rewards: ${Formatters.money(annualRewards)}/yr (${Formatters.money(rewards)} × ${annualizationFactor.toStringAsFixed(1)})');
    debugPrint('    ├─ Statement Credits: ${Formatters.money(annualCredits)}/yr (${Formatters.money(totalCreditsApplied)} × ${annualizationFactor.toStringAsFixed(1)})');
    debugPrint('    ├─ Benefits: ${Formatters.money(benefits)}/yr');
    debugPrint('    ├─ ─────────────────────────────');
    debugPrint('    ├─ Total Rewards + Benefits: +${Formatters.money(totalPositive)}/yr');
    debugPrint('    ├─ Annual Fee: -${Formatters.money(card.meta.annualFee)}/yr');
    debugPrint('    └─ 🏆 NET VALUE: ${Formatters.money(net)}/yr');
    debugPrint('='*60);
    
    return _CardComputation(
      card: card,
      rewards: annualRewards,
      benefits: benefits,
      creditsApplied: annualCredits,
      netValue: net,
      earnByCategory: earnByCategory,
      capsNotes: capsNotes,
    );
  }

  _ComboResult _bestTwoCardCombo(List<CardModel> cards, List<SpendTransaction> txs, int monthsInUpload) {
    _ComboResult? best;
    for (int i = 0; i < cards.length; i++) {
      for (int j = i + 1; j < cards.length; j++) {
        final combo = _computeTwoCardRouting(cards[i], cards[j], txs, monthsInUpload);
        if (best == null || combo.netValue > best.netValue) best = combo;
      }
    }
    return best ?? _computeTwoCardRouting(cards.first, cards.first, txs, monthsInUpload);
  }

  _ComboResult _computeTwoCardRouting(CardModel a, CardModel b, List<SpendTransaction> txs, int monthsInUpload) {
    // Track caps per card per rule
    final capUsedA = <CategoryRule, double>{};
    final capUsedB = <CategoryRule, double>{};

    double rewardsA = 0, rewardsB = 0;
    final capsNotes = <String>[];

    double earnFor(CardModel c, SpendTransaction t, Map<CategoryRule, double> capUsed, void Function(String) note) {
      // We exclude non-spend transactions earlier; keep this defensively safe.
      if (t.amount <= 0) return 0;
      final amt = t.amount;
      double bestEarn = amt * c.baseRate;
      for (final rule in c.categoryRules.where((r) => r.category == t.category)) {
        final capAmt = rule.cap.amount;
        double eligible = amt;
        if (capAmt != null) {
          final used = capUsed[rule] ?? 0;
          final left = (capAmt - used).clamp(0, double.infinity) as double;
          eligible = (eligible.clamp(0, left)) as double;
        }
        final earn = (eligible * rule.multiplier) + ((amt - eligible) * c.baseRate);
        if (earn > bestEarn) {
          bestEarn = earn;
        }
      }
      return bestEarn;
    }

    for (final t in txs) {
      if (t.amount <= 0) continue;
      final earnA = earnFor(a, t, capUsedA, (s) => capsNotes.add(s));
      final earnB = earnFor(b, t, capUsedB, (s) => capsNotes.add(s));
      if (earnA >= earnB) {
        rewardsA += earnA;
      } else {
        rewardsB += earnB;
      }
    }

    // Annualize rewards to match single-card calculations
    final annualizationFactor = 12.0 / monthsInUpload;
    final annualRewardsA = rewardsA * annualizationFactor;
    final annualRewardsB = rewardsB * annualizationFactor;
    final totalAnnualRewards = annualRewardsA + annualRewardsB;
    
    final benefits = 0.0; // omit in combo calcs for simplicity; could add based on prefs
    final net = totalAnnualRewards + benefits - a.meta.annualFee - b.meta.annualFee;
    return _ComboResult(cards: [a, b], rewards: totalAnnualRewards, netValue: net, capsNotes: capsNotes);
  }

  // Phase 2: Per-transaction recommendation logic
  // Returns the single best card for a transaction, along with applied rate and rationale.
  _PerTxComputation bestForTransaction(SpendTransaction t) {
    if (t.amount <= 0) {
      // Non-spend transactions (payments/credits/interest) are excluded from earnings.
      return _PerTxComputation(
        card: cards.first,
        appliedRate: 0,
        baseRate: cards.first.baseRate,
        estimatedReward: 0,
        rationale: 'Excluded (non-spend transaction)',
      );
    }
    _PerTxComputation? best;
    for (final c in cards) {
      final comp = _earnForSingle(c, t);
      if (best == null || comp.estimatedReward > best.estimatedReward) {
        best = comp;
      }
    }
    return best ?? _PerTxComputation(
      card: cards.first,
      appliedRate: cards.first.baseRate,
      baseRate: cards.first.baseRate,
      estimatedReward: (t.amount.abs()) * cards.first.baseRate,
      rationale: 'Base rate applied',
    );
  }

  // Compute recommendations for all transactions
  List<_PerTxComputation> bestForTransactions(List<SpendTransaction> txs) {
    return txs.map(bestForTransaction).toList();
  }

  // Public: get UI-friendly records for all transactions
  List<PerTransactionRec> perTransactionRecords(List<SpendTransaction> txs) {
    final comps = bestForTransactions(txs);
    final records = <PerTransactionRec>[];
    for (int i = 0; i < comps.length; i++) {
      final c = comps[i];
      final t = txs[i];
      records.add(PerTransactionRec(
        transactionId: t.id,
        merchant: t.merchant,
        date: t.date,
        amount: t.amount,
        category: t.category,
        cardId: c.card.meta.id,
        cardDisplay: '${c.card.meta.issuer} ${c.card.meta.name}',
        appliedRate: c.appliedRate,
        baseRate: c.baseRate,
        estimatedReward: c.estimatedReward,
        rationale: c.rationale,
      ));
    }
    return records;
  }

  // Internal: compute reward rate for a single transaction on one card.
  _PerTxComputation _earnForSingle(CardModel c, SpendTransaction t) {
    if (t.amount <= 0) {
      return _PerTxComputation(
        card: c,
        appliedRate: 0,
        baseRate: c.baseRate,
        estimatedReward: 0,
        rationale: 'Excluded (non-spend transaction)',
      );
    }
    final amt = t.amount;
    double bestEarn = amt * c.baseRate;
    double appliedRate = c.baseRate;
    String reason = 'Base rate ${_pct(c.baseRate)} on ${t.category}';

    // Evaluate all matching category rules. If multiple exist, choose highest return.
    final rules = c.categoryRules.where((r) => r.category == t.category).toList();
    for (final r in rules) {
      // For a single transaction, assume cap does not bind unless amount exceeds cap; if so, blend.
      final capAmt = r.cap.amount;
      if (capAmt != null && capAmt < amt) {
        final earn = (capAmt * r.multiplier) + ((amt - capAmt) * c.baseRate);
        final effRate = amt > 0 ? earn / amt : 0.0;
        if (earn > bestEarn) {
          bestEarn = earn;
          appliedRate = effRate;
          reason = '${_pct(r.multiplier)} on ${r.category} up to ${_fixed0(capAmt)}, then base ${_pct(c.baseRate)} (blended ${_pct(effRate)})';
        }
      } else {
        final earn = amt * r.multiplier;
        if (earn > bestEarn) {
          bestEarn = earn;
          appliedRate = r.multiplier;
          reason = '${_pct(r.multiplier)} category match on ${r.category}';
        }
      }
    }

    return _PerTxComputation(
      card: c,
      appliedRate: appliedRate,
      baseRate: c.baseRate,
      estimatedReward: bestEarn,
      rationale: reason,
    );
  }

  String _pct(double r) {
    return Formatters.percent(r);
  }
}

class _CardComputation {
  final CardModel card;
  final double rewards;
  final double benefits;
  final double creditsApplied;
  final double netValue;
  final Map<String, double> earnByCategory;
  final List<String> capsNotes;
  const _CardComputation({
    required this.card,
    required this.rewards,
    required this.benefits,
    required this.creditsApplied,
    required this.netValue,
    required this.earnByCategory,
    required this.capsNotes,
  });
}

class _ComboResult {
  final List<CardModel> cards;
  final double rewards;
  final double netValue;
  final List<String> capsNotes;
  const _ComboResult({required this.cards, required this.rewards, required this.netValue, required this.capsNotes});

  Map<String, dynamic> toDisplay() {
    double finite(double v) => v.isFinite ? v : 0;
    return {
      'cards': cards.map((c) => '${c.meta.issuer} ${c.meta.name}').toList(),
      'rewards': finite(rewards),
      'netValue': finite(netValue),
      'capsNotes': capsNotes,
    };
  }
}

class _PerTxComputation {
  final CardModel card;
  final double appliedRate;
  final double baseRate;
  final double estimatedReward;
  final String rationale;
  const _PerTxComputation({
    required this.card,
    required this.appliedRate,
    required this.baseRate,
    required this.estimatedReward,
    required this.rationale,
  });
}

List<CardModel> comparisonCardsThree() {
  final now = DateTime.now();

  // Chase Sapphire Reserve
  final csrMeta = CardOffer(
    id: 'csr',
    issuer: 'Chase',
    name: 'Sapphire Reserve',
    categoryMultipliers: const {},
    baseCashback: 0.015, // UR at ~1.5cpp via portal
    annualFee: 550,
    affiliateUrlCJ: null,
    affiliateUrlImpact: null,
    affiliateUrlRakuten: null,
    affiliateUrlPartnerize: null,
    createdAt: now,
    updatedAt: now,
  );

  // Chase Freedom (Flex)
  final cffMeta = CardOffer(
    id: 'cff',
    issuer: 'Chase',
    name: 'Freedom Flex',
    categoryMultipliers: const {},
    baseCashback: 0.01,
    annualFee: 0,
    affiliateUrlCJ: null,
    affiliateUrlImpact: null,
    affiliateUrlRakuten: null,
    affiliateUrlPartnerize: null,
    createdAt: now,
    updatedAt: now,
  );

  // Amex Platinum
  final platMeta = CardOffer(
    id: 'amex_plat',
    issuer: 'American Express',
    name: 'Platinum',
    categoryMultipliers: const {},
    baseCashback: 0.01, // MR baseline at 1cpp equivalent
    annualFee: 695,
    affiliateUrlCJ: null,
    affiliateUrlImpact: null,
    affiliateUrlRakuten: null,
    affiliateUrlPartnerize: null,
    createdAt: now,
    updatedAt: now,
  );

  return [
    // CSR: 3x dining & travel (~4.5% at 1.5cpp), 1x base (~1.5%)
    // $300 annual travel credit
    CardModel(
      meta: csrMeta,
      baseRate: 0.015,
      categoryRules: const [
        CategoryRule(category: Level1Categories.dining, multiplier: 0.045),
        CategoryRule(category: Level1Categories.travel, multiplier: 0.045),
      ],
      credits: const [
        CardCredit(
          category: Level1Categories.travel,
          creditValue: 300,
          frequency: CapPeriod.annual,
        ),
      ],
      pointsToCash: 1.5,
      travelPortalMultiplier: 1.5,
      benefitValues: const {
        'lounge': 200,
        'travel_ins': 50,
      },
    ),

    // Freedom Flex: 5% rotating cats (1500/quarter), 3% dining & drugstores, 1% base
    CardModel(
      meta: cffMeta,
      baseRate: 0.01,
      categoryRules: const [
        CategoryRule(category: Level1Categories.dining, multiplier: 0.03),
        CategoryRule(category: Level1Categories.drugstores, multiplier: 0.03),
      ],
      rotating: RotatingCategoriesConfig(
        categoriesByQuarter: const {
          1: [Level1Categories.groceries],
          2: [Level1Categories.gas],
          3: [Level1Categories.streaming],
          4: [Level1Categories.onlineRetail],
        },
        multiplier: 0.05,
        cap: RewardCap(amount: 1500, period: CapPeriod.quarterly),
      ),
      pointsToCash: 1.0,
      travelPortalMultiplier: 1.0,
      benefitValues: const {},
    ),

    // Amex Platinum: 5x flights and prepaid hotels via Amex Travel (value ~1.25cpp -> ~6.25%)
    CardModel(
      meta: platMeta,
      baseRate: 0.01,
      categoryRules: const [
        CategoryRule(category: Level1Categories.travel, multiplier: 0.0625),
      ],
      pointsToCash: 1.25,
      travelPortalMultiplier: 1.25,
      benefitValues: const {
        'lounge': 300,
        'tsa_pre': 85,
        'travel_ins': 50,
      },
    ),
  ];
}
