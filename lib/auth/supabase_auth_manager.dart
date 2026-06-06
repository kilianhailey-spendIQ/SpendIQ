import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:spendiq/auth/auth_manager.dart';

/// Supabase authentication implementation
class SupabaseAuthManager extends AuthManager with EmailSignInManager, GoogleSignInManager {
  final _supabase = Supabase.instance.client;

  @override
  User? get currentUser => _supabase.auth.currentUser;

  @override
  Stream<AuthState> get authStateChanges => _supabase.auth.onAuthStateChange;

  @override
  Future<User?> signInWithEmail(BuildContext context, String email, String password) async {
    try {
      final response = await _supabase.auth.signInWithPassword(email: email, password: password);
      return response.user;
    } on AuthException catch (e) {
      debugPrint('Sign in error: ${e.message}');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Colors.red),
        );
      }
      return null;
    } catch (e) {
      debugPrint('Sign in error: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('An unexpected error occurred'), backgroundColor: Colors.red),
        );
      }
      return null;
    }
  }

  @override
  Future<User?> createAccountWithEmail(BuildContext context, String email, String password) async {
    try {
      final response = await _supabase.auth.signUp(email: email, password: password);
      if (context.mounted && response.user != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Account created! Please check your email to verify.'), backgroundColor: Colors.green),
        );
      }
      return response.user;
    } on AuthException catch (e) {
      debugPrint('Sign up error: ${e.message}');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Colors.red),
        );
      }
      return null;
    } catch (e) {
      debugPrint('Sign up error: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('An unexpected error occurred'), backgroundColor: Colors.red),
        );
      }
      return null;
    }
  }

  @override
  Future<void> signOut() async {
    try {
      await _supabase.auth.signOut();
    } catch (e) {
      debugPrint('Sign out error: $e');
    }
  }

  @override
  Future<void> deleteUser(BuildContext context) async {
    try {
      // Supabase requires admin API for user deletion
      // For now, we'll sign out and let admin handle deletion via dashboard
      await signOut();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please contact support to delete your account')),
        );
      }
    } catch (e) {
      debugPrint('Delete user error: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Future<void> updateEmail({required String email, required BuildContext context}) async {
    try {
      await _supabase.auth.updateUser(UserAttributes(email: email));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Email updated! Please check your new email to verify.'), backgroundColor: Colors.green),
        );
      }
    } on AuthException catch (e) {
      debugPrint('Update email error: ${e.message}');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      debugPrint('Update email error: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('An unexpected error occurred'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Future<void> resetPassword({required String email, required BuildContext context}) async {
    try {
      await _supabase.auth.resetPasswordForEmail(email);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password reset email sent!'), backgroundColor: Colors.green),
        );
      }
    } on AuthException catch (e) {
      debugPrint('Reset password error: ${e.message}');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      debugPrint('Reset password error: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('An unexpected error occurred'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Future<User?> signInWithGoogle(BuildContext context) async {
    try {
      // Get the current URL for the redirect
      final redirectTo = kIsWeb ? Uri.base.toString() : null;
      
      final response = await _supabase.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: redirectTo,
      );
      
      if (!response) {
        debugPrint('Google sign-in was cancelled or failed');
        return null;
      }
      
      // On web, the user will be redirected to Google and back
      // The session will be automatically restored on return
      return _supabase.auth.currentUser;
    } on AuthException catch (e) {
      debugPrint('Google sign-in error: ${e.message}');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Colors.red),
        );
      }
      return null;
    } catch (e) {
      debugPrint('Google sign-in error: $e');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('An unexpected error occurred'), backgroundColor: Colors.red),
        );
      }
      return null;
    }
  }
}
