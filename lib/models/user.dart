import 'package:flutter/foundation.dart';

class AppUser {
  final String id;
  final String? name;
  final String? email;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isPro;
  final DateTime? subscriptionExpiry;
  final String? stripeCustomerId;
  final String? stripeSubscriptionId;

  const AppUser({
    required this.id,
    this.name,
    this.email,
    required this.createdAt,
    required this.updatedAt,
    this.isPro = false,
    this.subscriptionExpiry,
    this.stripeCustomerId,
    this.stripeSubscriptionId,
  });

  AppUser copyWith({
    String? id,
    String? name,
    String? email,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isPro,
    DateTime? subscriptionExpiry,
    String? stripeCustomerId,
    String? stripeSubscriptionId,
  }) =>
      AppUser(
        id: id ?? this.id,
        name: name ?? this.name,
        email: email ?? this.email,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        isPro: isPro ?? this.isPro,
        subscriptionExpiry: subscriptionExpiry ?? this.subscriptionExpiry,
        stripeCustomerId: stripeCustomerId ?? this.stripeCustomerId,
        stripeSubscriptionId: stripeSubscriptionId ?? this.stripeSubscriptionId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'is_pro': isPro,
        'subscription_expiry': subscriptionExpiry?.toIso8601String(),
        'stripe_customer_id': stripeCustomerId,
        'stripe_subscription_id': stripeSubscriptionId,
      };

  static AppUser fromJson(Map<String, dynamic> json) {
    try {
      return AppUser(
        id: json['id'] as String,
        name: json['name'] as String?,
        email: json['email'] as String?,
        createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ?? DateTime.now(),
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ?? DateTime.now(),
        isPro: json['is_pro'] as bool? ?? false,
        subscriptionExpiry: json['subscription_expiry'] != null ? DateTime.tryParse(json['subscription_expiry'] as String) : null,
        stripeCustomerId: json['stripe_customer_id'] as String?,
        stripeSubscriptionId: json['stripe_subscription_id'] as String?,
      );
    } catch (e) {
      debugPrint('AppUser.fromJson error: $e');
      final now = DateTime.now();
      return AppUser(id: 'local', createdAt: now, updatedAt: now);
    }
  }

  /// Helper to check if user has active subscription
  bool get hasActiveSubscription {
    if (!isPro) return false;
    if (subscriptionExpiry == null) return false;
    return subscriptionExpiry!.isAfter(DateTime.now());
  }
}
