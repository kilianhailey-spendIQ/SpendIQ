import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalStorageService {
  static const _kUserKey = 'spendiq_user';
  static const _kTransactionsKey = 'spendiq_transactions';
  static const _kPlanKey = 'spendiq_plan';

  Future<Map<String, dynamic>?> readJson(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('LocalStorageService.readJson error: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> readJsonList(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return [];
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded.whereType<Map<String, dynamic>>().toList();
      }
      return [];
    } catch (e) {
      debugPrint('LocalStorageService.readJsonList error: $e');
      return [];
    }
  }

  Future<void> writeJson(String key, Map<String, dynamic> value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(value));
    } catch (e) {
      debugPrint('LocalStorageService.writeJson error: $e');
    }
  }

  Future<void> writeJsonList(String key, List<Map<String, dynamic>> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(list));
    } catch (e) {
      debugPrint('LocalStorageService.writeJsonList error: $e');
    }
  }

  // Convenience keys
  String get userKey => _kUserKey;
  String get transactionsKey => _kTransactionsKey;
  String get planKey => _kPlanKey;

  /// Clears ALL SpendIQ-related local persisted data.
  ///
  /// This is intentionally scoped to keys starting with `spendiq_` so we do not
  /// interfere with other plugin storage (e.g., Supabase auth sessions).
  Future<int> clearAllSpendiqLocalData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith('spendiq_')).toList(growable: false);
      for (final k in keys) {
        await prefs.remove(k);
      }
      debugPrint('LocalStorageService.clearAllSpendiqLocalData removed=${keys.length}');
      return keys.length;
    } catch (e) {
      debugPrint('LocalStorageService.clearAllSpendiqLocalData error: $e');
      return 0;
    }
  }
}
