import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:excel/excel.dart';
import 'package:flutter/foundation.dart';
import 'package:spendiq/utils/formatters.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:spreadsheet_decoder/spreadsheet_decoder.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spendiq/core/optimiq.dart';
import 'package:spendiq/models/card_offer.dart';
import 'package:spendiq/core/categories.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Central loader for the offline Master Spreadsheet and program rules.
///
/// Goals (Phase 1, offline-only):
/// - Merchant cleaning via Merchant_Master_v21 mapping has priority over heuristics
/// - Optionally derive card models from spreadsheet if a simple sheet exists; otherwise fallback
/// - Strict scoping by Program Key is reserved for future matching (stubbed here)
class MasterSpreadsheetService {
  // Preferred packaged master spreadsheet (updated).
  static const String _assetPath = 'assets/documents/SpendIQ_MASTER_UPDATED_v100.xlsx';
  // Back-compat fallback (in case the new asset wasn't bundled correctly yet).
  static const String _assetFallbackPath = 'assets/documents/SpendIQ_MASTER_UPDATED_v100.xlsx';

  // === Option 1: master spreadsheet in Supabase Storage (file replacement workflow) ===
  // Keep bucket/path stable; you can replace the file any time.
  // Defaults per app workflow:
  // - bucket: master-bucket
  // - path: SpendIQ_MASTER_UPDATED_v100.xlsx
  static const String _supabaseMasterBucket = String.fromEnvironment('SUPABASE_MASTER_BUCKET', defaultValue: 'master-bucket');
  static const String _supabaseMasterPath = String.fromEnvironment('SUPABASE_MASTER_PATH', defaultValue: 'SpendIQ_MASTER_UPDATED_v100.xlsx');
  static const String _supabaseMasterUpdatedAtKey = 'spendiq_master_supabase_updated_at';
  // Cache key/version are intentionally bumped whenever the shipped XLSX changes.
  // Otherwise Flutter Web will happily keep using the previously persisted mapping
  // and it will look like the new spreadsheet "didn't apply".
  static const String _merchantCacheKey = 'spendiq_master_merchant_map_v100_2026_04_19_cleaned';
  // Bump this when the cache payload OR load heuristics OR underlying XLSX changes.
  static const String _merchantCacheVersion = 'v100_cleaned';
  static bool _loaded = false;
  static Future<void>? _loadFuture;

  // Merchant master mapping: raw substring (lowercase) -> row metadata
  static final Map<String, MerchantMasterRow> _merchantMap = <String, MerchantMasterRow>{};
  // Lightweight inverted index: token -> set of keys that contain it (for fuzzy candidates)
  static final Map<String, Set<String>> _tokenToKeys = <String, Set<String>>{};

  // Performance: avoid sorting the full key set for every transaction.
  // Built once after load/seed and reused.
  static List<String> _keysByLengthDesc = const [];
  // Performance: avoid recomputing alphanumeric-only versions for every key check.
  static final Map<String, String> _alnumKeyCache = <String, String>{};
  // Performance: normalized + tokenized key caches for word-match ranking.
  static final Map<String, String> _normKeyCache = <String, String>{};
  static final Map<String, List<String>> _keyWordsCache = <String, List<String>>{};

  // Fast exact-match indexes:
  // - normalized phrase -> candidate keys
  // - alnum-only phrase -> candidate keys
  // These prevent obvious matches (case/punctuation/spaces) from being lost due to token prefiltering.
  static final Map<String, Set<String>> _normToKeys = <String, Set<String>>{};
  static final Map<String, Set<String>> _alnumToKeys = <String, Set<String>>{};

  static String _lastMasterSource = 'none';
  static String get lastMasterSource => _lastMasterSource;

  // Minimal in-memory program/card registry constructed from spreadsheet (if available)
  static List<CardModel>? _cardModels;

  /// Fast startup path: load only the merchant mapping from local storage if present.
  ///
  /// This avoids decoding the XLSX on Flutter Web (which can block the UI thread).
  /// Safe to call at app startup.
  static Future<void> prewarmFromCache() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_merchantCacheKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      if (decoded['version'] != _merchantCacheVersion) return;
      final data = decoded['data'];
      if (data is! Map) return;

      _merchantMap.clear();
      for (final entry in data.entries) {
        final key = entry.key;
        final v = entry.value;
        if (key is! String) continue;
        if (v is String) {
          // Backward-compatible cache payload: key -> clean merchant
          _merchantMap[key] = MerchantMasterRow(cleanMerchant: v);
        } else if (v is Map) {
          final clean = (v['cleanMerchant'] ?? v['clean'] ?? '').toString().trim();
          if (clean.isEmpty) continue;
          final l1 = (v['level1'] ?? v['Level_1'] ?? '').toString().trim();
          final l2 = (v['level2'] ?? v['Level_2'] ?? '').toString().trim();
          final idx = int.tryParse((v['rowIndex'] ?? v['row'] ?? '').toString());
          _merchantMap[key] = MerchantMasterRow(
            cleanMerchant: clean,
            level1: l1.isEmpty ? null : l1,
            level2: l2.isEmpty ? null : l2,
            rowIndex: idx,
          );
        }
      }
      // No hardcoded merchant/category seeds — Master sheet is the source of truth.
      _rebuildFastKeyCaches();
      _loaded = true;
      debugPrint('MasterSpreadsheetService: prewarmed from cache. merchants=${_merchantMap.length}');
    } catch (e) {
      debugPrint('MasterSpreadsheetService: prewarm from cache failed: $e');
    }
  }

  static Future<void> _writeMerchantCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        'version': _merchantCacheVersion,
        'data': _merchantMap.map((k, v) => MapEntry(k, v.toJson())),
      };
      await prefs.setString(_merchantCacheKey, jsonEncode(payload));
    } catch (e) {
      debugPrint('MasterSpreadsheetService: write cache failed: $e');
    }
  }

  static Future<void> ensureLoaded() async {
    if (_loaded) return;

    // Prevent multiple concurrent loads (which can easily happen when several
    // transactions are parsed/categorized around the same time).
    final existing = _loadFuture;
    if (existing != null) return existing;

    final future = () async {
      try {
        // Cheap fast-path: if a cache exists (from a previous run), use it.
        await prewarmFromCache();
        if (_loaded) return;

        // Preferred path (Option 1): if Supabase is configured, try fetching the master
        // from Supabase Storage. Otherwise fall back to the packaged asset.
        final supabaseBytes = await _tryLoadMasterBytesFromSupabase();
        final rawBytes = supabaseBytes ?? (await _loadMasterBytesFromAssets());
        _lastMasterSource = supabaseBytes != null ? 'supabase' : 'asset';

        final decoded = _decodeMasterToRowMatrix(rawBytes);
        _loadMerchantMasterFromRowMatrix(decoded.rowsBySheet, preferredSheetNameHint: 'merchant_master');
        // Load cards from either Excel or row matrix (spreadsheet_decoder fallback)
        if (decoded.excel != null) {
          _cardModels = _tryBuildCards(decoded.excel!);
        }
        if (_cardModels == null || _cardModels!.isEmpty) {
          _cardModels = _tryBuildCardsFromRowMatrix(decoded.rowsBySheet);
        }
        // No hardcoded merchant/category seeds — Master sheet is the source of truth.
        _rebuildFastKeyCaches();
        // Persist mapping so subsequent loads avoid XLSX decoding.
        await _writeMerchantCache();
        _loaded = true;
        debugPrint('MasterSpreadsheetService: loaded ($_lastMasterSource). merchants=${_merchantMap.length}, cards=${_cardModels?.length ?? 0}');
      } catch (e) {
        _loaded = true; // mark as done to avoid repeat I/O; operate in fallback mode
        // Even if spreadsheet isn't available, still seed a few critical mappings.
        // No hardcoded merchant/category seeds — Master sheet is the source of truth.
        _rebuildFastKeyCaches();
        _lastMasterSource = 'fallback';
        debugPrint('MasterSpreadsheetService: spreadsheet not loaded ($e). Using fallbacks.');
      } finally {
        // Allow re-attempting load only if we *didn't* mark loaded for some reason.
        if (!_loaded) _loadFuture = null;
      }
    }();

    _loadFuture = future;
    return future;
  }

  static Future<Uint8List> _loadMasterBytesFromAssets() async {
    try {
      return (await rootBundle.load(_assetPath)).buffer.asUint8List();
    } catch (e) {
      debugPrint('MasterSpreadsheetService: failed to load asset master at "$_assetPath": $e');
      // Fallback is intentionally best-effort; if it also fails, rethrow so the caller
      // can enter fallback mode.
      return (await rootBundle.load(_assetFallbackPath)).buffer.asUint8List();
    }
  }

  /// Force refresh the master spreadsheet from Supabase Storage.
  ///
  /// Use this after you replace the XLSX in Supabase to immediately apply new rows
  /// (including Level 1/2/3 columns) without shipping a new app build.
  static Future<String> forceRefreshFromSupabase() async {
    try {
      final bytes = await _tryLoadMasterBytesFromSupabase(forceDownload: true);
      if (bytes == null) {
        return 'Supabase master not configured (or not reachable). Still using cached/asset master.';
      }

      await _resetCaches();

      final decoded = _decodeMasterToRowMatrix(bytes);
      _loadMerchantMasterFromRowMatrix(decoded.rowsBySheet, preferredSheetNameHint: 'merchant_master');
      if (decoded.excel != null) {
        _cardModels = _tryBuildCards(decoded.excel!);
      }
      // No hardcoded merchant/category seeds — Master sheet is the source of truth.
      _rebuildFastKeyCaches();
      await _writeMerchantCache();
      _loaded = true;
      return 'Master refreshed from Supabase. merchants=${_merchantMap.length}';
    } catch (e) {
      debugPrint('MasterSpreadsheetService: force refresh failed: $e');
      return 'Failed to refresh from Supabase: $e';
    }
  }

  static Future<void> _resetCaches() async {
    _loaded = false;
    _loadFuture = null;
    _merchantMap.clear();
    _tokenToKeys.clear();
    _alnumKeyCache.clear();
    _normKeyCache.clear();
    _keyWordsCache.clear();
    _normToKeys.clear();
    _alnumToKeys.clear();
    _keysByLengthDesc = const [];
    _cardModels = null;
    _lastMasterSource = 'none';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_merchantCacheKey);
    } catch (e) {
      debugPrint('MasterSpreadsheetService: failed to clear merchant cache: $e');
    }
  }

  /// Clears in-memory master data and removes the cached merchant map from local storage.
  ///
  /// Use this when the local cache has become corrupted or when you need a truly
  /// clean run for debugging parity between platforms.
  static Future<void> clearLocalMasterCaches() async {
    await _resetCaches();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_supabaseMasterUpdatedAtKey);
    } catch (e) {
      debugPrint('MasterSpreadsheetService: failed to clear updated_at cache: $e');
    }
  }

  static SupabaseClient? _supabaseClientOrNull() {
    try {
      return Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  static ({String dir, String name}) _splitStoragePath(String path) {
    final p = path.replaceAll(RegExp(r'^/+'), '');
    final idx = p.lastIndexOf('/');
    if (idx < 0) return (dir: '', name: p);
    return (dir: p.substring(0, idx), name: p.substring(idx + 1));
  }

  /// Attempt to download the master XLSX from Supabase Storage.
  ///
  /// If [forceDownload] is false, we try to compare `updated_at` via `list()` first
  /// and skip the download when nothing changed.
  static Future<Uint8List?> _tryLoadMasterBytesFromSupabase({bool forceDownload = false}) async {
    final client = _supabaseClientOrNull();
    if (client == null) return null;
    if (_supabaseMasterBucket.trim().isEmpty || _supabaseMasterPath.trim().isEmpty) return null;

    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedUpdatedAt = prefs.getString(_supabaseMasterUpdatedAtKey);

      String? remoteUpdatedAt;
      if (!forceDownload) {
        try {
          final split = _splitStoragePath(_supabaseMasterPath);
          final items = await client.storage.from(_supabaseMasterBucket).list(path: split.dir);
          final hit = items.where((o) => o.name == split.name).firstOrNull;
          remoteUpdatedAt = hit?.updatedAt;
        } catch (e) {
          // If listing fails, we can still attempt download.
          debugPrint('MasterSpreadsheetService: Supabase list failed (will try download): $e');
        }

        if (remoteUpdatedAt != null && cachedUpdatedAt != null && remoteUpdatedAt == cachedUpdatedAt) {
          // No change; rely on existing merchant-map cache.
          return null;
        }
      }

      final bytes = await client.storage.from(_supabaseMasterBucket).download(_supabaseMasterPath);
      try {
        if (remoteUpdatedAt != null) await prefs.setString(_supabaseMasterUpdatedAtKey, remoteUpdatedAt);
      } catch (e) {
        debugPrint('MasterSpreadsheetService: failed to persist updated_at: $e');
      }
      debugPrint('MasterSpreadsheetService: downloaded master from Supabase (${bytes.length} bytes).');
      return bytes;
    } catch (e) {
      debugPrint(
        'MasterSpreadsheetService: Supabase master download failed (bucket="$_supabaseMasterBucket" path="$_supabaseMasterPath"): $e',
      );

      // NOTE: Supabase Storage often returns “not_found” both when the object
      // path is wrong *and* when the bucket/object is private and the current
      // client (anon, unauthenticated) has no read permissions.
      // Give an explicit hint so setup issues are obvious.
      debugPrint(
        'MasterSpreadsheetService: If your bucket is PRIVATE, the anon key cannot read it. Make the bucket public, or add auth + RLS policies / signed URLs.',
      );

      // Common setup issue: the path constant doesn't match the uploaded filename.
      // If we get a 404/not_found, try to discover the best candidate XLSX in the bucket.
      final discovered = await _tryDiscoverAndDownloadMasterFromSupabase(client);
      if (discovered != null) return discovered;
      return null;
    }
  }

  static Future<Uint8List?> _tryDiscoverAndDownloadMasterFromSupabase(SupabaseClient client) async {
    try {
      // We only attempt discovery when the configured path doesn't exist.
      // Strategy:
      // 1) List root and common folders.
      // 2) Prefer filenames that look like our master.
      // 3) Fallback: newest .xlsx in the bucket.
      final bucket = _supabaseMasterBucket;
      final preferredTokens = <String>['spendiq', 'master'];
      final candidateDirs = <String>['', ...{_splitStoragePath(_supabaseMasterPath).dir}.where((d) => d.isNotEmpty)];

      final all = <({String path, String name, String? updatedAt})>[];
      for (final dir in candidateDirs) {
        List<FileObject> items;
        try {
          items = await client.storage.from(bucket).list(path: dir);
        } catch (_) {
          continue;
        }
        for (final o in items) {
          final name = o.name;
          if (!name.toLowerCase().endsWith('.xlsx')) continue;
          final fullPath = dir.isEmpty ? name : '$dir/$name';
          all.add((path: fullPath, name: name, updatedAt: o.updatedAt));
        }
      }

      if (all.isEmpty) {
        debugPrint('MasterSpreadsheetService: Supabase discovery: no .xlsx objects found in bucket "$bucket"');
        return null;
      }

      int scoreCandidate(({String path, String name, String? updatedAt}) c) {
        final n = c.name.toLowerCase();
        int score = 0;
        for (final t in preferredTokens) {
          if (n.contains(t)) score += 10;
        }
        if (n.replaceAll('_', '').replaceAll('-', '').contains('spendiqmaster')) score += 15;
        if (n == _supabaseMasterPath.toLowerCase()) score += 50;
        return score;
      }

      all.sort((a, b) {
        final sa = scoreCandidate(a);
        final sb = scoreCandidate(b);
        if (sa != sb) return sb.compareTo(sa);
        // Tie-breaker: latest updatedAt first when parseable.
        DateTime? pa;
        DateTime? pb;
        try {
          if (a.updatedAt != null) pa = DateTime.tryParse(a.updatedAt!);
          if (b.updatedAt != null) pb = DateTime.tryParse(b.updatedAt!);
        } catch (_) {}
        if (pa != null && pb != null && pa != pb) return pb.compareTo(pa);
        return a.name.compareTo(b.name);
      });

      final best = all.first;
      debugPrint('MasterSpreadsheetService: Supabase discovery: using "${best.path}" (was "$_supabaseMasterPath").');
      final bytes = await client.storage.from(bucket).download(best.path);
      debugPrint('MasterSpreadsheetService: downloaded discovered master from Supabase (${bytes.length} bytes).');
      return bytes;
    } catch (e) {
      debugPrint('MasterSpreadsheetService: Supabase discovery failed: $e');
      return null;
    }
  }

  static ({Excel? excel, Map<String, List<List<String>>> rowsBySheet}) _decodeMasterToRowMatrix(Uint8List bytes) {
    // The `excel` package can fail on some spreadsheets due to number format/style
    // edge cases (seen in the wild as: "custom numFmtId starts at 164 but found a value of 0").
    // When it fails, we fall back to `spreadsheet_decoder`, which is typically
    // more tolerant because it ignores most style metadata.

    Excel? excel;
    try {
      excel = _tryDecodeWithExcel(bytes);
    } catch (e) {
      debugPrint('MasterSpreadsheetService: primary XLSX decoder failed, will try fallback: $e');
    }

    if (excel != null) {
      final rowsBySheet = <String, List<List<String>>>{};
      for (final entry in excel.tables.entries) {
        final name = entry.key;
        final table = entry.value;
        final rows = <List<String>>[];
        for (final row in table.rows) {
          rows.add(row.map((c) => (c?.value?.toString() ?? '').trim()).toList(growable: false));
        }
        rowsBySheet[name] = rows;
      }
      return (excel: excel, rowsBySheet: rowsBySheet);
    }

    // Fallback decoder
    final decoder = SpreadsheetDecoder.decodeBytes(bytes, update: true);
    final rowsBySheet = <String, List<List<String>>>{};
    for (final entry in decoder.tables.entries) {
      final name = entry.key;
      final t = entry.value;
      final rows = <List<String>>[];
      for (final row in t.rows) {
        rows.add(row.map((v) => (v?.toString() ?? '').trim()).toList(growable: false));
      }
      rowsBySheet[name] = rows;
    }
    debugPrint('MasterSpreadsheetService: decoded XLSX via spreadsheet_decoder. sheets=${rowsBySheet.keys.length}');
    return (excel: null, rowsBySheet: rowsBySheet);
  }

  static Excel _tryDecodeWithExcel(Uint8List bytes) {
    try {
      return Excel.decodeBytes(bytes);
    } catch (e1) {
      debugPrint('MasterSpreadsheetService: Excel.decodeBytes failed (default): $e1');
      rethrow;
    }
  }

  static void _loadMerchantMasterFromRowMatrix(
    Map<String, List<List<String>>> rowsBySheet, {
    required String preferredSheetNameHint,
  }) {
    try {
      if (rowsBySheet.isEmpty) throw StateError('no sheets');
      MapEntry<String, List<List<String>>>? entry;
      final hint = preferredSheetNameHint.toLowerCase();
      entry = rowsBySheet.entries.where((e) => e.key.toLowerCase().contains(hint)).firstOrNull;
      entry ??= rowsBySheet.entries
          .where((e) => e.key.toLowerCase().contains('merchant') && e.key.toLowerCase().contains('master'))
          .firstOrNull;
      entry ??= rowsBySheet.entries.first;

      final sheetName = entry.key;
      final rows = entry.value;
      if (rows.isEmpty) return;
      debugPrint('MasterSpreadsheetService: parsing Merchant Master from sheet "$sheetName" rows=${rows.length}');

      // Detect header indices.
      int rawCol = -1;
      int cleanCol = -1;
      int level1Col = -1;
      int level2Col = -1;
      final header = rows.first;
      for (int i = 0; i < header.length; i++) {
        final v = _normHeader(header[i]);
        final isMerchantKeyword = v.contains('merchantorkeyword') || (v.contains('merchant') && v.contains('keyword'));
        if (isMerchantKeyword) {
          rawCol = rawCol < 0 ? i : rawCol;
          continue;
        }
        if (v == 'level1' || v.contains('level1') || v.contains('lvl1')) level1Col = level1Col < 0 ? i : level1Col;
        if (v == 'level2' || v.contains('level2') || v.contains('lvl2')) level2Col = level2Col < 0 ? i : level2Col;
        if (v.contains('raw') || v.contains('original') || v.contains('pattern')) rawCol = rawCol < 0 ? i : rawCol;
        if (v.contains('clean') || v.contains('standard') || (v.contains('merchant') && !v.contains('keyword'))) {
          cleanCol = cleanCol < 0 ? i : cleanCol;
        }
      }

      // When headers are missing, fallback to a simple positional layout.
      // We intentionally avoid any hardcoded category recognition here — the Master
      // sheet is the source of truth and can use arbitrary Level 1/2 strings.
      if (rawCol < 0 || cleanCol < 0) {
        debugPrint('MasterSpreadsheetService: Merchant_Master headers not found (matrix); inferring columns from data…');
        final merchCol = 0;
        int inferredCleanCol = merchCol;
        int inferredLevel1Col = -1;
        int inferredLevel2Col = -1;

        // Common layouts:
        //  A) Merchant | Level 1 | Level 2
        //  B) Merchant | Clean/Standard | Level 1 | Level 2
        if (header.length == 3) {
          inferredCleanCol = merchCol;
          inferredLevel1Col = 1;
          inferredLevel2Col = 2;
        } else if (header.length >= 4) {
          inferredCleanCol = 1;
          inferredLevel1Col = 2;
          inferredLevel2Col = 3;
        } else if (header.length == 2) {
          inferredCleanCol = 1;
        }

        debugPrint(
          'MasterSpreadsheetService: inferred columns (matrix) merch=$merchCol clean=$inferredCleanCol level1=$inferredLevel1Col level2=$inferredLevel2Col',
        );

        for (int r = 1; r < rows.length; r++) {
          final row = rows[r];
          if (row.length <= merchCol) continue;
          final raw = row[merchCol].trim();
          if (raw.isEmpty) continue;
          final key = raw.toLowerCase();
          if (_merchantMap.containsKey(key)) continue;

           final rawClean = (row.length > inferredCleanCol) ? row[inferredCleanCol].trim() : '';
           final rawL1 = (inferredLevel1Col >= 0 && row.length > inferredLevel1Col) ? row[inferredLevel1Col].trim() : '';
           final rawL2 = (inferredLevel2Col >= 0 && row.length > inferredLevel2Col) ? row[inferredLevel2Col].trim() : '';

           final repaired = _repairMerchantMasterFields(raw: raw, clean: rawClean, level1: rawL1, level2: rawL2);
           _merchantMap[key] = MerchantMasterRow(cleanMerchant: repaired.cleanMerchant, level1: repaired.level1, level2: repaired.level2, rowIndex: r);
          _MSMatch.indexKeyTokens(key);
        }
        return;
      }

      for (int r = 1; r < rows.length; r++) {
        final row = rows[r];
        if (row.length <= rawCol || row.length <= cleanCol) continue;
        final raw = row[rawCol].trim();
        final clean = row[cleanCol].trim();
        if (raw.isEmpty || clean.isEmpty) continue;
        final key = raw.toLowerCase();
         final rawL1 = (level1Col >= 0 && row.length > level1Col) ? row[level1Col].trim() : '';
         final rawL2 = (level2Col >= 0 && row.length > level2Col) ? row[level2Col].trim() : '';
         final repaired = _repairMerchantMasterFields(raw: raw, clean: clean, level1: rawL1, level2: rawL2);
         _merchantMap[key] = MerchantMasterRow(cleanMerchant: repaired.cleanMerchant, level1: repaired.level1, level2: repaired.level2, rowIndex: r);
        _MSMatch.indexKeyTokens(key);
      }
    } catch (e) {
      debugPrint('MasterSpreadsheetService: load merchant master (matrix) failed: $e');
    }
  }

   static ({String cleanMerchant, String? level1, String? level2}) _repairMerchantMasterFields({
     required String raw,
     required String clean,
     required String level1,
     required String level2,
   }) {
     // Minimal, non-destructive cleanup only. We do not attempt to "fix" columns
     // based on hardcoded category lists — Level 1/2 must be exactly what the
     // sheet provides.
     final cleanMerchant = clean.trim().isNotEmpty ? clean.trim() : raw.trim();
     final outL1 = level1.trim().isEmpty ? null : level1.trim();
     final outL2 = level2.trim().isEmpty ? null : level2.trim();
     return (cleanMerchant: cleanMerchant, level1: outL1, level2: outL2);
   }

  static String _normHeader(String v) => v
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '')
      .trim();


  static void _rebuildFastKeyCaches() {
    try {
      final keys = _merchantMap.keys.toList(growable: false);
      keys.sort((a, b) => b.length.compareTo(a.length));
      _keysByLengthDesc = keys;

      // Rebuild token index in sync with the current key set.
      _tokenToKeys
        ..clear();
      _normToKeys
        ..clear();
      _alnumToKeys
        ..clear();
      _alnumKeyCache
        ..clear()
        ..addEntries(keys.map((k) => MapEntry(k, _MSMatch.alnumOnly(k))));
      _normKeyCache
        ..clear()
        ..addEntries(keys.map((k) => MapEntry(k, _MSMatch.normalizeForMatching(k))));
      _keyWordsCache
        ..clear()
        ..addEntries(keys.map((k) {
          final nk = _normKeyCache[k] ?? _MSMatch.normalizeForMatching(k);
          final words = nk.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList(growable: false);
          return MapEntry(k, words);
        }));

      for (final k in keys) {
        final nk = _normKeyCache[k] ?? _MSMatch.normalizeForMatching(k);
        if (nk.isNotEmpty) _normToKeys.putIfAbsent(nk, () => <String>{}).add(k);
        final ak = _alnumKeyCache[k] ?? _MSMatch.alnumOnly(k);
        if (ak.isNotEmpty) _alnumToKeys.putIfAbsent(ak, () => <String>{}).add(k);
      }

      for (final k in keys) {
        _MSMatch.indexKeyTokens(k);
      }
    } catch (e) {
      debugPrint('MasterSpreadsheetService: rebuild key caches failed: $e');
      _keysByLengthDesc = _merchantMap.keys.toList(growable: false);
    }
  }

  /// Returns the best Merchant Master match row for this merchant string.
  ///
  /// This uses the same ranking rules as [cleanMerchantFromMapping], but returns
  /// the full row (clean merchant + Level 1/Level 2 when present).
  static MerchantMasterMatch? matchMerchantMaster(String rawMerchant) {
    if (!_loaded) return null;
    if (_merchantMap.isEmpty) return null;

    final dNorm = _MSMatch.normalizeForMatching(rawMerchant);
    if (dNorm.isEmpty) return null;
    final dAlnum = _MSMatch.alnumOnly(dNorm);
    final dWords = dNorm.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList(growable: false);

    // 0) O(1) exact match (case/punctuation/space-insensitive)
    final exactNormKeys = _normToKeys[dNorm];
    if (exactNormKeys != null && exactNormKeys.isNotEmpty) {
      final bestKey = exactNormKeys.toList()..sort((a, b) => b.length.compareTo(a.length));
      final row = _merchantMap[bestKey.first];
      if (row != null) return MerchantMasterMatch(key: bestKey.first, row: row, method: MerchantCleanMethod.exactMatch, tier: 0, score: 9999.0);
    }
    final exactAlnumKeys = _alnumToKeys[dAlnum];
    if (exactAlnumKeys != null && exactAlnumKeys.isNotEmpty) {
      final bestKey = exactAlnumKeys.toList()..sort((a, b) => b.length.compareTo(a.length));
      final row = _merchantMap[bestKey.first];
      if (row != null) return MerchantMasterMatch(key: bestKey.first, row: row, method: MerchantCleanMethod.exactMatch, tier: 0, score: 9998.0);
    }

    final tokens = _MSMatch.descTokensForIndexing(dNorm);
    final candidates = <String>{};
    for (final t in tokens) {
      final ks = _tokenToKeys[t];
      if (ks != null) candidates.addAll(ks);
    }

    // If the token index yields no candidates, we still allow a cheap
    // substring scan using the already-sorted key list (longest-first).
    // This preserves the user rule: character-string matching should work even
    // when tokenization fails.
    if (candidates.isEmpty) {
      for (final key in _keysByLengthDesc) {
        final kn = _normKeyCache[key];
        if (kn == null || kn.isEmpty) continue;
        if (_MSMatch._containsKeywordSpecial(dNorm, kn)) {
          final row = _merchantMap[key];
          if (row != null) {
            return MerchantMasterMatch(key: key, row: row, method: MerchantCleanMethod.fullPhraseContains, tier: 1, score: 8000.0 + kn.length);
          }
        }
        final ka = _alnumKeyCache[key];
        if (ka != null && ka.length >= 4 && dAlnum.contains(ka)) {
          final row = _merchantMap[key];
          if (row != null) {
            return MerchantMasterMatch(key: key, row: row, method: MerchantCleanMethod.fullPhraseContains, tier: 1, score: 7900.0 + ka.length);
          }
        }
      }
      return null;
    }

    // Two-pass strategy:
    // 1) Try token-prefiltered candidates for speed.
    // 2) If that produces no strong match, fall back to scanning all keys.
    // This prevents the prefilter from accidentally excluding the correct key
    // due to punctuation/pluralization/tokenization quirks.
    final bestFromCandidates = candidates.isNotEmpty
        ? _bestMatchForKeys(
            descNorm: dNorm,
            descWords: dWords,
            descAlnum: dAlnum,
            scanKeys: candidates,
            normKeyCache: _normKeyCache,
            alnumKeyCache: _alnumKeyCache,
            keyWordsCache: _keyWordsCache,
          )
        : null;
    final best = (bestFromCandidates != null && bestFromCandidates.isStrong)
        ? bestFromCandidates
        : _bestMatchForKeys(
            descNorm: dNorm,
            descWords: dWords,
            descAlnum: dAlnum,
            scanKeys: _merchantMap.keys,
            normKeyCache: _normKeyCache,
            alnumKeyCache: _alnumKeyCache,
            keyWordsCache: _keyWordsCache,
          );

    if (best == null) return null;
    if (!best.isStrong) return null;
    final row = _merchantMap[best.keyRaw];
    if (row == null) return null;
    return MerchantMasterMatch(key: best.keyRaw, row: row, method: best.method, tier: best.tier, score: best.rankScore);
  }

  /// Lightweight lookup used by troubleshooting UI to display Level 1/Level 2 for
  /// a candidate key.
  static MerchantMasterRow? getMerchantMasterRowByKey(String key) => _merchantMap[key];

  /// Return a cleaned merchant name if a mapping matches; else null.
  ///
  /// Rule: We treat any key in Merchant_Master_v21 as a substring matcher on the
  /// raw description line. The first match wins (longer keys are checked first).
  static String? cleanMerchantFromMapping(String rawDescription) {
    if (!_loaded) return null; // not ready yet
    if (_merchantMap.isEmpty) return null;

    final dNorm = _MSMatch.normalizeForMatching(rawDescription);
    if (dNorm.isEmpty) return null;
    final dAlnum = _MSMatch.alnumOnly(dNorm);
    final dWords = dNorm.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList(growable: false);

    // 0) O(1) exact match (case/punctuation/space-insensitive)
    final exactNormKeys = _normToKeys[dNorm];
    if (exactNormKeys != null && exactNormKeys.isNotEmpty) {
      final bestKey = exactNormKeys.toList()..sort((a, b) => b.length.compareTo(a.length));
      return _merchantMap[bestKey.first]?.cleanMerchant;
    }
    final exactAlnumKeys = _alnumToKeys[dAlnum];
    if (exactAlnumKeys != null && exactAlnumKeys.isNotEmpty) {
      final bestKey = exactAlnumKeys.toList()..sort((a, b) => b.length.compareTo(a.length));
      return _merchantMap[bestKey.first]?.cleanMerchant;
    }

    final tokens = _MSMatch.descTokensForIndexing(dNorm);
    final candidates = <String>{};
    for (final t in tokens) {
      final ks = _tokenToKeys[t];
      if (ks != null) candidates.addAll(ks);
    }

    // No index overlap => do a cheap longest-first substring scan to honor
    // character-string matching rules.
    if (candidates.isEmpty) {
      for (final key in _keysByLengthDesc) {
        final kn = _normKeyCache[key];
        if (kn == null || kn.isEmpty) continue;
        if (_MSMatch._containsKeywordSpecial(dNorm, kn)) return _merchantMap[key]?.cleanMerchant;
        final ka = _alnumKeyCache[key];
        if (ka != null && ka.length >= 4 && dAlnum.contains(ka)) return _merchantMap[key]?.cleanMerchant;
      }
      return null;
    }

    final bestFromCandidates = candidates.isNotEmpty
        ? _bestMatchForKeys(
            descNorm: dNorm,
            descWords: dWords,
            descAlnum: dAlnum,
            scanKeys: candidates,
            normKeyCache: _normKeyCache,
            alnumKeyCache: _alnumKeyCache,
            keyWordsCache: _keyWordsCache,
          )
        : null;
    final best = (bestFromCandidates != null && bestFromCandidates.isStrong)
        ? bestFromCandidates
        : _bestMatchForKeys(
            descNorm: dNorm,
            descWords: dWords,
            descAlnum: dAlnum,
            scanKeys: _merchantMap.keys,
            normKeyCache: _normKeyCache,
            alnumKeyCache: _alnumKeyCache,
            keyWordsCache: _keyWordsCache,
          );

    if (best == null) return null;
    if (!best.isStrong) return null;
    return _merchantMap[best.keyRaw]?.cleanMerchant;
  }

  /// Debug/explain version of [cleanMerchantFromMapping].
  ///
  /// This is intentionally more expensive than the production path and should be
  /// used only for troubleshooting UI.
  static MerchantCleanExplain explainMerchantCleaning(String rawDescription, {int topCandidates = 6}) {
    final loaded = _loaded;
    if (!loaded || _merchantMap.isEmpty) {
      return MerchantCleanExplain(
        rawDescription: rawDescription,
        cleanedMerchant: null,
        method: MerchantCleanMethod.notLoaded,
        matchedKey: null,
        details: const {},
        topCandidates: const [],
      );
    }

    final dNorm = _MSMatch.normalizeForMatching(rawDescription);
    final dAlnum = _MSMatch.alnumOnly(dNorm);
    final dWords = dNorm.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList(growable: false);

    // Show exact-match hits first (this is what users expect for things like KING SOOPERS).
    final exactNormKeys = _normToKeys[dNorm];
    if (exactNormKeys != null && exactNormKeys.isNotEmpty) {
      final bestKey = exactNormKeys.toList()..sort((a, b) => b.length.compareTo(a.length));
      final row = _merchantMap[bestKey.first];
      return MerchantCleanExplain(
        rawDescription: rawDescription,
        cleanedMerchant: row?.cleanMerchant,
        method: MerchantCleanMethod.exactMatch,
        matchedKey: bestKey.first,
        details: {
          'master_source': lastMasterSource,
          'normalized': dNorm,
          'alnum': dAlnum,
          'exact_norm_match_count': exactNormKeys.length,
        },
        topCandidates: bestKey
            .take(topCandidates)
            .map((k) => MerchantCleanCandidate(key: k, score: 9999.0, notes: const {'tier': 0, 'method': 'exactMatch'}))
            .toList(growable: false),
      );
    }
    final exactAlnumKeys = _alnumToKeys[dAlnum];
    if (exactAlnumKeys != null && exactAlnumKeys.isNotEmpty) {
      final bestKey = exactAlnumKeys.toList()..sort((a, b) => b.length.compareTo(a.length));
      final row = _merchantMap[bestKey.first];
      return MerchantCleanExplain(
        rawDescription: rawDescription,
        cleanedMerchant: row?.cleanMerchant,
        method: MerchantCleanMethod.exactMatch,
        matchedKey: bestKey.first,
        details: {
          'master_source': lastMasterSource,
          'normalized': dNorm,
          'alnum': dAlnum,
          'exact_alnum_match_count': exactAlnumKeys.length,
        },
        topCandidates: bestKey
            .take(topCandidates)
            .map((k) => MerchantCleanCandidate(key: k, score: 9998.0, notes: const {'tier': 0, 'method': 'exactMatch'}))
            .toList(growable: false),
      );
    }

    final tokens = _MSMatch.descTokensForIndexing(dNorm);
    final candidates = <String>{};
    for (final t in tokens) {
      final ks = _tokenToKeys[t];
      if (ks != null) candidates.addAll(ks);
    }

    // If we have no overlap with the token index, do a substring scan (longest-first)
    // and show the first few hits.
    if (candidates.isEmpty) {
      final hits = <String>[];
      for (final key in _keysByLengthDesc) {
        final kn = _normKeyCache[key];
        if (kn != null && kn.isNotEmpty && _MSMatch._containsKeywordSpecial(dNorm, kn)) {
          hits.add(key);
        } else {
          final ka = _alnumKeyCache[key];
          if (ka != null && ka.length >= 4 && dAlnum.contains(ka)) hits.add(key);
        }
        if (hits.length >= topCandidates) break;
      }

      final bestKey = hits.firstOrNull;
      final row = bestKey == null ? null : _merchantMap[bestKey];
      return MerchantCleanExplain(
        rawDescription: rawDescription,
        cleanedMerchant: row?.cleanMerchant,
        method: row == null ? MerchantCleanMethod.noMatch : MerchantCleanMethod.fullPhraseContains,
        matchedKey: bestKey,
        details: {
          'master_source': lastMasterSource,
          'normalized': dNorm,
          'alnum': dAlnum,
          'tokens': tokens.toList(growable: false),
          'candidateCount': 0,
          'substring_scan': true,
        },
        topCandidates: hits
            .map((k) => MerchantCleanCandidate(key: k, score: 8000, notes: const {'tier': 1, 'method': 'fullPhraseContains'}))
            .toList(growable: false),
      );
    }

    // Rank + explain token-index candidates first.
    var scanKeys = candidates;
    final scored = <_MatchScore>[];
    for (final key in scanKeys) {
      if (key.isEmpty) continue;
      scored.add(_MSMatch.scoreKeyAgainst(
        descNorm: dNorm,
        descWords: dWords,
        descAlnum: dAlnum,
        keyRaw: key,
        keyNorm: _normKeyCache[key] ?? _MSMatch.normalizeForMatching(key),
        keyWords: _keyWordsCache[key] ?? (_MSMatch.normalizeForMatching(key).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList(growable: false)),
        keyAlnum: _alnumKeyCache[key] ?? _MSMatch.alnumOnly(key),
      ));
    }
    scored.sort((a, b) => b.compareTo(a));
    final best = scored.isNotEmpty ? scored.first : null;

    final didSecondPass = best == null || !best.isStrong;
    if (didSecondPass) {
      // Second-pass (all keys) for explanation only.
      scanKeys = _merchantMap.keys.toSet();
      scored
        ..clear();
      for (final key in scanKeys) {
        if (key.isEmpty) continue;
        scored.add(_MSMatch.scoreKeyAgainst(
          descNorm: dNorm,
          descWords: dWords,
          descAlnum: dAlnum,
          keyRaw: key,
          keyNorm: _normKeyCache[key] ?? _MSMatch.normalizeForMatching(key),
          keyWords: _keyWordsCache[key] ?? (_MSMatch.normalizeForMatching(key).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList(growable: false)),
          keyAlnum: _alnumKeyCache[key] ?? _MSMatch.alnumOnly(key),
        ));
      }
      scored.sort((a, b) => b.compareTo(a));
    }
    final top2 = scored.take(topCandidates).toList(growable: false);
    final best2 = scored.isNotEmpty ? scored.first : null;

    if (best2 == null || !best2.isStrong) {
      return MerchantCleanExplain(
        rawDescription: rawDescription,
        cleanedMerchant: null,
        method: MerchantCleanMethod.noMatch,
        matchedKey: null,
        details: {
          'normalized': dNorm,
          'alnum': dAlnum,
          'tokens': tokens.toList(growable: false),
          'candidateCount': candidates.length,
          'secondPassAllKeys': didSecondPass,
        },
        topCandidates: top2
            .map((c) => MerchantCleanCandidate(key: c.keyRaw, score: c.rankScore, notes: c.explainCandidate))
            .toList(growable: false),
      );
    }

    final bestRow = _merchantMap[best2.keyRaw];
    return MerchantCleanExplain(
      rawDescription: rawDescription,
      cleanedMerchant: bestRow?.cleanMerchant,
      method: best2.explainMethod,
      matchedKey: best2.keyRaw,
      details: {
        'normalized': dNorm,
        'alnum': dAlnum,
        'tier': best2.tier,
        'candidateCount': candidates.length,
        'secondPassAllKeys': candidates.isNotEmpty && (best == null || !best.isStrong),
        if (bestRow?.level1 != null) 'level1': bestRow!.level1!,
        if (bestRow?.level2 != null) 'level2': bestRow!.level2!,
        ...best2.explain,
      },
      topCandidates: top2
          .map((c) => MerchantCleanCandidate(key: c.keyRaw, score: c.rankScore, notes: c.explainCandidate))
          .toList(growable: false),
    );
  }

  /// Get card models sourced from spreadsheet if available; otherwise use defaults.
  static List<CardModel> getCardModelsOrFallback() {
    if (_cardModels != null && _cardModels!.isNotEmpty) return _cardModels!;
    return comparisonCardsThree();
  }

  // === Internal loaders ===

  // ignore: unused_element
  static void _loadMerchantMaster(Excel excel) {
    try {
      // Find a sheet whose name contains 'merchant_master' (case-insensitive)
      final entry = excel.tables.entries.firstWhere(
        (e) => e.key.toLowerCase().contains('merchant_master'),
        orElse: () => excel.tables.entries.firstWhere(
          (e) => e.key.toLowerCase().contains('merchant') && e.key.toLowerCase().contains('master'),
          orElse: () => excel.tables.entries.isEmpty ? throw StateError('no sheets') : excel.tables.entries.first,
        ),
      );
      final table = entry.value;
      if (table.maxRows == 0) return;

      // Detect header indices: prefer columns that look like raw/clean names
      int rawCol = -1;
      int cleanCol = -1;
      int level1Col = -1;
      int level2Col = -1;
      final header = table.rows.first;
      for (int i = 0; i < header.length; i++) {
        final raw = (header[i]?.value?.toString() ?? '');
        final v = _normHeader(raw);
        // Common variants in your Merchant_Master_v21 tab:
        // - Merchant or Keyword
        // - Merchant_or_Keyword
        // - Merchant/Keyword
        final isMerchantKeyword = v.contains('merchantorkeyword') || (v.contains('merchant') && v.contains('keyword'));
        if (isMerchantKeyword) {
          // IMPORTANT: this column is the *raw match key* (keyword). Do not
          // automatically treat it as the cleaned merchant column too—many
          // master sheets have a separate "Clean Merchant" / "Standard" column.
          rawCol = rawCol < 0 ? i : rawCol;
          continue;
        }
        if (v == 'level1' || v.contains('level1') || v.contains('lvl1')) level1Col = level1Col < 0 ? i : level1Col;
        if (v == 'level2' || v.contains('level2') || v.contains('lvl2')) level2Col = level2Col < 0 ? i : level2Col;
        if (v.contains('raw') || v.contains('original') || v.contains('pattern')) rawCol = rawCol < 0 ? i : rawCol;
        if (v.contains('clean') || v.contains('standard') || (v.contains('merchant') && !v.contains('keyword'))) {
          cleanCol = cleanCol < 0 ? i : cleanCol;
        }
      }
      if (rawCol < 0 || cleanCol < 0) {
        // Fallback: simple positional layout. We avoid any hardcoded recognition
        // of category names — Level 1/2 values come exactly from the sheet.
        debugPrint('MasterSpreadsheetService: Merchant_Master headers not found; using positional columns…');
        final merchCol = 0;
        int inferredCleanCol = merchCol;
        int inferredLevel1Col = -1;
        int inferredLevel2Col = -1;

        final colCount = table.rows.first.length;
        if (colCount == 3) {
          // Merchant | Level1 | Level2
          inferredCleanCol = merchCol;
          inferredLevel1Col = 1;
          inferredLevel2Col = 2;
        } else if (colCount >= 4) {
          // Merchant | Clean | Level1 | Level2
          inferredCleanCol = 1;
          inferredLevel1Col = 2;
          inferredLevel2Col = 3;
        } else if (colCount == 2) {
          inferredCleanCol = 1;
        }

        debugPrint(
          'MasterSpreadsheetService: inferred columns merch=$merchCol clean=$inferredCleanCol level1=$inferredLevel1Col level2=$inferredLevel2Col',
        );

        for (int r = 1; r < table.rows.length; r++) {
          final row = table.rows[r];
          if (row.length <= merchCol) continue;
          final raw = (row[merchCol]?.value?.toString() ?? '').trim();
          if (raw.isEmpty) continue;
          final key = raw.toLowerCase();
          if (_merchantMap.containsKey(key)) continue;

          final rawClean = (row.length > inferredCleanCol) ? (row[inferredCleanCol]?.value?.toString() ?? '').trim() : '';
          final rawL1 = (inferredLevel1Col >= 0 && row.length > inferredLevel1Col) ? (row[inferredLevel1Col]?.value?.toString() ?? '').trim() : '';
          final rawL2 = (inferredLevel2Col >= 0 && row.length > inferredLevel2Col) ? (row[inferredLevel2Col]?.value?.toString() ?? '').trim() : '';
          final repaired = _repairMerchantMasterFields(raw: raw, clean: rawClean, level1: rawL1, level2: rawL2);
          _merchantMap[key] = MerchantMasterRow(
            cleanMerchant: repaired.cleanMerchant,
            level1: repaired.level1,
            level2: repaired.level2,
            rowIndex: r,
          );
          _MSMatch.indexKeyTokens(key);
        }
        return;
      }

      for (int r = 1; r < table.rows.length; r++) {
        final row = table.rows[r];
        if (row.length <= rawCol || row.length <= cleanCol) continue;
        final raw = (row[rawCol]?.value?.toString() ?? '').trim();
        final clean = (row[cleanCol]?.value?.toString() ?? '').trim();
        if (raw.isEmpty || clean.isEmpty) continue;
        final key = raw.toLowerCase();
        final rawL1 = (level1Col >= 0 && row.length > level1Col) ? (row[level1Col]?.value?.toString() ?? '').trim() : '';
        final rawL2 = (level2Col >= 0 && row.length > level2Col) ? (row[level2Col]?.value?.toString() ?? '').trim() : '';
        final repaired = _repairMerchantMasterFields(raw: raw, clean: clean, level1: rawL1, level2: rawL2);
        _merchantMap[key] = MerchantMasterRow(cleanMerchant: repaired.cleanMerchant, level1: repaired.level1, level2: repaired.level2, rowIndex: r);
        _MSMatch.indexKeyTokens(key);
      }
    } catch (e) {
      debugPrint('MasterSpreadsheetService: load merchant master failed: $e');
    }
  }

  static List<CardModel>? _tryBuildCards(Excel excel) {
    try {
      // Load credits first (from Credits tab)
      final creditsByProgramKey = _tryLoadCredits(excel);
      
      // Simple sheet discovery. We look for a sheet with columns similar to:
      // Program Key | Issuer | Name | BaseRate% | AnnualFee | Dining% | Groceries% | Gas% | Flights% | Hotels% | Transit%
      final entry = excel.tables.entries.firstWhere(
        (e) => e.key.toLowerCase().contains('program') || e.key.toLowerCase().contains('card'),
        orElse: () => excel.tables.entries.first,
      );
      final table = entry.value;
      if (table.maxRows == 0) return null;

      // Map headers
      final header = table.rows.first.map((c) => (c?.value?.toString() ?? '').toLowerCase().trim()).toList();
      int idxKey = header.indexWhere((h) => h.contains('program') || h == 'key' || h.contains('id'));
      int idxIssuer = header.indexWhere((h) => h.contains('issuer') || h.contains('bank'));
      int idxName = header.indexWhere((h) => h == 'name' || h.contains('product'));
      int idxBase = header.indexWhere((h) => h.contains('base'));
      int idxFee = header.indexWhere((h) => h.contains('annual') && h.contains('fee'));

      double pct(dynamic v) {
        final s = (v?.toString() ?? '').replaceAll('%', '').trim();
        final d = double.tryParse(s) ?? 0.0;
        return (d > 1.0) ? (d / 100.0) : d; // accept either 5 or 0.05
      }

      // Category columns by Level1 name match
      int cDining = header.indexWhere((h) => h.contains('dining') || h.contains('restaurant'));
      int cGroceries = header.indexWhere((h) => h.contains('grocery'));
      int cGas = header.indexWhere((h) => h.contains('gas') || h.contains('fuel'));
      int cFlights = header.indexWhere((h) => h.contains('flight') || h.contains('air'));
      int cHotels = header.indexWhere((h) => h.contains('hotel'));
      int cTransit = header.indexWhere((h) => h.contains('transit') || h.contains('rideshare') || h.contains('transport'));

      final now = DateTime.now();
      final models = <CardModel>[];
      for (int r = 1; r < table.rows.length; r++) {
        final row = table.rows[r];
        if (row.isEmpty) continue;
        String key = (idxKey >= 0 && r < table.maxRows) ? (row[idxKey]?.value?.toString() ?? '').trim() : '';
        String issuer = (idxIssuer >= 0) ? (row[idxIssuer]?.value?.toString() ?? '').trim() : '';
        String name = (idxName >= 0) ? (row[idxName]?.value?.toString() ?? '').trim() : '';
        double baseRate = pct(idxBase >= 0 ? row[idxBase]?.value : null);
        double fee = double.tryParse((idxFee >= 0 ? row[idxFee]?.value?.toString() : '') ?? '') ?? 0.0;

        if (issuer.isEmpty || name.isEmpty) continue;
        if (baseRate <= 0) baseRate = 0.01; // sensible default

        final rules = <CategoryRule>[];
        void addRule(int idx, String cat) {
          if (idx >= 0) {
            final v = pct(row[idx]?.value);
            if (v > 0) rules.add(CategoryRule(category: cat, multiplier: v));
          }
        }
        addRule(cDining, Level1Categories.dining);
        addRule(cGroceries, Level1Categories.groceries);
        addRule(cGas, Level1Categories.gas);
        // Travel is a single Level 1 category in the app. If multiple travel columns
        // exist in the sheet (Flights/Hotels/Transit), keep the best multiplier.
        void addTravelRule(int idx) {
          if (idx < 0) return;
          final v = pct(row[idx]?.value);
          if (v <= 0) return;
          final existingIdx = rules.indexWhere((r) => r.category == Level1Categories.travel);
          if (existingIdx < 0) {
            rules.add(CategoryRule(category: Level1Categories.travel, multiplier: v));
            return;
          }
          if (v > rules[existingIdx].multiplier) {
            rules[existingIdx] = CategoryRule(category: Level1Categories.travel, multiplier: v);
          }
        }
        addTravelRule(cFlights);
        addTravelRule(cHotels);
        addTravelRule(cTransit);

        // AMEX_GOLD_RESY special case: boost dining to at least 4% if detected in key
        if (key.toUpperCase().contains('AMEX_GOLD_RESY')) {
          final idx = rules.indexWhere((r) => r.category == Level1Categories.dining);
          if (idx >= 0) {
            if (rules[idx].multiplier < 0.04) {
              rules[idx] = CategoryRule(category: Level1Categories.dining, multiplier: 0.04);
            }
          } else {
            rules.add(const CategoryRule(category: Level1Categories.dining, multiplier: 0.04));
          }
        }

        final meta = CardOffer(
          id: key.isNotEmpty ? key : '${issuer.toLowerCase().replaceAll(' ', '_')}_${name.toLowerCase().replaceAll(' ', '_')}',
          issuer: issuer,
          name: name,
          categoryMultipliers: const {},
          baseCashback: baseRate,
          annualFee: fee,
          affiliateUrlCJ: null,
          affiliateUrlImpact: null,
          affiliateUrlRakuten: null,
          affiliateUrlPartnerize: null,
          createdAt: now,
          updatedAt: now,
        );
        // Attach credits for this card (if any)
        final cardCredits = creditsByProgramKey[key] ?? <CardCredit>[];
        
        models.add(CardModel(
          meta: meta,
          baseRate: baseRate,
          categoryRules: rules,
          credits: cardCredits,
          rotating: null,
          pointsToCash: 1.0,
          travelPortalMultiplier: 1.0,
          benefitValues: const {},
        ));
      }
      return models.isEmpty ? null : models;
    } catch (e) {
      debugPrint('MasterSpreadsheetService: build cards failed: $e');
      return null;
    }
  }

  /// Load credits from the Credits tab in the Master spreadsheet (v106 schema).
  /// Returns a map of Program Key -> List of CardCredit objects.
  static Map<String, List<CardCredit>> _tryLoadCredits(Excel excel) {
    final creditsByProgramKey = <String, List<CardCredit>>{};
    
    try {
      // Find Credits sheet
      MapEntry<String, Sheet>? creditsEntry;
      for (final entry in excel.tables.entries) {
        if (entry.key.toLowerCase().contains('credit')) {
          creditsEntry = entry;
          break;
        }
      }
      
      if (creditsEntry == null) {
        debugPrint('MasterSpreadsheetService: No Credits tab found in spreadsheet');
        return creditsByProgramKey;
      }
      
      final table = creditsEntry.value;
      if (table.maxRows == 0) return creditsByProgramKey;
      
      // v106 schema columns:
      // Program Key | Category | Credit Value | Frequency | Spend Requirement | 
      // Match Level | Credit_Merchant_L1 | Credit_Merchant_L2 | Credit_Merchant_L3
      final header = table.rows.first.map((c) => (c?.value?.toString() ?? '').toLowerCase().trim()).toList();
      
      int idxProgramKey = header.indexWhere((h) => h.contains('program') && h.contains('key'));
      if (idxProgramKey < 0) idxProgramKey = header.indexWhere((h) => h.contains('key') || h == 'card' || h.contains('card id'));
      
      int idxCategory = header.indexWhere((h) => h.contains('category') && !h.contains('merchant'));
      int idxCreditValue = header.indexWhere((h) => h.contains('credit') && (h.contains('value') || h.contains('amount')));
      if (idxCreditValue < 0) idxCreditValue = header.indexWhere((h) => h.contains('value') || h.contains('amount'));
      
      int idxFrequency = header.indexWhere((h) => h.contains('frequency') || h.contains('period'));
      int idxSpendReq = header.indexWhere((h) => h.contains('spend') && h.contains('requirement'));
      if (idxSpendReq < 0) idxSpendReq = header.indexWhere((h) => h.contains('minimum') && h.contains('spend'));
      
      // v106 new columns
      int idxMatchLevel = header.indexWhere((h) => h.contains('match') && h.contains('level'));
      int idxMerchantL1 = header.indexWhere((h) => h.contains('credit') && h.contains('merchant') && h.contains('l1'));
      int idxMerchantL2 = header.indexWhere((h) => h.contains('credit') && h.contains('merchant') && h.contains('l2'));
      int idxMerchantL3 = header.indexWhere((h) => h.contains('credit') && h.contains('merchant') && h.contains('l3'));
      
      debugPrint('MasterSpreadsheetService: Credits tab columns - ProgramKey:$idxProgramKey Category:$idxCategory CreditValue:$idxCreditValue Frequency:$idxFrequency SpendReq:$idxSpendReq MatchLevel:$idxMatchLevel MerchL1:$idxMerchantL1 MerchL2:$idxMerchantL2 MerchL3:$idxMerchantL3');
      
      if (idxProgramKey < 0 || idxCategory < 0 || idxCreditValue < 0 || idxFrequency < 0) {
        debugPrint('MasterSpreadsheetService: Credits tab missing required columns');
        return creditsByProgramKey;
      }
      
      // Parse each credit row
      for (int r = 1; r < table.rows.length; r++) {
        final row = table.rows[r];
        if (row.isEmpty) continue;
        
        final programKey = (row[idxProgramKey]?.value?.toString() ?? '').trim();
        final category = (row[idxCategory]?.value?.toString() ?? '').trim();
        final creditValueStr = (row[idxCreditValue]?.value?.toString() ?? '').trim();
        final frequencyStr = (row[idxFrequency]?.value?.toString() ?? '').trim().toLowerCase();
        final spendReqStr = idxSpendReq >= 0 ? (row[idxSpendReq]?.value?.toString() ?? '').trim() : '';
        
        // v106 new fields
        final matchLevelStr = idxMatchLevel >= 0 ? (row[idxMatchLevel]?.value?.toString() ?? '').trim().toLowerCase() : '';
        final merchantL1 = idxMerchantL1 >= 0 ? (row[idxMerchantL1]?.value?.toString() ?? '').trim() : '';
        final merchantL2 = idxMerchantL2 >= 0 ? (row[idxMerchantL2]?.value?.toString() ?? '').trim() : '';
        final merchantL3 = idxMerchantL3 >= 0 ? (row[idxMerchantL3]?.value?.toString() ?? '').trim() : '';
        
        if (programKey.isEmpty || category.isEmpty || creditValueStr.isEmpty || frequencyStr.isEmpty) {
          continue;
        }
        
        // Parse credit value (allow dollar sign)
        final creditValue = double.tryParse(creditValueStr.replaceAll('\$', '').replaceAll(',', ''));
        if (creditValue == null || creditValue <= 0) continue;
        
        // Parse frequency
        CapPeriod frequency = CapPeriod.none;
        if (frequencyStr.contains('month')) {
          frequency = CapPeriod.monthly;
        } else if (frequencyStr.contains('quarter')) {
          frequency = CapPeriod.quarterly;
        } else if (frequencyStr.contains('annual') || frequencyStr.contains('year')) {
          frequency = CapPeriod.annual;
        }
        
        // Parse spend requirement (optional)
        double? spendRequirement;
        if (spendReqStr.isNotEmpty) {
          spendRequirement = double.tryParse(spendReqStr.replaceAll('\$', '').replaceAll(',', ''));
        }
        
        // Parse match level (v106)
        CreditMatchLevel matchLevel = CreditMatchLevel.none;
        if (matchLevelStr.contains('l1') || matchLevelStr == '1') {
          matchLevel = CreditMatchLevel.l1;
        } else if (matchLevelStr.contains('l2') || matchLevelStr == '2') {
          matchLevel = CreditMatchLevel.l2;
        } else if (matchLevelStr.contains('l3') || matchLevelStr == '3') {
          matchLevel = CreditMatchLevel.l3;
        }
        
        final credit = CardCredit(
          category: category,
          creditValue: creditValue,
          frequency: frequency,
          spendRequirement: spendRequirement,
          matchLevel: matchLevel,
          merchantL1: merchantL1.isEmpty ? null : merchantL1,
          merchantL2: merchantL2.isEmpty ? null : merchantL2,
          merchantL3: merchantL3.isEmpty ? null : merchantL3,
        );
        
        creditsByProgramKey.putIfAbsent(programKey, () => <CardCredit>[]).add(credit);
      }
      
      debugPrint('MasterSpreadsheetService: Loaded ${creditsByProgramKey.length} cards with credits');
      for (final entry in creditsByProgramKey.entries) {
        debugPrint('  ${entry.key}: ${entry.value.length} credits');
      }
      
    } catch (e) {
      debugPrint('MasterSpreadsheetService: Failed to load credits: $e');
    }
    
    return creditsByProgramKey;
  }

  /// Build cards from row matrix (spreadsheet_decoder fallback).
  /// This is used when the Excel decoder fails due to formatting issues.
  static List<CardModel>? _tryBuildCardsFromRowMatrix(Map<String, List<List<String>>> rowsBySheet) {
    try {
      debugPrint('MasterSpreadsheetService: Building cards from row matrix (spreadsheet_decoder fallback)');
      debugPrint('MasterSpreadsheetService: Available sheets: ${rowsBySheet.keys.toList()}');
      
      // Load credits first (from Credits tab)
      final creditsByProgramKey = _tryLoadCreditsFromRowMatrix(rowsBySheet);
      
      // Load signup bonuses (from Signup_Rewards_Review tab)
      final signupBonusesByProgramKey = _tryLoadSignupBonusesFromRowMatrix(rowsBySheet);
      
      // Find the Programs/Cards sheet - try multiple possible names
      MapEntry<String, List<List<String>>>? entry;
      
      // Try exact matches first
      for (final sheetName in ['Programs_Master', 'Programs', 'Cards_Master', 'Cards', 'Program_Master']) {
        if (rowsBySheet.containsKey(sheetName)) {
          entry = MapEntry(sheetName, rowsBySheet[sheetName]!);
          debugPrint('MasterSpreadsheetService: Found cards sheet by exact match: $sheetName');
          break;
        }
      }
      
      // Fallback to fuzzy search
      if (entry == null) {
        for (final e in rowsBySheet.entries) {
          final name = e.key.toLowerCase();
          if (name.contains('program') || name.contains('card')) {
            entry = e;
            debugPrint('MasterSpreadsheetService: Found cards sheet by fuzzy match: ${e.key}');
            break;
          }
        }
      }
      
      if (entry == null || entry.value.isEmpty) {
        debugPrint('MasterSpreadsheetService: ERROR - No Programs/Cards sheet found in row matrix!');
        debugPrint('MasterSpreadsheetService: Please ensure your v106 spreadsheet has a sheet named "Programs_Master" or similar');
        return null;
      }
      
      final rows = entry.value;
      final header = rows.first.map((v) => v.toLowerCase().trim()).toList();
      
      // Map headers
      int idxKey = header.indexWhere((h) => h.contains('program') || h == 'key' || h.contains('id'));
      int idxIssuer = header.indexWhere((h) => h.contains('issuer') || h.contains('bank'));
      int idxName = header.indexWhere((h) => h == 'name' || h.contains('product'));
      int idxBase = header.indexWhere((h) => h.contains('base'));
      int idxFee = header.indexWhere((h) => h.contains('annual') && h.contains('fee'));
      
      double pct(String v) {
        final s = v.replaceAll('%', '').trim();
        if (s.isEmpty) return 0.0;
        final d = double.tryParse(s) ?? 0.0;
        return (d > 1.0) ? (d / 100.0) : d;
      }
      
      // Category columns
      int cDining = header.indexWhere((h) => h.contains('dining') || h.contains('restaurant'));
      int cGroceries = header.indexWhere((h) => h.contains('grocery'));
      int cGas = header.indexWhere((h) => h.contains('gas') || h.contains('fuel'));
      int cFlights = header.indexWhere((h) => h.contains('flight') || h.contains('air'));
      int cHotels = header.indexWhere((h) => h.contains('hotel'));
      int cTransit = header.indexWhere((h) => h.contains('transit') || h.contains('rideshare') || h.contains('transport'));
      
      debugPrint('MasterSpreadsheetService: Card sheet columns - Key:$idxKey Issuer:$idxIssuer Name:$idxName Base:$idxBase Fee:$idxFee');
      
      final now = DateTime.now();
      final models = <CardModel>[];
      
      for (int r = 1; r < rows.length; r++) {
        final row = rows[r];
        if (row.isEmpty) continue;
        
        String key = (idxKey >= 0 && idxKey < row.length) ? row[idxKey].trim() : '';
        String issuer = (idxIssuer >= 0 && idxIssuer < row.length) ? row[idxIssuer].trim() : '';
        String name = (idxName >= 0 && idxName < row.length) ? row[idxName].trim() : '';
        double baseRate = pct(idxBase >= 0 && idxBase < row.length ? row[idxBase] : '');
        double fee = double.tryParse((idxFee >= 0 && idxFee < row.length ? row[idxFee] : '').replaceAll('\$', '').replaceAll(',', '')) ?? 0.0;
        
        if (issuer.isEmpty || name.isEmpty) continue;
        if (baseRate <= 0) baseRate = 0.01;
        
        final rules = <CategoryRule>[];
        void addRule(int idx, String cat) {
          if (idx >= 0 && idx < row.length) {
            final v = pct(row[idx]);
            if (v > 0) rules.add(CategoryRule(category: cat, multiplier: v));
          }
        }
        addRule(cDining, Level1Categories.dining);
        addRule(cGroceries, Level1Categories.groceries);
        addRule(cGas, Level1Categories.gas);
        
        void addTravelRule(int idx) {
          if (idx < 0 || idx >= row.length) return;
          final v = pct(row[idx]);
          if (v <= 0) return;
          final existingIdx = rules.indexWhere((r) => r.category == Level1Categories.travel);
          if (existingIdx < 0) {
            rules.add(CategoryRule(category: Level1Categories.travel, multiplier: v));
            return;
          }
          if (v > rules[existingIdx].multiplier) {
            rules[existingIdx] = CategoryRule(category: Level1Categories.travel, multiplier: v);
          }
        }
        addTravelRule(cFlights);
        addTravelRule(cHotels);
        addTravelRule(cTransit);
        
        // AMEX_GOLD_RESY special case
        if (key.toUpperCase().contains('AMEX_GOLD_RESY')) {
          final idx = rules.indexWhere((r) => r.category == Level1Categories.dining);
          if (idx >= 0) {
            if (rules[idx].multiplier < 0.04) {
              rules[idx] = CategoryRule(category: Level1Categories.dining, multiplier: 0.04);
            }
          } else {
            rules.add(const CategoryRule(category: Level1Categories.dining, multiplier: 0.04));
          }
        }
        
        final meta = CardOffer(
          id: key.isNotEmpty ? key : '${issuer.toLowerCase().replaceAll(' ', '_')}_${name.toLowerCase().replaceAll(' ', '_')}',
          issuer: issuer,
          name: name,
          categoryMultipliers: const {},
          baseCashback: baseRate,
          annualFee: fee,
          affiliateUrlCJ: null,
          affiliateUrlImpact: null,
          affiliateUrlRakuten: null,
          affiliateUrlPartnerize: null,
          createdAt: now,
          updatedAt: now,
        );
        
        // Attach credits and signup bonus for this card
        final cardCredits = creditsByProgramKey[key] ?? <CardCredit>[];
        final signupBonus = signupBonusesByProgramKey[key] ?? 0.0;
        
        models.add(CardModel(
          meta: meta,
          baseRate: baseRate,
          categoryRules: rules,
          credits: cardCredits,
          rotating: null,
          pointsToCash: 1.0,
          travelPortalMultiplier: 1.0,
          benefitValues: const {},
          signupBonus: signupBonus,
        ));
      }
      
      debugPrint('MasterSpreadsheetService: Built ${models.length} cards from row matrix');
      return models.isEmpty ? null : models;
    } catch (e) {
      debugPrint('MasterSpreadsheetService: build cards from row matrix failed: $e');
      return null;
    }
  }
  
  /// Load credits from row matrix (spreadsheet_decoder fallback).
  static Map<String, List<CardCredit>> _tryLoadCreditsFromRowMatrix(Map<String, List<List<String>>> rowsBySheet) {
    final creditsByProgramKey = <String, List<CardCredit>>{};
    
    try {
      // Find Credits sheet
      MapEntry<String, List<List<String>>>? creditsEntry;
      for (final entry in rowsBySheet.entries) {
        if (entry.key.toLowerCase().contains('credit')) {
          creditsEntry = entry;
          break;
        }
      }
      
      if (creditsEntry == null) {
        debugPrint('MasterSpreadsheetService: No Credits tab found in row matrix');
        return creditsByProgramKey;
      }
      
      final rows = creditsEntry.value;
      if (rows.isEmpty) return creditsByProgramKey;
      
      final header = rows.first.map((v) => v.toLowerCase().trim()).toList();
      
      // More flexible column detection to handle different naming conventions
      int idxProgramKey = -1;
      int idxCategory = -1;
      int idxCreditValue = -1;
      int idxFrequency = -1;
      int idxSpendReq = -1;
      int idxMatchLevel = -1;
      int idxAcceptedEstablishments = -1;
      int idxMerchantMatch = -1;
      int idxMerchantL1 = -1;
      int idxMerchantL2 = -1;
      int idxMerchantL3 = -1;
      
      for (int i = 0; i < header.length; i++) {
        final h = header[i];
        // Program Key - column 0
        if (idxProgramKey < 0 && (h.contains('program') || h == 'key' || h.contains('card'))) {
          idxProgramKey = i;
        }
        // Category - column 1
        if (idxCategory < 0 && h == 'category') {
          idxCategory = i;
        }
        // Credit Amount/Value - column 2 (Amount Per Period)
        if (idxCreditValue < 0 && (h.contains('amount') || (h.contains('credit') && h.contains('value')))) {
          if (!h.contains('spend') && !h.contains('requirement')) {
            idxCreditValue = i;
          }
        }
        // Frequency - column 3
        if (idxFrequency < 0 && (h.contains('frequency') || (h.contains('period') && !h.contains('amount')))) {
          idxFrequency = i;
        }
        // Spend requirement - column 4
        if (idxSpendReq < 0 && ((h.contains('spend') && h.contains('requirement')) || (h.contains('minimum') && h.contains('spend')))) {
          idxSpendReq = i;
        }
        // Match Level - column 5
        if (idxMatchLevel < 0 && h.contains('match') && h.contains('level')) {
          idxMatchLevel = i;
        }
        // Accepted Establishments - column 6
        if (idxAcceptedEstablishments < 0 && h.contains('accepted') && h.contains('establishment')) {
          idxAcceptedEstablishments = i;
        }
        // Merchant Match - column 7 (old single column - for backward compatibility)
        if (idxMerchantMatch < 0 && h.contains('merchant') && h.contains('match') && !h.contains('l1') && !h.contains('l2') && !h.contains('l3')) {
          idxMerchantMatch = i;
        }
        // Credit_Merchant_L1/L2/L3 - columns 8,9,10 (new v106 columns)
        if (idxMerchantL1 < 0 && h.contains('merchant') && (h.contains('_l1') || h.contains(' l1') || h.endsWith('l1'))) {
          idxMerchantL1 = i;
        }
        if (idxMerchantL2 < 0 && h.contains('merchant') && (h.contains('_l2') || h.contains(' l2') || h.endsWith('l2'))) {
          idxMerchantL2 = i;
        }
        if (idxMerchantL3 < 0 && h.contains('merchant') && (h.contains('_l3') || h.contains(' l3') || h.endsWith('l3'))) {
          idxMerchantL3 = i;
        }
      }
      
      debugPrint('MasterSpreadsheetService: Credits tab header: ${header.take(12).join(' | ')}');
      debugPrint('MasterSpreadsheetService: Credits (row matrix) columns:');
      debugPrint('  [0]ProgramKey:$idxProgramKey [1]Category:$idxCategory [2]CreditValue:$idxCreditValue');
      debugPrint('  [3]Frequency:$idxFrequency [4]SpendReq:$idxSpendReq [5]MatchLevel:$idxMatchLevel');
      debugPrint('  [6]AcceptedEst:$idxAcceptedEstablishments [7]MerchMatch:$idxMerchantMatch');
      debugPrint('  [8]MerchL1:$idxMerchantL1 [9]MerchL2:$idxMerchantL2 [10]MerchL3:$idxMerchantL3');
      
      if (idxProgramKey < 0 || idxCategory < 0 || idxCreditValue < 0 || idxFrequency < 0) {
        debugPrint('MasterSpreadsheetService: Credits tab (row matrix) missing required columns');
        return creditsByProgramKey;
      }
      
      for (int r = 1; r < rows.length; r++) {
        final row = rows[r];
        if (row.isEmpty) continue;
        
        final programKey = (idxProgramKey < row.length) ? row[idxProgramKey].trim() : '';
        final category = (idxCategory < row.length) ? row[idxCategory].trim() : '';
        final creditValueStr = (idxCreditValue < row.length) ? row[idxCreditValue].trim() : '';
        final frequencyStr = (idxFrequency < row.length) ? row[idxFrequency].trim().toLowerCase() : '';
        final spendReqStr = (idxSpendReq >= 0 && idxSpendReq < row.length) ? row[idxSpendReq].trim() : '';
        
        // v106 new fields for merchant matching
        final matchLevelStr = (idxMatchLevel >= 0 && idxMatchLevel < row.length) ? row[idxMatchLevel].trim().toLowerCase() : '';
        final acceptedEstablishments = (idxAcceptedEstablishments >= 0 && idxAcceptedEstablishments < row.length) ? row[idxAcceptedEstablishments].trim() : '';
        final merchantMatch = (idxMerchantMatch >= 0 && idxMerchantMatch < row.length) ? row[idxMerchantMatch].trim() : '';
        String merchantL1 = (idxMerchantL1 >= 0 && idxMerchantL1 < row.length) ? row[idxMerchantL1].trim() : '';
        String merchantL2 = (idxMerchantL2 >= 0 && idxMerchantL2 < row.length) ? row[idxMerchantL2].trim() : '';
        String merchantL3 = (idxMerchantL3 >= 0 && idxMerchantL3 < row.length) ? row[idxMerchantL3].trim() : '';
        
        if (programKey.isEmpty || category.isEmpty || creditValueStr.isEmpty || frequencyStr.isEmpty) {
          continue;
        }
        
        final creditValue = double.tryParse(creditValueStr.replaceAll('\$', '').replaceAll(',', ''));
        if (creditValue == null || creditValue <= 0) continue;
        
        CapPeriod frequency = CapPeriod.none;
        if (frequencyStr.contains('month')) {
          frequency = CapPeriod.monthly;
        } else if (frequencyStr.contains('quarter')) {
          frequency = CapPeriod.quarterly;
        } else if (frequencyStr.contains('annual') || frequencyStr.contains('year')) {
          frequency = CapPeriod.annual;
        }
        
        double? spendRequirement;
        if (spendReqStr.isNotEmpty) {
          spendRequirement = double.tryParse(spendReqStr.replaceAll('\$', '').replaceAll(',', ''));
        }
        
        // Parse Match Level and assign appropriate merchant string based on level
        CreditMatchLevel matchLevel = CreditMatchLevel.none;
        if (matchLevelStr.contains('l1') || matchLevelStr == '1') {
          matchLevel = CreditMatchLevel.l1;
          // If L1 column is empty but Accepted Establishments has value, use that
          if (merchantL1.isEmpty && acceptedEstablishments.isNotEmpty) merchantL1 = acceptedEstablishments;
        } else if (matchLevelStr.contains('l2') || matchLevelStr == '2') {
          matchLevel = CreditMatchLevel.l2;
          // If L2 column is empty but Merchant Match has value, use that
          if (merchantL2.isEmpty && merchantMatch.isNotEmpty) merchantL2 = merchantMatch;
        } else if (matchLevelStr.contains('l3') || matchLevelStr == '3') {
          matchLevel = CreditMatchLevel.l3;
          // If L3 column is empty but Merchant Match has value, use that
          if (merchantL3.isEmpty && merchantMatch.isNotEmpty) merchantL3 = merchantMatch;
        }
        
        final credit = CardCredit(
          category: category,
          creditValue: creditValue,
          frequency: frequency,
          spendRequirement: spendRequirement,
          matchLevel: matchLevel,
          merchantL1: merchantL1.isEmpty ? null : merchantL1,
          merchantL2: merchantL2.isEmpty ? null : merchantL2,
          merchantL3: merchantL3.isEmpty ? null : merchantL3,
        );
        
        creditsByProgramKey.putIfAbsent(programKey, () => <CardCredit>[]).add(credit);
      }
      
      debugPrint('MasterSpreadsheetService: Loaded ${creditsByProgramKey.length} cards with credits (row matrix)');
      for (final entry in creditsByProgramKey.entries) {
        debugPrint('  ${entry.key}: ${entry.value.length} credits');
      }
      
    } catch (e) {
      debugPrint('MasterSpreadsheetService: Failed to load credits from row matrix: $e');
    }
    
    return creditsByProgramKey;
  }
  
  /// Load signup bonuses from row matrix (Signup_Rewards_Review tab).
  static Map<String, double> _tryLoadSignupBonusesFromRowMatrix(Map<String, List<List<String>>> rowsBySheet) {
    final signupBonusesByProgramKey = <String, double>{};
    
    try {
      // Find Signup_Rewards_Review sheet
      MapEntry<String, List<List<String>>>? signupEntry;
      for (final entry in rowsBySheet.entries) {
        final name = entry.key.toLowerCase();
        if (name.contains('signup') || name.contains('reward')) {
          signupEntry = entry;
          break;
        }
      }
      
      if (signupEntry == null) {
        debugPrint('MasterSpreadsheetService: No Signup_Rewards_Review tab found in row matrix');
        return signupBonusesByProgramKey;
      }
      
      final rows = signupEntry.value;
      if (rows.isEmpty) return signupBonusesByProgramKey;
      
      final header = rows.first.map((v) => v.toLowerCase().trim()).toList();
      
      int idxProgramKey = -1;
      int idxBonusValue = -1;
      
      for (int i = 0; i < header.length; i++) {
        final h = header[i];
        if (idxProgramKey < 0 && (h.contains('program') || h == 'key' || h.contains('card'))) {
          idxProgramKey = i;
        }
        if (idxBonusValue < 0 && (h.contains('bonus') || h.contains('value') || h.contains('reward'))) {
          if (!h.contains('requirement')) {
            idxBonusValue = i;
          }
        }
      }
      
      debugPrint('MasterSpreadsheetService: Signup_Rewards_Review columns - ProgramKey:$idxProgramKey BonusValue:$idxBonusValue');
      
      if (idxProgramKey < 0 || idxBonusValue < 0) {
        debugPrint('MasterSpreadsheetService: Signup_Rewards_Review tab missing required columns');
        return signupBonusesByProgramKey;
      }
      
      for (int r = 1; r < rows.length; r++) {
        final row = rows[r];
        if (row.isEmpty) continue;
        
        final programKey = (idxProgramKey < row.length) ? row[idxProgramKey].trim() : '';
        final bonusValueStr = (idxBonusValue < row.length) ? row[idxBonusValue].trim() : '';
        
        if (programKey.isEmpty || bonusValueStr.isEmpty) continue;
        
        final bonusValue = double.tryParse(bonusValueStr.replaceAll('\$', '').replaceAll(',', ''));
        if (bonusValue == null || bonusValue <= 0) continue;
        
        signupBonusesByProgramKey[programKey] = bonusValue;
      }
      
      debugPrint('MasterSpreadsheetService: Loaded ${signupBonusesByProgramKey.length} signup bonuses (row matrix)');
      for (final entry in signupBonusesByProgramKey.entries) {
        debugPrint('  ${entry.key}: \$${entry.value.toStringAsFixed(0)}');
      }
      
    } catch (e) {
      debugPrint('MasterSpreadsheetService: Failed to load signup bonuses from row matrix: $e');
    }
    
    return signupBonusesByProgramKey;
  }

  // NOTE: intentionally no fallback merchant seeds.
}

class MerchantMasterRow {
  final String cleanMerchant;
  final String? level1;
  final String? level2;
  final int? rowIndex;

  const MerchantMasterRow({required this.cleanMerchant, this.level1, this.level2, this.rowIndex});

  Map<String, Object?> toJson() => {'cleanMerchant': cleanMerchant, 'level1': level1, 'level2': level2, 'rowIndex': rowIndex};
}

class MerchantMasterMatch {
  final String key;
  final MerchantMasterRow row;
  final MerchantCleanMethod method;
  final int tier;
  final double score;
  const MerchantMasterMatch({required this.key, required this.row, required this.method, required this.tier, required this.score});
}

enum MerchantCleanMethod {
  notLoaded,
  exactMatch,
  fullPhraseContains,
  partialPhraseWords,
  fullKeyword,
  charInOrder,
  noMatch,
}

class MerchantCleanCandidate {
  final String key;
  final double score;
  final Map<String, Object?> notes;
  const MerchantCleanCandidate({required this.key, required this.score, this.notes = const {}});
}

class MerchantCleanExplain {
  final String rawDescription;
  final String? cleanedMerchant;
  final MerchantCleanMethod method;
  final String? matchedKey;
  final Map<String, Object?> details;
  final List<MerchantCleanCandidate> topCandidates;

  const MerchantCleanExplain({
    required this.rawDescription,
    required this.cleanedMerchant,
    required this.method,
    required this.matchedKey,
    required this.details,
    required this.topCandidates,
  });
}

// ---- Matching helpers (normalization + fuzzy) ----
class _MSMatch {
  static const Set<String> _stopTokens = {
    // Corporate/legal suffixes and generic filler tokens that should not drive matching.
    'inc',
    'incorporated',
    'llc',
    'ltd',
    'limited',
    'corp',
    'corporation',
    'co',
    'company',
    'plc',
    'the',
    'and',
  };

  static bool _isStopToken(String w) {
    final t = w.trim().toLowerCase();
    if (t.isEmpty) return true;
    // Treat pure numbers as non-informative for matching.
    if (RegExp(r'^\d+$').hasMatch(t)) return true;
    return _stopTokens.contains(t);
  }

  static String normalizeForMatching(String s) {
    // User rules:
    // - Case-insensitive
    // - Replace hyphens and slashes with spaces
    // - Remove extra spaces
    String n = s.replaceAll('*', ' ');
    // Normalize dash variants to '-' first, then convert '-' and '/' into spaces.
    n = n
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll('‑', '-')
        .replaceAll('-', ' ')
        .replaceAll('/', ' ');
    n = n.replaceAll(RegExp(r'[^a-zA-Z0-9\s]+'), ' ');
    n = n.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

    // Improve tokenization when statements concatenate things like:
    // "TACOBELL030836" -> "tacobell 030836"
    // "030836TACOBELL" -> "030836 tacobell"
    n = n.replaceAllMapped(RegExp(r'([a-z])([0-9])'), (m) => '${m[1]} ${m[2]}');
    n = n.replaceAllMapped(RegExp(r'([0-9])([a-z])'), (m) => '${m[1]} ${m[2]}');
    n = n.replaceAll(RegExp(r'\s+'), ' ').trim();
    return n;
  }

  /// Remove all non-alphanumeric characters for dash/space agnostic comparisons.
  static String alnumOnly(String s) => s.replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// Returns the length of the longest contiguous substring of `needle` (case: already lowered)
  /// that appears within `haystack`. Only considers substrings of length >= minLen.
  static int longestContainedSubstrLen({required String haystack, required String needle, int minLen = 3}) {
    if (haystack.isEmpty || needle.isEmpty) return 0;
    final h = haystack;
    final n = needle;
    final N = n.length;
    int best = 0;
    for (int L = (N < 12 ? N : 12); L >= minLen; L--) { // cap window for speed on long keys
      for (int i = 0; i + L <= N; i++) {
        final sub = n.substring(i, i + L);
        if (h.contains(sub)) {
          if (L > best) best = L;
          // Early exit if we found a perfect window size for this L (keep searching shorter L only if needed)
        }
      }
      if (best >= L) return best; // found at least one of length L; can't do better in this loop
    }
    return best;
  }

  static void indexKeyTokens(String key) {
    // IMPORTANT: Token index must be built off the *normalized* key, not the raw
    // spreadsheet string.
    //
    // Otherwise punctuation variants won't share tokens and can get accidentally
    // excluded by the candidate pre-filtering.
    // Example:
    //   key: "Domino's" -> raw tokens {"domino"}
    //   desc: "DOMINOS" -> desc tokens {"dominos"}
    // Candidate set becomes non-empty via other tokens (e.g., "pizza"), and
    // we'd never even consider the Domino's key. Normalizing fixes this.
    final keyNorm = normalizeForMatching(key);
    final tokens = descTokensForIndexing(keyNorm);
    for (final t in tokens) {
      MasterSpreadsheetService._tokenToKeys.putIfAbsent(t, () => <String>{}).add(key);
    }
  }

  static Set<String> descTokensForIndexing(String descNorm) {
    // Prefer word tokens (3+). If the description contains a long concatenated word,
    // also index that whole word so we can avoid scanning the entire catalog.
    final tokens = <String>{};
    for (final t in descNorm.split(RegExp(r'[^a-z0-9]+'))) {
      final tt = t.trim();
      if (tt.length < 3) continue;
      tokens.add(tt);

      // Extra resilience for plural/singular and possessive variants.
      // Example: "domino's" -> "domino"; statement may contain "dominos".
      // We add the singular form as an additional token so prefiltering doesn't
      // accidentally exclude the correct key.
      if (tt.length >= 4 && tt.endsWith('s')) {
        tokens.add(tt.substring(0, tt.length - 1));
      }
    }
    // Add long alpha-runs as extra tokens.
    for (final m in RegExp(r'[a-z]{4,}').allMatches(alnumOnly(descNorm))) {
      final run = m.group(0);
      if (run != null && run.length >= 4) tokens.add(run);
    }
    return tokens;
  }

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final m = a.length;
    final n = b.length;
    final dp = List<int>.generate(n + 1, (j) => j);
    for (int i = 1; i <= m; i++) {
      int prev = dp[0];
      dp[0] = i;
      for (int j = 1; j <= n; j++) {
        final temp = dp[j];
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        final del = dp[j] + 1;
        final ins = dp[j - 1] + 1;
        final sub = prev + cost;
        int best = del < ins ? del : ins;
        if (sub < best) best = sub;
        dp[j] = best;
        prev = temp;
      }
    }
    return dp[n];
  }

  static double _similarity(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    final dist = _levenshtein(a, b);
    final denom = a.length > b.length ? a.length : b.length;
    return 1.0 - (dist / denom);
  }

  // ignore: unused_element
  static String? fuzzyCleanMerchant(String rawDescription, {double threshold = 0.78}) {
    if (MasterSpreadsheetService._merchantMap.isEmpty) return null;
    final dNorm = normalizeForMatching(rawDescription);
    if (dNorm.isEmpty) return null;

    // Candidate selection via token index
    final tokens = dNorm
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.isNotEmpty && t.length >= 3)
        .toSet();
    final candidates = <String>{};
    for (final t in tokens) {
      final ks = MasterSpreadsheetService._tokenToKeys[t];
      if (ks != null) candidates.addAll(ks);
    }
    if (candidates.isEmpty) candidates.addAll(MasterSpreadsheetService._merchantMap.keys);

    // Build n-grams of the description (up to 4 tokens) for locality-aware similarity
    final descTokens = dNorm.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final grams = <String>[];
    final maxLen = 4;
    for (int n = 1; n <= maxLen; n++) {
      for (int i = 0; i + n <= descTokens.length; i++) {
        grams.add(descTokens.sublist(i, i + n).join(' '));
      }
    }

    double bestScore = 0.0;
    int bestMatchLen = 0; // tie-breaker: character count of the winning gram
    String? bestKey;
    // Iterate in insertion order of the spreadsheet-loaded map; filter by candidates set when available.
    final orderedKeys = MasterSpreadsheetService._merchantMap.keys;
    for (final key in orderedKeys) {
      if (candidates.isNotEmpty && !candidates.contains(key)) continue;
      final k = key.trim();
      if (k.isEmpty) continue;
      double localBest = 0.0;
      int localBestLen = 0;
      for (final g in grams) {
        final s = _similarity(k, g);
        if (s > localBest || (s == localBest && g.length > localBestLen)) {
          localBest = s;
          localBestLen = g.length;
        }
        if (localBest >= 0.995) break; // early exit on near-exact match
      }
      if (localBest > bestScore || (localBest == bestScore && localBestLen > bestMatchLen)) {
        bestScore = localBest;
        bestMatchLen = localBestLen;
        bestKey = k;
      }
    }

    if (bestKey != null && bestScore >= threshold) {
      return MasterSpreadsheetService._merchantMap[bestKey]?.cleanMerchant;
    }
    return null;
  }

  static bool _partialWordMatch(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    // Avoid noisy matches on 1-2 letter tokens.
    // If either token is shorter than 3, only allow exact equality.
    if (a.length < 3 || b.length < 3) return a == b;
    if (a == b) return true;
    return a.contains(b) || b.contains(a);
  }

  static bool _containsKeywordSpecial(String descNorm, String keywordNorm) {
    if (descNorm.isEmpty || keywordNorm.isEmpty) return false;
    // Special-case: avoid matching "air" when embedded inside a larger token
    // (e.g. "kauairooftoptent"), but still allow airline-ish prefixes like
    // " aircanada" or "Air Canada".
    // Rule: "air" must be at start OR preceded by a non-alphanumeric.
    if (keywordNorm == 'air') {
      return RegExp(r'(^|[^a-z0-9])air').hasMatch(descNorm);
    }

    // IMPORTANT: Prevent noisy false positives on very short keywords.
    // Example: keyword "ups" should not match "upslope".
    // Rule: for 1-3 character keywords, require whole-word / boundary match.
    if (keywordNorm.length <= 3) {
      return RegExp('(^|[^a-z0-9])${RegExp.escape(keywordNorm)}([^a-z0-9]|\$)').hasMatch(descNorm);
    }
    return descNorm.contains(keywordNorm);
  }

  /// Single-word keyword matching that avoids embedded-substring false positives.
  ///
  /// Examples:
  /// - Matches: "tacobell 030836", "tacobell030836" (after normalization), "tacobell."
  /// - Does NOT match: "pineapple" for keyword "apple" (embedded)
  ///
  /// Rule:
  /// - Must have a non-alphanumeric (or start) before the keyword
  /// - After keyword: allow end, non-alphanumeric, OR digits (common for statement suffixes)
  static bool _containsStandaloneSingleWord(String descNorm, String keywordNorm) {
    if (descNorm.isEmpty || keywordNorm.isEmpty) return false;
    if (keywordNorm.length <= 3) return _containsKeywordSpecial(descNorm, keywordNorm);
    return RegExp('(^|[^a-z0-9])${RegExp.escape(keywordNorm)}([0-9]|[^a-z0-9]|\$)').hasMatch(descNorm);
  }

  static _MatchScore scoreKeyAgainst({
    required String descNorm,
    required List<String> descWords,
    required String descAlnum,
    required String keyRaw,
    required String keyNorm,
    required List<String> keyWords,
    required String keyAlnum,
  }) {
    // Filter out generic/non-informative tokens so they can't create false positives
    // (e.g. matching on "inc" and bubbling up unrelated candidates).
    final kw = keyWords.where((w) => !_isStopToken(w)).toList(growable: false);
    final dw = descWords.where((w) => !_isStopToken(w)).toList(growable: false);

    // If a key becomes a single token after filtering (e.g. "Something Inc" -> "something"),
    // treat it as a single-word key for tiering.
    final isPhrase = kw.length >= 2;
    final phraseContains = keyNorm.isNotEmpty && _containsKeywordSpecial(descNorm, keyNorm);
    final phraseContainsAlnum = keyAlnum.isNotEmpty && descAlnum.contains(keyAlnum) && keyAlnum.length >= 4;
    final exactMatch = keyNorm.isNotEmpty && (descNorm == keyNorm || descAlnum == keyAlnum);

    // If we filtered a phrase down to a single informative token (e.g. "Airways Inc" -> "airways"),
    // use that token for single-word contains checks so statements that omit suffixes still match.
    final effectiveSingleToken = (!isPhrase && kw.length == 1) ? kw.first : keyNorm;
    final effectiveSingleTokenAlnum = (!isPhrase && kw.length == 1) ? alnumOnly(kw.first) : keyAlnum;

    // IMPORTANT: for single-word keys we still want substring-style matching (e.g.
    // "TACOBELL030836"), but we must avoid embedded matches (e.g. "apple" in
    // "pineapple"). So we use a boundary-aware contains for single tokens.
    final singleWordContains = !isPhrase && effectiveSingleToken.isNotEmpty && _containsStandaloneSingleWord(descNorm, effectiveSingleToken);

    int exactWordMatches = 0;
    int partialWordMatches = 0;
    final matchedKeyWords = <String>[];
    for (final w in kw) {
      if (w.isEmpty) continue;
      bool matched = false;

      // Special-case keyword handling: "air" should only match with a boundary
      // in front of it.
      if (w == 'air') {
        if (_containsKeywordSpecial(descNorm, 'air')) {
          partialWordMatches++;
          matched = true;
        }
      }

      for (final t in dw) {
        if (t == w) {
          exactWordMatches++;
          matched = true;
          break;
        }
      }

      // Extra support for concatenated statement strings: treat a word as matched
      // if its alnum-only form occurs inside the full description alnum.
      // NOTE: do NOT allow this for short (<=3) tokens, because that creates
      // lots of false positives (e.g. "ups" inside "upslope").
      if (!matched && w.length >= 4 && w != 'air') {
        final wa = alnumOnly(w);
        if (wa.isNotEmpty && descAlnum.contains(wa)) {
          // Count this as a partial match (we don't want it to outrank true token matches).
          partialWordMatches++;
          matched = true;
        }
      }

      if (!matched && w != 'air') {
        for (final t in dw) {
          // For 1-3 char keywords, only allow exact word equality (handled above).
          if (w.length <= 3) continue;
          if (_partialWordMatch(w, t)) {
            partialWordMatches++;
            matched = true;
            break;
          }
        }
      }
      if (matched) matchedKeyWords.add(w);
    }

    final totalMatched = exactWordMatches + partialWordMatches;
    final coverage = kw.isEmpty ? 0.0 : (totalMatched / kw.length);

    // Char-in-order: longest contiguous substring of key's alnum contained in description alnum.
    final charInOrderLen = (effectiveSingleTokenAlnum.length < 3 || descAlnum.isEmpty)
        ? 0
        : longestContainedSubstrLen(haystack: descAlnum, needle: effectiveSingleTokenAlnum, minLen: 3);
    // Intentionally do NOT use fuzzy edit-distance similarity for ranking.
    // Per user rules, character-level scoring should only be a last-resort
    // "characters in order" check.

    // Priority tiers per user:
    // 0) Exact match (normalized string or alnum-only equality)
    // 1) Full merchant phrase match (full key phrase contained OR phrase alnum contained)
    // 2) Keyword match (single word; exact or partial) — outranks partial phrase matches
    // 3) Partial merchant phrase match (1-2+ words match, partial-word allowed)
    // 4) Characters in order (lowest)
    int tier;
    MerchantCleanMethod method;
    if (exactMatch) {
      tier = 0;
      method = MerchantCleanMethod.exactMatch;
    } else if (isPhrase && (phraseContains || phraseContainsAlnum)) {
      tier = 1;
      method = MerchantCleanMethod.fullPhraseContains;
    } else if (!isPhrase && singleWordContains) {
      // Bring back the original expectation: exact merchant keywords like
      // "TACOBELL" should match "TACOBELL030836" even if tokenization fails.
      // Boundary rules prevent embedded false positives.
      tier = 1;
      method = MerchantCleanMethod.fullPhraseContains;
    } else if (!isPhrase && kw.isNotEmpty && exactWordMatches > 0) {
      tier = 2;
      method = MerchantCleanMethod.fullKeyword;
    } else if (!isPhrase && kw.isNotEmpty && partialWordMatches > 0) {
      tier = 2;
      method = MerchantCleanMethod.fullKeyword;
    } else if (isPhrase && totalMatched > 0) {
      tier = 3;
      method = MerchantCleanMethod.partialPhraseWords;
    } else if (charInOrderLen >= 3) {
      tier = 4;
      method = MerchantCleanMethod.charInOrder;
    } else {
      tier = 9;
      method = MerchantCleanMethod.noMatch;
    }

    // Rank score (higher is better). Tier dominates.
    // Keep the number readable-ish for UI by staying in a ~0-1000 range.
    // Tier dominates. Lower tier number = higher priority.
    final tierWeight = (10 - tier) * 200.0;
    final wordScore = (exactWordMatches * 20.0) + (partialWordMatches * 12.0) + (coverage * 40.0);
    final charScore = charInOrderLen.toDouble();
    final lenBonus = keyNorm.length.clamp(0, 40) * 0.25;
    final rank = tierWeight + wordScore + charScore + lenBonus;

    return _MatchScore(
      keyRaw: keyRaw,
      tier: tier,
      rankScore: rank,
      method: method,
      phraseContains: phraseContains,
      exactWordMatches: exactWordMatches,
      partialWordMatches: partialWordMatches,
      matchedKeyWords: matchedKeyWords,
      coverage: coverage,
      charInOrderLen: charInOrderLen,
      similarity: 0.0,
      keyNorm: keyNorm,
      exactMatch: exactMatch,
    );
  }
}

// === Matching shared helpers (two-pass: candidates then fallback-to-all) ===
_MatchScore? _bestMatchForKeys({
  required String descNorm,
  required List<String> descWords,
  required String descAlnum,
  required Iterable<String> scanKeys,
  required Map<String, String> normKeyCache,
  required Map<String, String> alnumKeyCache,
  required Map<String, List<String>> keyWordsCache,
}) {
  _MatchScore? best;
  for (final key in scanKeys) {
    if (key.isEmpty) continue;
    final score = _MSMatch.scoreKeyAgainst(
      descNorm: descNorm,
      descWords: descWords,
      descAlnum: descAlnum,
      keyRaw: key,
      keyNorm: normKeyCache[key] ?? _MSMatch.normalizeForMatching(key),
      keyWords: keyWordsCache[key] ?? (_MSMatch.normalizeForMatching(key).split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList(growable: false)),
      keyAlnum: alnumKeyCache[key] ?? _MSMatch.alnumOnly(key),
    );
    if (best == null) {
      best = score;
      continue;
    }
    final cmp = score.compareTo(best);
    if (cmp > 0) {
      best = score;
    } else if (cmp == 0) {
      // Tie-break ONLY within the best-match bucket: alphabetical by key.
      if (score.tier == best.tier && (score.rankScore - best.rankScore).abs() < 0.0001) {
        final a = score.keyRaw.toLowerCase();
        final b = best.keyRaw.toLowerCase();
        if (a.compareTo(b) < 0) best = score;
      }
    }
  }
  return best;
}

class _MatchScore implements Comparable<_MatchScore> {
  final String keyRaw;
  final int tier;
  final double rankScore;
  final MerchantCleanMethod method;
  final bool phraseContains;
  final int exactWordMatches;
  final int partialWordMatches;
  final List<String> matchedKeyWords;
  final double coverage;
  final int charInOrderLen;
  final double similarity;
  final String keyNorm;
  final bool exactMatch;

  const _MatchScore({
    required this.keyRaw,
    required this.tier,
    required this.rankScore,
    required this.method,
    required this.phraseContains,
    required this.exactWordMatches,
    required this.partialWordMatches,
    required this.matchedKeyWords,
    required this.coverage,
    required this.charInOrderLen,
    required this.similarity,
    required this.keyNorm,
    required this.exactMatch,
  });

  bool get isStrong {
    // Strong-enough gate to avoid random fuzzy picks:
    // - Exact/phrase matches are accepted.
    // - Otherwise require at least 1 word match OR meaningful char-in-order length.
    if (tier == 0) return true;
    if (tier == 1) return true;
    if (tier == 2) return (exactWordMatches + partialWordMatches) >= 1;
    if (tier == 3) return (exactWordMatches + partialWordMatches) >= 1;
    if (tier == 4) return charInOrderLen >= 5;
    return false;
  }

  MerchantCleanMethod get explainMethod => method;

  Map<String, Object?> get explain => {
        'key_norm': keyNorm,
        'exact_match': exactMatch,
        'phrase_contains': phraseContains,
        'word_exact': exactWordMatches,
        'word_partial': partialWordMatches,
        'word_coverage': Formatters.fixed(coverage, decimals: 2),
        'matched_key_words': matchedKeyWords,
        'char_in_order_len': charInOrderLen,
        'rank': Formatters.fixed(rankScore, decimals: 1),
      };

  Map<String, Object?> get explainCandidate => {
        'tier': tier,
        'method': method.name,
        'exact_match': exactMatch,
        'word_exact': exactWordMatches,
        'word_partial': partialWordMatches,
        'coverage': Formatters.fixed(coverage, decimals: 2),
        'char_in_order_len': charInOrderLen,
        'rank': Formatters.fixed(rankScore, decimals: 1),
      };

  @override
  int compareTo(_MatchScore other) {
    final byRank = rankScore.compareTo(other.rankScore);
    if (byRank != 0) return byRank;
    // Prefer higher-tier (lower number) on tie, then longer key.
    final byTier = other.tier.compareTo(tier);
    if (byTier != 0) return byTier;
    return keyNorm.length.compareTo(other.keyNorm.length);
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final it = iterator;
    if (!it.moveNext()) return null;
    return it.current;
  }
}
