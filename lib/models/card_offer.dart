class CardOffer {
  final String id;
  final String issuer;
  final String name;
  final Map<String, double> categoryMultipliers; // e.g., {'groceries': 0.03}
  final double baseCashback; // e.g., 0.01 for 1%
  final double annualFee; // USD
  final String? affiliateUrlCJ;
  final String? affiliateUrlImpact;
  final String? affiliateUrlRakuten;
  final String? affiliateUrlPartnerize;
  final DateTime createdAt;
  final DateTime updatedAt;

  const CardOffer({
    required this.id,
    required this.issuer,
    required this.name,
    required this.categoryMultipliers,
    required this.baseCashback,
    required this.annualFee,
    this.affiliateUrlCJ,
    this.affiliateUrlImpact,
    this.affiliateUrlRakuten,
    this.affiliateUrlPartnerize,
    required this.createdAt,
    required this.updatedAt,
  });
}
