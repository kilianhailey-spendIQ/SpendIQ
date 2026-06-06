enum PlanTier { free, single, household }

class Plan {
  final PlanTier tier;
  final String name;
  final String description;
  final double price; // USD
  final bool recurring; // false: one-time, true: yearly
  final int maxUploads;
  final int maxMembers; // 1 or 2
  final bool simulationIncluded;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Plan({
    required this.tier,
    required this.name,
    required this.description,
    required this.price,
    required this.recurring,
    required this.maxUploads,
    required this.maxMembers,
    required this.simulationIncluded,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'tier': tier.name,
        'name': name,
        'description': description,
        'price': price,
        'recurring': recurring,
        'max_uploads': maxUploads,
        'max_members': maxMembers,
        'simulation_included': simulationIncluded,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  static Plan fromJson(Map<String, dynamic> json) => Plan(
        tier: PlanTier.values.firstWhere((e) => e.name == (json['tier'] as String? ?? 'free'), orElse: () => PlanTier.free),
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        price: (json['price'] as num?)?.toDouble() ?? 0,
        recurring: json['recurring'] as bool? ?? false,
        maxUploads: json['max_uploads'] as int? ?? 1,
        maxMembers: json['max_members'] as int? ?? 1,
        simulationIncluded: json['simulation_included'] as bool? ?? false,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ?? DateTime.now(),
      );
}
