import 'package:flutter/foundation.dart';

class SpendTransaction {
  final String id;
  final DateTime date;
  final String description; // Full original description/line item
  final String merchant; // best-effort merchant name
  final String category; // Level 1 primary category
  final String? subcategory; // Level 2
  final String? brand; // Level 3 (precise store/brand)
  final String? special; // Special logic notes
  final double amount; // positive for spend, negative for refunds/interest/payments/excluded items
  /// Stable ordering index that preserves the exact order the user uploaded/copied.
  ///
  /// This is intentionally independent of [date] because many statements are not
  /// strictly chronological, and users expect analysis to follow their pasted order.
  final int? uploadOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  const SpendTransaction({
    required this.id,
    required this.date,
    required this.description,
    required this.merchant,
    required this.category,
    this.subcategory,
    this.brand,
    this.special,
    required this.amount,
    this.uploadOrder,
    required this.createdAt,
    required this.updatedAt,
  });

  SpendTransaction copyWith({
    String? id,
    DateTime? date,
    String? description,
    String? merchant,
    String? category,
    String? subcategory,
    String? brand,
    String? special,
    double? amount,
    int? uploadOrder,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      SpendTransaction(
        id: id ?? this.id,
        date: date ?? this.date,
        description: description ?? this.description,
        merchant: merchant ?? this.merchant,
        category: category ?? this.category,
        subcategory: subcategory ?? this.subcategory,
        brand: brand ?? this.brand,
        special: special ?? this.special,
        amount: amount ?? this.amount,
        uploadOrder: uploadOrder ?? this.uploadOrder,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'description': description,
        'merchant': merchant,
        'category': category,
        'subcategory': subcategory,
        'brand': brand,
        'special': special,
        'amount': amount,
        'upload_order': uploadOrder,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };

  static SpendTransaction fromJson(Map<String, dynamic> json) {
    try {
      return SpendTransaction(
        id: json['id'] as String,
        date: DateTime.tryParse(json['date'] as String? ?? '') ?? DateTime.now(),
        description: json['description'] as String? ?? '',
        merchant: json['merchant'] as String? ?? '',
        category: json['category'] as String? ?? 'uncategorized',
        subcategory: json['subcategory'] as String?,
        brand: json['brand'] as String?,
        special: json['special'] as String?,
        amount: (json['amount'] as num?)?.toDouble() ?? 0,
        uploadOrder: (json['upload_order'] as num?)?.toInt(),
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ?? DateTime.now(),
      );
    } catch (e) {
      debugPrint('SpendTransaction.fromJson error: $e');
      final now = DateTime.now();
      return SpendTransaction(
        id: 'invalid',
        date: now,
        description: 'invalid',
        merchant: 'invalid',
        category: 'uncategorized',
        amount: 0,
        createdAt: now,
        updatedAt: now,
      );
    }
  }
}
