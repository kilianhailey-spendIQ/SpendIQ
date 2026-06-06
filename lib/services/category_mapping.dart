import 'dart:async';
import 'dart:typed_data';
import 'package:excel/excel.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Loads optional Excel-based category mapping from assets/documents/category.xlsx
/// The sheet can contain columns like:
/// - keyword | category
/// - merchant | level1
/// Matching is case-insensitive and uses "contains" on the transaction description.
class CategoryMappingService {
  static const defaultAssetPath = 'assets/documents/category.xlsx';

  static bool _loaded = false;
  static final List<_Rule> _rules = [];

  /// Ensures mapping is loaded once. Safe to call repeatedly.
  static Future<void> ensureLoaded({String assetPath = defaultAssetPath}) async {
    if (_loaded) return;
    try {
      final data = await rootBundle.load(assetPath);
      await _loadFromBytes(data.buffer.asUint8List());
      _loaded = true;
      debugPrint('CategoryMappingService: loaded ${_rules.length} rules from $assetPath');
    } catch (e) {
      // Asset is optional; fail silently but mark as loaded to avoid repeated IO.
      _loaded = true;
      debugPrint('CategoryMappingService: no mapping loaded ($e)');
    }
  }

  /// Returns a category (ideally Level 1) if a rule matches, else null.
  static String? matchCategory(String description) {
    if (_rules.isEmpty) return null;
    // Normalize: replace separators with spaces and collapse whitespace for robust contains matching
    final d = description
        .toLowerCase()
        .replaceAll('*', ' ')
        // Keep true hyphens but normalize other dash variants to '-'
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll('‑', '-')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    for (final r in _rules) {
      if (_containsKeywordSpecial(d, r.keyword)) return r.category;
    }
    return null;
  }

  static bool _containsKeywordSpecial(String descNorm, String keywordNorm) {
    if (descNorm.isEmpty || keywordNorm.isEmpty) return false;
    if (keywordNorm == 'air') {
      // "air" must be at start OR preceded by a non-alphanumeric.
      // Allows: "Air Canada", " aircanada"; blocks: "kauairooftoptent".
      return RegExp(r'(^|[^a-z0-9])air').hasMatch(descNorm);
    }
    return descNorm.contains(keywordNorm);
  }

  /// Whether given category string is one of Level 1 categories.
  static bool isLevel1(String c) {
    final v = c.trim();
    if (v.isEmpty) return false;
    return v.toLowerCase() != 'uncategorized';
  }

  static Future<void> _loadFromBytes(Uint8List bytes) async {
    _rules.clear();
    final excel = Excel.decodeBytes(bytes);
    if (excel.tables.isEmpty) return;
    final table = excel.tables.values.first; // Use the first worksheet
    if (table.maxRows == 0) return;

    // Detect header indices
    int keywordCol = -1;
    int categoryCol = -1;
    final headerRow = table.rows.first;
    for (int i = 0; i < headerRow.length; i++) {
      final v = (headerRow[i]?.value?.toString() ?? '').toLowerCase().trim();
      if (v == 'keyword' || v == 'merchant' || v.contains('contains')) {
        keywordCol = i;
      }
      if (v == 'category' || v == 'level1' || v.contains('cat')) {
        categoryCol = i;
      }
    }

    if (keywordCol < 0 || categoryCol < 0) {
      debugPrint('CategoryMappingService: header not found (need keyword + category)');
      return;
    }

    for (int r = 1; r < table.rows.length; r++) {
      final row = table.rows[r];
      if (row.length <= keywordCol || row.length <= categoryCol) continue;
      final kw = (row[keywordCol]?.value?.toString() ?? '').trim();
      final cat = (row[categoryCol]?.value?.toString() ?? '').trim();
      if (kw.isEmpty || cat.isEmpty) continue;

      final normalizedKw = kw.toLowerCase();
      final normalizedCat = _normalizeToLevel1(cat);
      _rules.add(_Rule(keyword: normalizedKw, category: normalizedCat));
    }
  }

  static String _normalizeToLevel1(String input) {
    // Keep exact value from the mapping sheet; do not coerce into a hardcoded set.
    return input.trim();
  }
}

class _Rule {
  final String keyword; // lowercase
  final String category; // Level 1 normalized
  _Rule({required this.keyword, required this.category});
}
