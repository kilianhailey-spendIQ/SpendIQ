class CardRankingDetail {
  final String cardId;
  final String cardName;
  final double netValue;
  final double totalRewards;
  final double totalCredits;
  final double totalBenefits;
  final double annualFee;
  final double firstYearBonus;

  const CardRankingDetail({
    required this.cardId,
    required this.cardName,
    required this.netValue,
    required this.totalRewards,
    required this.totalCredits,
    required this.totalBenefits,
    required this.annualFee,
    required this.firstYearBonus,
  });
}

class RecommendationResult {
  final String cardId;
  final String cardName;
  final double estimatedAnnualValue; // rewards + credits + benefits - fees (ongoing annual value)
  final double totalRewards; // category earnings only
  final double totalCredits; // statement credits applied
  final double totalBenefits; // non-credit benefits (lounge, insurance, etc)
  final double annualFee;
  final double firstYearBonus; // signup bonus (separate from annual value)
  final Map<String, double> categoryEarnings; // breakdown by category
  final Map<String, double> spendByCategory; // Level 1 totals
  final Map<String, double> storeSpecificSpend; // brand -> total spend
  final Map<String, double> perCardRewards; // card display name -> rewards
  final List<CardRankingDetail> allCardRankings; // ALL cards ranked by net value (best to worst)
  final List<String> capsNotes; // human-readable notes about caps/limits
  final Map<String, dynamic>? bestCombo; // {'cards': [...], 'rewards': #, 'netValue': #, 'capsNotes': []}
  final Map<String, double> storeCardProjections; // brand -> est rewards with store card
  final DateTime createdAt;
  final DateTime updatedAt;

  const RecommendationResult({
    required this.cardId,
    required this.cardName,
    required this.estimatedAnnualValue,
    required this.totalRewards,
    this.totalCredits = 0,
    this.totalBenefits = 0,
    required this.annualFee,
    this.firstYearBonus = 0,
    required this.categoryEarnings,
    required this.spendByCategory,
    required this.storeSpecificSpend,
    required this.perCardRewards,
    this.allCardRankings = const [],
    required this.capsNotes,
    required this.bestCombo,
    required this.storeCardProjections,
    required this.createdAt,
    required this.updatedAt,
  });
}

class PerTransactionRec {
  final String transactionId;
  final String merchant;
  final DateTime date;
  final double amount;
  final String category; // Level 1
  final String cardId;
  final String cardDisplay; // Issuer + Name
  final double appliedRate; // e.g., 0.045 for 4.5%
  final double baseRate; // the card's base rate for comparison
  final double estimatedReward; // amount * appliedRate (abs(amount))
  final String rationale; // short human explanation

  const PerTransactionRec({
    required this.transactionId,
    required this.merchant,
    required this.date,
    required this.amount,
    required this.category,
    required this.cardId,
    required this.cardDisplay,
    required this.appliedRate,
    required this.baseRate,
    required this.estimatedReward,
    required this.rationale,
  });
}
