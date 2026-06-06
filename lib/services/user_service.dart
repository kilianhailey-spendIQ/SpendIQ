import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:spendiq/models/user.dart';

/// Service for managing user data and subscription state
class UserService {
  final _supabase = Supabase.instance.client;

  /// Get current user data from Supabase
  Future<AppUser?> getCurrentUser() async {
    try {
      final authUser = _supabase.auth.currentUser;
      if (authUser == null) return null;

      final response = await _supabase.from('users').select().eq('id', authUser.id).maybeSingle();

      if (response == null) {
        // User exists in auth but not in users table - create profile
        debugPrint('User not found in users table, creating profile...');
        return await _createUserProfile(authUser);
      }

      return AppUser.fromJson(response);
    } catch (e) {
      debugPrint('Error getting current user: $e');
      return null;
    }
  }

  /// Create user profile in database (called after signup)
  Future<AppUser?> _createUserProfile(User authUser) async {
    try {
      final userData = {
        'id': authUser.id,
        'email': authUser.email,
        'name': authUser.userMetadata?['name'] as String?,
        'is_pro': false,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      };

      await _supabase.from('users').insert(userData);

      return AppUser.fromJson(userData);
    } catch (e) {
      debugPrint('Error creating user profile: $e');
      return null;
    }
  }

  /// Update user's subscription status (called after payment)
  Future<bool> updateSubscriptionStatus({
    required String userId,
    required bool isPro,
    DateTime? subscriptionExpiry,
    String? stripeCustomerId,
    String? stripeSubscriptionId,
  }) async {
    try {
      final updates = {
        'is_pro': isPro,
        'subscription_expiry': subscriptionExpiry?.toIso8601String(),
        'stripe_customer_id': stripeCustomerId,
        'stripe_subscription_id': stripeSubscriptionId,
        'updated_at': DateTime.now().toIso8601String(),
      };

      await _supabase.from('users').update(updates).eq('id', userId);

      debugPrint('Subscription status updated for user $userId: isPro=$isPro');
      return true;
    } catch (e) {
      debugPrint('Error updating subscription status: $e');
      return false;
    }
  }

  /// Check if user has active subscription
  Future<bool> hasActiveSubscription(String userId) async {
    try {
      final user = await getCurrentUser();
      if (user == null) return false;

      return user.hasActiveSubscription;
    } catch (e) {
      debugPrint('Error checking subscription status: $e');
      return false;
    }
  }

  /// Get user by Stripe customer ID (useful for webhook processing)
  Future<AppUser?> getUserByStripeCustomerId(String customerId) async {
    try {
      final response = await _supabase.from('users').select().eq('stripe_customer_id', customerId).maybeSingle();

      if (response == null) return null;

      return AppUser.fromJson(response);
    } catch (e) {
      debugPrint('Error getting user by Stripe customer ID: $e');
      return null;
    }
  }

  /// Update user profile (name, email, etc.)
  Future<bool> updateProfile({
    required String userId,
    String? name,
    String? email,
  }) async {
    try {
      final updates = <String, dynamic>{
        'updated_at': DateTime.now().toIso8601String(),
      };

      if (name != null) updates['name'] = name;
      if (email != null) updates['email'] = email;

      await _supabase.from('users').update(updates).eq('id', userId);

      debugPrint('Profile updated for user $userId');
      return true;
    } catch (e) {
      debugPrint('Error updating profile: $e');
      return false;
    }
  }
}
