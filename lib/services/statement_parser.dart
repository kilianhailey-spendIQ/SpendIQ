import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:spendiq/utils/formatters.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:spendiq/models/transaction.dart';
import 'package:spendiq/core/categories.dart';
import 'package:spendiq/services/category_mapping.dart';
import 'package:spendiq/services/spend_categorizer.dart';
// Web OCR fallback (uses JS via ocr_service_web.dart). Safe to import on all platforms.
import 'package:spendiq/services/ocr_service_web.dart' as ocr;
import 'package:spendiq/services/ocr_service_native.dart' as native_ocr;
import 'package:spendiq/services/master_spreadsheet_service.dart';

/// Row representing a parsed transaction without categorization.
/// Only the required fields for preview/CSV.
class SimpleTransactionRow {
  final DateTime date;
  final String merchant;
  final double amount; // keep sign as found in statement
  final String sourceLine; // original line for reference

  const SimpleTransactionRow({required this.date, required this.merchant, required this.amount, required this.sourceLine});
}

/// Result object for simple parsing mode requested by the user.
class SimpleParseResult {
  final String rawText;
  final List<SimpleTransactionRow> rows;
  final List<String> unparsedLines; // lines that looked like body but couldn't be parsed

  const SimpleParseResult({required this.rawText, required this.rows, required this.unparsedLines});
}

/// Parses credit card statements from PDFs and infers merchant categories.
class _SimpleRows {
  final List<SimpleTransactionRow> rows;
  final List<String> unparsedLines;
  final String trimmedText; // raw text truncated to only the repeating transaction block
  const _SimpleRows({required this.rows, required this.unparsedLines, required this.trimmedText});
}

class StatementParserService {
  /// Web-only: prefer using the JS-based PDF.js + (optional) Tesseract “smart”
  /// extractor for the initial text-layer extraction.
  ///
  /// Why:
  /// - The Dart PDF text extractor is synchronous on web and can trigger the
  ///   browser “Page is unresponsive” dialog on some statements.
  /// - The JS pipeline is async and reports progress without blocking the UI.
  ///
  /// This does **not** change any downstream matching/sorting/categorization
  /// logic: it only changes how we obtain the raw text string.
  static bool preferWebSmartExtract = true;

  /// User request (critical): do not persist PDF parse cache.
  ///
  /// When false, the simple PDF cache is neither read nor written.
  static const bool enableSimplePdfCache = false;
  // Users can upload up to 1 year + 1 month of history.
  // We also use this as an outlier guardrail: if one transaction lands far
  // outside the majority cluster (e.g., a bogus 2019 parse), we drop it.
  static const int _majorityWindowMonths = 13;
  static const _knownCategories = <String>{
    'groceries','dining','travel','gas','transit','entertainment','shopping','online','utilities','phone','internet','pharmacy','health','fitness','education','home','rent','insurance','subscriptions','services','fees','taxes','electronics','coffee','alcohol','pets','charity','other','uncategorized'
  };

  /// Keyword-based rules for category inference. Lowercased contains() checks.
  static const Map<String, String> _keywordToCategory = {
    // Groceries
    'whole foods': 'groceries', 'trader joe': 'groceries', 'kroger': 'groceries', 'safeway': 'groceries', 'aldi': 'groceries', 'walmart supercenter': 'groceries', 'costco': 'groceries',
    // Dining
    'mcdonald': 'dining', 'starbucks': 'dining', 'chipotle': 'dining', 'taco bell': 'dining', 'kfc': 'dining', 'burger king': 'dining', 'domino': 'dining', 'ubereats': 'dining', 'doordash': 'dining', 'grubhub': 'dining', 'coffee': 'dining',
    'panda express': 'dining',
    // Travel
    'delta': 'travel', 'united': 'travel', 'american airlines': 'travel', 'southwest': 'travel', 'airbnb': 'travel', 'marriott': 'travel', 'hilton': 'travel', 'lyft': 'travel', 'uber trip': 'travel', 'booking.com': 'travel',
    // Gas/Transit
    'shell': 'gas', 'chevron': 'gas', 'bp ': 'gas', 'exxon': 'gas', '7-eleven fuel': 'gas', 'metro': 'transit', 'mta': 'transit', 'clipper': 'transit', 'bart': 'transit',
    // Entertainment
    'netflix': 'entertainment', 'spotify': 'entertainment', 'hulu': 'entertainment', 'disney+': 'entertainment', 'amc': 'entertainment', 'regal': 'entertainment', 'steam': 'entertainment', 'playstation': 'entertainment', 'xbox': 'entertainment',
    // Online/Shopping
    'amazon': 'online', 'etsy': 'online', 'ebay': 'online', 'best buy': 'electronics', 'apple.com': 'electronics', 'microsoft': 'electronics', 'target': 'shopping',
    // Utilities & bills
    'comcast': 'internet', 'xfinity': 'internet', 'verizon': 'phone', 'att ': 'phone', 't-mobile': 'phone', 'pg&e': 'utilities', 'duke energy': 'utilities', 'spectrum': 'internet',
    // Health
    'cvs': 'pharmacy', 'walgreens': 'pharmacy', 'rite aid': 'pharmacy', 'planet fitness': 'fitness', '24 hour fitness': 'fitness',
    // Subscriptions/Services
    'subscri': 'subscriptions', 'patreon': 'subscriptions', 'onlyfans': 'subscriptions', 'dropbox': 'services', 'notion': 'services', 'slack': 'services', 'zoom': 'services',
    // Fees/Taxes
    'annual fee': 'fees', 'late fee': 'fees', 'interest': 'fees', 'tax': 'taxes',
  };

  /// Returns true if the text likely refers to interest.
  ///
  /// We intentionally tolerate OCR weirdness like "Inter est" / extra whitespace
  /// or punctuation between letters.
  static bool isInterestText(String text) {
    // OCR can confuse i/l/1/|/! which breaks naive contains('interest').
    // We therefore normalize to a letters-only form and also run a tolerant
    // regex matcher.
    final lower = text.toLowerCase();
    if (lower.contains('interest')) return true;

    String normalizeLettersOnly(String s) {
      // Map common OCR confusables that frequently break naive keyword checks.
      // Goal: if a human reads it as "interest", we should treat it as interest.
      final mapped = s
          // i
          .replaceAll('1', 'i')
          .replaceAll('|', 'i')
          .replaceAll('!', 'i')
          .replaceAll('ℹ', 'i')
          .replaceAll('l', 'i')
          // s
          .replaceAll('5', 's')
          // o
          .replaceAll('0', 'o')
          // a
          .replaceAll('@', 'a')
          // z
          .replaceAll('2', 'z')
          // b
          .replaceAll('8', 'b')
          // g
          .replaceAll('6', 'g')
          .replaceAll('9', 'g');
      // Keep only letters so punctuation/whitespace doesn't matter.
      return mapped.replaceAll(RegExp(r'[^a-z]'), '');
    }

    final normalized = normalizeLettersOnly(lower);
    if (normalized.contains('interest')) return true;

    // Robust fallback: match i n t e r e s t with optional non-letters between.
    // Also allow OCR 'l'/'1' in the first letter position.
    return RegExp(r'[il1][^a-z]*n[^a-z]*t[^a-z]*e[^a-z]*r[^a-z]*e[^a-z]*s[^a-z]*t', caseSensitive: false).hasMatch(lower);
  }

  /// Debug helper to explain *why* [isInterestText] returned true/false.
  ///
  /// This is used in the in-app troubleshooting sheet so we can verify OCR/
  /// formatting quirks (e.g. "Inter est" or "1nterest").
  static Map<String, dynamic> explainInterestText(String text) {
    final lower = text.toLowerCase();
    final directContains = lower.contains('interest');

    String normalizeLettersOnly(String s) {
      final mapped = s
          .replaceAll('1', 'i')
          .replaceAll('|', 'i')
          .replaceAll('!', 'i')
          .replaceAll('ℹ', 'i')
          .replaceAll('l', 'i')
          .replaceAll('5', 's')
          .replaceAll('0', 'o')
          .replaceAll('@', 'a')
          .replaceAll('2', 'z')
          .replaceAll('8', 'b')
          .replaceAll('6', 'g')
          .replaceAll('9', 'g');
      return mapped.replaceAll(RegExp(r'[^a-z]'), '');
    }

    final normalized = normalizeLettersOnly(lower);
    final normalizedContains = normalized.contains('interest');
    final regex = RegExp(r'[il1][^a-z]*n[^a-z]*t[^a-z]*e[^a-z]*r[^a-z]*e[^a-z]*s[^a-z]*t', caseSensitive: false);
    final regexMatch = regex.hasMatch(lower);

    return {
      'input': text,
      'lower': lower,
      'direct_contains_interest': directContains,
      'normalized_letters_only': normalized,
      'normalized_contains_interest': normalizedContains,
      'regex': regex.pattern,
      'regex_match': regexMatch,
      'final_is_interest': directContains || normalizedContains || regexMatch,
    };
  }

  /// Applies all non-negotiable ingest rules:
  /// 1) Exclude phrase override (post-categorization; short-circuits other overrides)
  /// 2) ToastTab (TST*) dining override (post-categorization)
  /// 3) Interest override must always win (post-categorization)
  /// 3) Drop date outliers using the 13-month majority-window logic
  static List<SpendTransaction> sanitizeTransactions(
    List<SpendTransaction> items, {
    required String label,
  }) {
    // Important: Interest override must run last so it can never be overwritten.
    // Exclude override short-circuits everything else.
    final overridden = items.map(applyNonNegotiableOverrides).toList(growable: false);
    return filterSpendTransactionDateOutliers(overridden, label: label);
  }

  /// Removes *exact* duplicates (same date, amount, merchant, description).
  ///
  /// This primarily prevents the same statement being saved multiple times
  /// (or partial + final parse results being merged) from causing repeated rows
  /// in downstream analysis.
  ///
  /// Important: This is intentionally conservative and only dedupes when all
  /// key fields match after light normalization. If a user genuinely has two
  /// identical purchases, this will collapse them — but that scenario is
  /// typically rarer than the accidental double-save/import we’re guarding.
  static List<SpendTransaction> dedupeExactTransactions(
    List<SpendTransaction> items, {
    required String label,
  }) {
    String norm(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    String dayKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    String keyFor(SpendTransaction t) {
      // Use fixed-precision amount to avoid float encoding differences.
      final amt = Formatters.fixed(t.amount, decimals: 2);
      return '${dayKey(t.date)}|$amt|${norm(t.merchant)}|${norm(t.description)}';
    }

    final seen = <String>{};
    final out = <SpendTransaction>[];
    for (final t in items) {
      final k = keyFor(t);
      if (seen.add(k)) out.add(t);
    }
    final removed = items.length - out.length;
    if (removed > 0) {
      debugPrint('StatementParserService.dedupeExactTransactions label=$label removed=$removed kept=${out.length}');
    }
    return out;
  }

  /// Applies all post-categorization overrides to a single transaction.
  ///
  /// Order matters:
  /// - Exclude override first (must short-circuit)
  /// - ToastTab override next
  /// - Interest override last (must always win)
  static SpendTransaction applyNonNegotiableOverrides(SpendTransaction tx) {
    final excluded = applyExcludeOverride(tx);
    final afterOthers = excluded.category.trim().toLowerCase() == 'exclude'
        ? excluded
        : applyInterestOverride(applyToastTabOverride(excluded));
    return _forceNegativeIfExcluded(afterOthers);
  }

  static SpendTransaction _forceNegativeIfExcluded(SpendTransaction tx) {
    final c = tx.category.trim().toLowerCase();
    final sc = (tx.subcategory ?? '').trim().toLowerCase();
    if (c != 'exclude' && sc != 'exclude') return tx;
    if (tx.amount.isNegative) return tx;
    return tx.copyWith(amount: -tx.amount.abs(), updatedAt: DateTime.now());
  }

  /// User rule: AFTER normal category matching (SpendIQ master), detect certain
  /// non-spend transactions (payments/fees/interest/redemptions/etc.) and force
  /// them into category `Exclude`.
  ///
  /// Matching requirements (user request):
  /// - Case-insensitive
  /// - Whole-phrase match as consecutive whole words (no substring matches)
  /// - Punctuation/extra whitespace around the phrase is OK
  /// - Phrase words must appear together and unbroken
  static SpendTransaction applyExcludeOverride(SpendTransaction tx) {
    try {
      // Some sources put summary rows like "LATE FEE" / "CASH ADVANCE FEE" in
      // the merchant field rather than description. Treat merchant+description
      // as the searchable text so Exclude rules apply consistently.
      final searchable = '${tx.description} ${tx.merchant}'.trim();
      final phrase = _findExcludePhraseMatch(searchable);
      if (phrase == null) return tx;

      return tx.copyWith(
        // Excluded lines should never be counted as spend. Force negative so any
        // downstream "spend only" logic can safely filter them out.
        amount: -tx.amount.abs(),
        category: 'Exclude',
        subcategory: 'Exclude',
        brand: '',
        special: [
          if ((tx.special ?? '').trim().isNotEmpty) tx.special!.trim(),
          'Exclude override (phrase: "$phrase")',
        ].where((s) => s.trim().isNotEmpty).join(' · '),
        updatedAt: DateTime.now(),
      );
    } catch (e) {
      debugPrint('StatementParserService.applyExcludeOverride error: $e');
      return tx;
    }
  }

  static const List<String> _excludePhrases = [
    'payment thank you',
    'payment - thank you',
    'mobile payment',
    'online payment',
    'automatic payment',
    'autopay',
    'auto pay',
    'directpay',
    'payment received',
    'payment elec xfr',
    'annual fee',
    'annual membership fee',
    'membership fee',
    'card membership fee',
    'interest charge',
    'late fee',
    'late payment fee',
    'returned payment fee',
    'nsf fee',
    'overlimit fee',
    'over-limit fee',
    'over limit fee',
    'cash advance fee',
    'balance transfer fee',
    'convenience check fee',
    'cash advance',
    'balance transfer',
    'cashback bonus redemption',
    'rewards redemption',
    'points redemption',
    'statement credit',
    'reward credit',
    'mr redemption',
    'pay with points',
    'new balance',
    'account ending in',
  ];

  static String? _findExcludePhraseMatch(String description) {
    final descTokens = _tokenizeWords(description);
    if (descTokens.isEmpty) return null;

    for (final phrase in _excludePhrases) {
      final phraseTokens = _tokenizeWords(phrase);
      if (phraseTokens.isEmpty) continue;
      if (_containsConsecutiveTokenSequence(descTokens, phraseTokens)) return phrase;
    }
    return null;
  }

  static List<String> _tokenizeWords(String input) {
    // Keep only a-z / 0-9 as token characters. Everything else becomes a separator.
    // This makes punctuation/hyphens not interfere with whole-phrase word matching.
    final lower = input.toLowerCase();
    final normalized = lower.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    return normalized.split(RegExp(r'\s+')).where((t) => t.trim().isNotEmpty).toList(growable: false);
  }

  static bool _containsConsecutiveTokenSequence(List<String> tokens, List<String> phraseTokens) {
    if (phraseTokens.length > tokens.length) return false;
    if (phraseTokens.isEmpty) return false;
    for (int i = 0; i <= tokens.length - phraseTokens.length; i++) {
      bool ok = true;
      for (int j = 0; j < phraseTokens.length; j++) {
        if (tokens[i + j] != phraseTokens[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
    return false;
  }

  /// User rule: `TST*` stands for ToastTab and should ALWAYS be categorized as Dining.
  ///
  /// This runs post-categorization so it can override whatever the master mapping
  /// selected, without adding any guessy heuristics elsewhere.
  static SpendTransaction applyToastTabOverride(SpendTransaction tx) {
    try {
      final joined = '${tx.merchant} ${tx.description}'.toLowerCase();
      // Common statement descriptor formats include:
      // - "TST*<merchant name>" (sometimes glued to previous characters, e.g. "...5TST*...")
      // - "TST <merchant name>" (asterisk missing in some text-layer/OCR outputs)
      // We intentionally avoid `\b` word-boundaries because PDF text extraction can
      // concatenate tokens (digit+TST*) which would defeat `\b`.
      // We treat *any* occurrence of a ToastTab descriptor starting with `TST`
      // (with or without the `*`, with or without whitespace) as ToastTab.
      //
      // Why so permissive?
      // - Some Discover PDFs glue tokens so the delimiter becomes `TSTUEF...`.
      // - Some OCR outputs drop `*` and whitespace.
      //
      // Guardrail: we still require the preceding character to NOT be a letter
      // so we don't accidentally match inside unrelated words (e.g. "arTSTic").
      // Primary match: the canonical ToastTab marker is `TST*`.
      // We allow optional whitespace before/after the asterisk to survive OCR weirdness.
      final hasTstStar = RegExp(r'(?<![a-z])tst\s*\*', caseSensitive: false).hasMatch(joined);
      // Fallback match: some PDFs/OCR drop the `*` or whitespace, producing `TSTSomething`.
      final hasTstPrefix = RegExp(r'(?<![a-z])tst(?=[^a-z]|$)', caseSensitive: false).hasMatch(joined) ||
          RegExp(r'(?<![a-z])tst(?=[a-z0-9])', caseSensitive: false).hasMatch(joined);
      final isToastTab = hasTstStar || hasTstPrefix;
      if (!isToastTab) return tx;

      return tx.copyWith(
        category: Level1Categories.dining,
        subcategory: 'Restaurants',
        special: [
          if ((tx.special ?? '').trim().isNotEmpty) tx.special!.trim(),
          'ToastTab override (TST*)',
        ].where((s) => s.trim().isNotEmpty).join(' · '),
        updatedAt: DateTime.now(),
      );
    } catch (e) {
      debugPrint('StatementParserService.applyToastTabOverride error: $e');
      return tx;
    }
  }

  static bool _shouldForceOcrFallback(String rawExtractedText) {
    final t = rawExtractedText.replaceAll('\u0000', '').trim();
    if (t.isEmpty) return true;
    // If extraction yields almost no useful text, it's typically a scanned PDF
    // or a CID/CMap mapping failure. In both cases OCR should be the source of truth.
    if (t.length < 200) return true;
    if (_isLikelyCidMappingFailure(t)) return true;
    return false;
  }

  static double _applyInterestNegativity({required String description, required double amount}) {
    // Some statement rows are non-spend summary/metadata lines that can still carry
    // an amount. We force those negative so downstream "spend only" logic can
    // safely ignore them.
    if (isInterestText(description)) return -amount.abs();
    final phrase = _findForceNegativePhraseMatch(description);
    if (phrase != null) return -amount.abs();
    return amount;
  }

  /// Phrases that should force an amount negative (so it's excluded from spend
  /// analytics) even if the statement provides a positive figure.
  ///
  /// Matching uses the same whole-phrase, consecutive whole-word rules as the
  /// Exclude override.
  static const List<String> _forceNegativePhrases = [
    'new balance',
    'account ending in',
  ];

  static String? _findForceNegativePhraseMatch(String description) {
    final descTokens = _tokenizeWords(description);
    if (descTokens.isEmpty) return null;

    for (final phrase in _forceNegativePhrases) {
      final phraseTokens = _tokenizeWords(phrase);
      if (phraseTokens.isEmpty) continue;
      if (_containsConsecutiveTokenSequence(descTokens, phraseTokens)) return phrase;
    }
    return null;
  }

  /// Final post-processing hook.
  ///
  /// This MUST run **after** categorization so it can override any chosen
  /// Level 1/2 when a transaction is an interest charge.
  static SpendTransaction applyInterestOverride(SpendTransaction tx) {
    final text = '${tx.description} ${tx.merchant}'.trim();
    final byText = isInterestText(text);
    final byMerchantMaster = _isInterestFromMerchantMaster(tx);
    if (!byText && !byMerchantMaster) return tx;

    return tx.copyWith(
      amount: -tx.amount.abs(),
      category: 'Interest',
      subcategory: 'Interest',
      brand: '',
      special: [
        if ((tx.special ?? '').trim().isNotEmpty) tx.special!.trim(),
        if (byText) 'Interest override (text)',
        if (byMerchantMaster) 'Interest override (merchant master)',
      ].where((s) => s.trim().isNotEmpty).join(' · '),
      updatedAt: DateTime.now(),
    );
  }

  /// User rule (per merchant table):
  /// If the Merchant Master match contains the word "Interest" anywhere, we
  /// must treat the transaction as Interest and force the amount negative.
  ///
  /// This is intentionally independent of OCR text detection because some
  /// PDFs/CSVs may distort the original description, but the merchant table
  /// match is authoritative.
  static bool _isInterestFromMerchantMaster(SpendTransaction tx) {
    try {
      final match = MasterSpreadsheetService.matchMerchantMaster('${tx.merchant} ${tx.description}');
      if (match == null) return false;

      bool hasInterest(String? s) => s != null && s.trim().isNotEmpty && isInterestText(s);
      return hasInterest(match.key) || hasInterest(match.row.cleanMerchant) || hasInterest(match.row.level1) || hasInterest(match.row.level2);
    } catch (e) {
      debugPrint('StatementParserService._isInterestFromMerchantMaster error: $e');
      return false;
    }
  }

  static get len_ => null;

  /// Parse PDF from asset path bundled in app assets.
  static Future<List<SpendTransaction>> parsePdfFromAsset(String assetPath) async {
    try {
      final bytes = await rootBundle.load(assetPath);
      return parsePdfFromBytes(bytes.buffer.asUint8List());
    } catch (e) {
      debugPrint('StatementParserService.parsePdfFromAsset error: $e');
      return [];
    }
  }

  /// Discover-only simple row parser used for the preview/CSV flow.
  /// Visual Lines Mode as requested:
  /// - Preserve visual lines (as they appear when copying from the PDF)
  /// - Scan for DATE (MM/DD) at start of a line, then TEXT possibly spanning subsequent wrapped lines,
  ///   then AMOUNT on the same line or a later line. Stop if a new DATE starts before an AMOUNT.
  /// - Associate the nearest following AMOUNT after the TEXT block.
  static _SimpleRows _parseDiscoverToSimpleRows(String text) {
    final cleaned = text.replaceAll('\u0000', '');
    // Discover single-line capture (improved):
    // - Start of line: MM/DD
    // - Optional second date token right after (MM/DD)
    // - Merchant/desc (lazy)
    // - First amount-like token ($ 0.00, $0.00, or (0.00) etc.)
    // - Allow any trailing characters after the amount (categories/codes/noise)
    final strictLine = RegExp(
        r'^\s*(?<m>\d{1,2})\/(?<d>\d{1,2})(?:\/(?<y>\d{2,4}))?\b(?:\s+\d{1,2}\/\d{1,2}(?:\/\d{2,4})?)?\s+(?<desc>.+?)\s+(?<amt>[-+]?\(?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})\)?)\b.*$',
        caseSensitive: false);
    // Fallback for tricky Discover lines (per user request):
    // If a line starts with MM/DD and contains any $amount later, capture the first
    // $amount and take everything between date token and that $ as the description.
    final dateAtStart = RegExp(r'^\s*(?<m>\d{1,2})\/(?<d>\d{1,2})(?:\/(?<y>\d{2,4}))?\b');
    final firstDollarAmount = RegExp(r'[-+]?\(?\$\s*\d{1,3}(?:,\d{3})*(?:\.\d{2})\)?');

    // Performance: for Discover only, we already sliced to the Transactions
    // section. Further speed it up by only scanning lines that START with a
    // date token at the beginning of the line. Keep all existing parsing
    // rules the same; this only reduces the candidate set.
    final lines = cleaned
        .split('\n')
        .map((l) => l.replaceAll('\u0000', '').trimRight())
        .where((l) => l.trim().isNotEmpty)
        .where((l) => dateAtStart.hasMatch(l))
        .toList();

    final rows = <SimpleTransactionRow>[];
    final unparsed = <String>[];

    for (final line in lines) {
      final RegExpMatch? m = strictLine.firstMatch(line);
      String desc;
      String amtStr;
      int mm;
      int dd;
      if (m == null) {
        // Try fallback: MM/DD ... $amount (ignore any trailing junk)
        final RegExpMatch? dm = dateAtStart.firstMatch(line);
        final am = firstDollarAmount.firstMatch(line);
        if (dm != null && am != null && am.start > dm.end) {
          mm = int.tryParse(dm.namedGroup('m') ?? '') ?? 1;
          dd = int.tryParse(dm.namedGroup('d') ?? '') ?? 1;
          final yy = _normalizeYear(dm.namedGroup('y'));
          desc = line.substring(dm.end, am.start).trim();
          amtStr = am.group(0)!.trim();

          final dt = _buildDate(mm: mm, dd: dd, yyyy: yy);
          final parsedAmount = _parseAmount(amtStr);
          final amount = _applyInterestNegativity(description: desc, amount: parsedAmount);
          rows.add(SimpleTransactionRow(
            date: dt,
            merchant: _extractMerchant(desc),
            amount: amount,
            sourceLine: line,
          ));
          continue;
        } else {
          unparsed.add(line);
          continue;
        }
      } else {
        mm = int.tryParse(m.namedGroup('m') ?? '') ?? 1;
        dd = int.tryParse(m.namedGroup('d') ?? '') ?? 1;
        final yy = _normalizeYear(m.namedGroup('y'));
        desc = (m.namedGroup('desc') ?? '').trim();
        amtStr = (m.namedGroup('amt') ?? '').trim();

        final dt = _buildDate(mm: mm, dd: dd, yyyy: yy);
        final parsedAmount = _parseAmount(amtStr);
        final amount = _applyInterestNegativity(description: desc, amount: parsedAmount);
        rows.add(SimpleTransactionRow(
          date: dt,
          merchant: _extractMerchant(desc),
          amount: amount,
          sourceLine: line,
        ));
        continue;
      }
    }

    final filteredRows = _filterDateOutliers<SimpleTransactionRow>(
      rows,
      getDate: (r) => r.date,
      label: 'discover_simple',
    );

    // Preserve the original statement order (row order) as it appears in the
    // uploaded/pasted text. Users expect analysis to follow the same sequence
    // they copied from the statement.
    final trimmedText = filteredRows.isEmpty ? text : filteredRows.map((r) => r.sourceLine).join('\n');
    return _SimpleRows(rows: filteredRows, unparsedLines: unparsed, trimmedText: trimmedText);
  }

  /// Parse PDF from bytes (works for uploads on all platforms including web).
  /// 
  /// UNIFIED: Both web and native now use the same extraction path.
  /// The only platform difference is the OCR fallback service used.
  static Future<List<SpendTransaction>> parsePdfFromBytes(Uint8List data) async {
    try {
      // Make sure spreadsheet-driven merchant cleaning and card rules are ready.
      await MasterSpreadsheetService.ensureLoaded();
      final traceId = _simplePdfCacheKey(data);
      debugPrint('PDFTRACE[$traceId] full:start platform=${kIsWeb ? "web" : "native"} bytes=${data.lengthInBytes}');

      // Offload heavy PDF decoding + extraction from the UI isolate.
      final tExtract0 = DateTime.now();
      // On Web, compute() can add noticeable overhead and provides no progress.
      // We run the same page-by-page extraction on the main isolate but yield
      // between pages to keep the UI responsive.
      var raw = await _pdfBytesToRawTextAsync(data);
      final tExtract1 = DateTime.now();
      debugPrint('PDFTRACE[$traceId] full:textlayer done ms=${tExtract1.difference(tExtract0).inMilliseconds} rawLen=${raw.length}');

      raw = _presegmentAndTrim(raw);
      debugPrint('PDFTRACE[$traceId] full:textlayer_trim done trimmedLen=${raw.length}');

      // UNIFIED: If text layer is unusable, force OCR (same logic for both platforms)
      if (_shouldForceOcrFallback(raw)) {
        try {
          debugPrint('PDFTRACE[$traceId] full:force_ocr reason=weak_textlayer');
          final rawOcr = await _runPlatformOcr(data, traceId: traceId);
          raw = _presegmentAndTrim(rawOcr);
          debugPrint('PDFTRACE[$traceId] full:force_ocr done trimmedLen=${raw.length}');
        } catch (e) {
          debugPrint('PDFTRACE[$traceId] full:force_ocr failed $e');
        }
      }
      
      // UNIFIED: Discover fallback (same logic for both platforms)
      if (_looksLikeDiscoverStatement(raw)) {
        // Keep parsing on the main isolate because it depends on preloaded
        // spreadsheet-backed categorization logic.
        final txs = _parseTextToTransactions(raw);
        final cidBad = _isLikelyCidMappingFailure(raw);
        debugPrint('PDFTRACE[$traceId] full:discover_check isDiscover=true txs=${txs.length} cidBad=$cidBad');
        if (txs.isEmpty || cidBad) {
          try {
            debugPrint('PDFTRACE[$traceId] full:fallback_ocr reason=discover_empty_or_cid');
            final rawOcr = await _runPlatformOcr(data, traceId: traceId, dpi: 300);
            final trimmed = _presegmentAndTrim(rawOcr);
            final txsFromOcr = _parseTextToTransactions(trimmed);
            if (txsFromOcr.isNotEmpty) return txsFromOcr;
          } catch (e) {
            debugPrint('PDFTRACE[$traceId] full:fallback_ocr failed $e');
          }
        } else {
          return txs;
        }
        return txs;
      }
      return _parseTextToTransactions(raw);
    } catch (e) {
      debugPrint('StatementParserService.parsePdfFromBytes error: $e');
      return [];
    }
  }

  // ========== SIMPLE EXTRACTION (no categorization) ==========
  /// Extract raw text and identify transaction lines (Date, Merchant, Amount) only.
  /// Excludes headers, footers, payments/interest/balances/totals.
  /// 
  /// UNIFIED: This now uses the same extraction path as extractSimpleFromBytesWithProgress
  /// to ensure web and native produce identical results.
  static Future<SimpleParseResult> extractSimpleFromBytes(Uint8List data) async {
    try {
      final traceId = _simplePdfCacheKey(data);
      debugPrint('PDFTRACE[$traceId] simple:start platform=${kIsWeb ? "web" : "native"} bytes=${data.lengthInBytes}');
      
      // Use the unified extraction path (same as extractSimpleFromBytesWithProgress)
      return _extractSimpleFromBytesUnified(
        data,
        traceId: traceId,
        onPageProgress: (_, __) {}, // No-op progress callback
        onPartialResult: null,
      );
    } catch (e) {
      debugPrint('StatementParserService.extractSimpleFromBytes error: $e');
      return const SimpleParseResult(rawText: '', rows: [], unparsedLines: []);
    }
  }

  /// Cross-platform helper used by the Upload UI so web + native follow the same
  /// parsing path.
  ///
  /// UNIFIED PATH: Both web and native now use the EXACT same extraction logic.
  /// The only platform difference is the OCR fallback service used.
  static Future<SimpleParseResult> extractSimpleFromBytesWithProgress(
    Uint8List data, {
    required void Function(int donePages, int totalPages) onPageProgress,
    void Function(SimpleParseResult partialResult)? onPartialResult,
  }) async {
    final traceId = _simplePdfCacheKey(data);
    debugPrint('PDFTRACE[$traceId] upload:extract_simple_with_progress platform=${kIsWeb ? "web" : "native"} bytes=${data.lengthInBytes}');
    
    // UNIFIED: Both platforms use the same progressive extraction path
    return _extractSimpleFromBytesUnified(
      data,
      traceId: traceId,
      onPageProgress: onPageProgress,
      onPartialResult: onPartialResult,
    );
  }

  /// Force an OCR-only extraction + parsing pass.
  ///
  /// This is intended as a **fallback** when the normal unified extraction
  /// returns 0 rows (commonly for some Discover statement PDFs).
  ///
  /// It does **not** change downstream categorization / matching behavior; it
  /// only changes the way we obtain text for the *same* parser.
  static Future<SimpleParseResult> extractSimpleForceOcrFromBytesWithProgress(
    Uint8List data, {
    required void Function(int donePages, int totalPages) onPageProgress,
    void Function(SimpleParseResult partialResult)? onPartialResult,
    int dpi = 300,
  }) async {
    final traceId = _simplePdfCacheKey(data);
    debugPrint(
      'PDFTRACE[$traceId] upload:force_ocr_simple platform=${kIsWeb ? "web" : "native"} bytes=${data.lengthInBytes} dpi=$dpi',
    );

    try {
      await MasterSpreadsheetService.ensureLoaded();

      final t0 = DateTime.now();
      final rawOcr = await _runPlatformOcr(
        data,
        traceId: traceId,
        onPageProgress: onPageProgress,
        dpi: dpi,
      );
      final t1 = DateTime.now();
      debugPrint(
        'PDFTRACE[$traceId] force_ocr:text done ms=${t1.difference(t0).inMilliseconds} rawLen=${rawOcr.length}',
      );

      final trimmed = _presegmentAndTrim(rawOcr);
      final parsedMap = await compute(_extractSimpleInIsolate, trimmed);
      final parsedRows = (parsedMap['rows'] as List)
          .map((e) {
            final m = e as Map;
            return SimpleTransactionRow(
              date: DateTime.fromMillisecondsSinceEpoch((m['dateEpoch'] as num).toInt()),
              merchant: (m['merchant'] as String?) ?? '',
              amount: (m['amount'] as num).toDouble(),
              sourceLine: (m['sourceLine'] as String?) ?? '',
            );
          })
          .toList(growable: false);
      final parsedUnparsed = (parsedMap['unparsedLines'] as List).map((e) => e.toString()).toList(growable: false);
      final parsedTrimmedText = (parsedMap['trimmedText'] as String?) ?? '';

      final result = SimpleParseResult(rawText: parsedTrimmedText, rows: parsedRows, unparsedLines: parsedUnparsed);
      onPartialResult?.call(result);
      return result;
    } catch (e) {
      debugPrint('StatementParserService.extractSimpleForceOcrFromBytesWithProgress error: $e');
      return const SimpleParseResult(rawText: '', rows: [], unparsedLines: []);
    }
  }
  
  /// UNIFIED extraction path for both web and native platforms.
  /// This ensures identical parsing behavior across all platforms.
  static Future<SimpleParseResult> _extractSimpleFromBytesUnified(
    Uint8List data, {
    required String traceId,
    required void Function(int donePages, int totalPages) onPageProgress,
    void Function(SimpleParseResult partialResult)? onPartialResult,
  }) async {
    await MasterSpreadsheetService.ensureLoaded();
    debugPrint('PDFTRACE[$traceId] unified:start platform=${kIsWeb ? "web" : "native"} bytes=${data.lengthInBytes}');

    // User request: never persist or reuse parse cache.
    // (We keep the traceId format for debugging parity between platforms.)
    final cacheKey = traceId;
    if (enableSimplePdfCache) {
      final cached = await _readSimplePdfCache(cacheKey);
      if (cached != null) {
        if (_looksLikeDiscoverStatement(cached.rawText) && cached.rows.isEmpty) {
          debugPrint('PDFTRACE[$traceId] unified:cache hit but ignored discover_empty key=$cacheKey');
        } else {
          debugPrint('PDFTRACE[$traceId] unified:cache hit key=$cacheKey rawLen=${cached.rawText.length} rows=${cached.rows.length} unparsed=${cached.unparsedLines.length}');
          onPageProgress(1, 1);
          onPartialResult?.call(cached);
          return cached;
        }
      }
      debugPrint('PDFTRACE[$traceId] unified:cache miss key=$cacheKey');
    } else {
      debugPrint('PDFTRACE[$traceId] unified:cache disabled');
    }

    // STEP 1: Extract text from PDF.
    // - Web: run on main isolate with yielding + real per-page progress.
    // - Native: run in background isolate (no per-page progress available).
    final tExtract0 = DateTime.now();
    if (!kIsWeb) {
      onPageProgress(0, 3);
    }
    var raw = await _pdfBytesToRawTextAsync(
      data,
      onPageProgress: kIsWeb ? onPageProgress : null,
      traceId: traceId,
    );
    final tExtract1 = DateTime.now();
    debugPrint('PDFTRACE[$traceId] unified:textlayer done ms=${tExtract1.difference(tExtract0).inMilliseconds} rawLen=${raw.length}');
    if (!kIsWeb) onPageProgress(1, 3);

    // STEP 2: Trim and decide whether OCR is required.
    final tTrim0 = DateTime.now();
    raw = _presegmentAndTrim(raw);
    final tTrim1 = DateTime.now();
    debugPrint('PDFTRACE[$traceId] unified:trim ms=${tTrim1.difference(tTrim0).inMilliseconds} trimmedLen=${raw.length}');

    // Check if text layer is unusable and force OCR
    if (_shouldForceOcrFallback(raw)) {
      try {
        debugPrint('PDFTRACE[$traceId] unified:force_ocr reason=weak_textlayer');
        final rawOcr = await _runPlatformOcr(data, traceId: traceId, onPageProgress: onPageProgress);
        raw = _presegmentAndTrim(rawOcr);
        debugPrint('PDFTRACE[$traceId] unified:force_ocr done trimmedLen=${raw.length}');
      } catch (e) {
        debugPrint('PDFTRACE[$traceId] unified:force_ocr failed $e');
      }
    }

    // STEP 3: Parse raw text -> rows off the UI isolate.
    final tParse0 = DateTime.now();
    final parsedMap = await compute(_extractSimpleInIsolate, raw);
    final tParse1 = DateTime.now();
    final parsedRows = (parsedMap['rows'] as List)
        .map((e) {
          final m = e as Map;
          return SimpleTransactionRow(
            date: DateTime.fromMillisecondsSinceEpoch((m['dateEpoch'] as num).toInt()),
            merchant: (m['merchant'] as String?) ?? '',
            amount: (m['amount'] as num).toDouble(),
            sourceLine: (m['sourceLine'] as String?) ?? '',
          );
        })
        .toList(growable: false);
    final parsedUnparsed = (parsedMap['unparsedLines'] as List).map((e) => e.toString()).toList(growable: false);
    final parsedTrimmedText = (parsedMap['trimmedText'] as String?) ?? '';
    debugPrint('PDFTRACE[$traceId] unified:parse ms=${tParse1.difference(tParse0).inMilliseconds} rows=${parsedRows.length} unparsed=${parsedUnparsed.length}');
    if (kIsWeb) {
      // Extraction already used per-page progress; keep the UI in the same step.
      onPageProgress(1, 1);
    } else {
      onPageProgress(2, 3);
    }

    final parsed = _SimpleRows(rows: parsedRows, unparsedLines: parsedUnparsed, trimmedText: parsedTrimmedText);
    final partialForUi = SimpleParseResult(rawText: parsed.trimmedText, rows: parsed.rows, unparsedLines: parsed.unparsedLines);
    onPartialResult?.call(partialForUi);

    // STEP 4: Discover fallback if needed (IDENTICAL logic for both platforms)
    if (_looksLikeDiscoverStatement(raw) && (parsed.rows.isEmpty || _isLikelyCidMappingFailure(raw))) {
      try {
        debugPrint('PDFTRACE[$traceId] unified:discover_fallback_ocr reason=empty_or_cid');
        final rawOcr = await _runPlatformOcr(
          data,
          traceId: traceId,
          onPageProgress: onPageProgress,
          dpi: 300,
        );
        final trimmed = _presegmentAndTrim(rawOcr);
        final reparsedMap = await compute(_extractSimpleInIsolate, trimmed);
        final reparsedRows = (reparsedMap['rows'] as List)
            .map((e) {
              final m = e as Map;
              return SimpleTransactionRow(
                date: DateTime.fromMillisecondsSinceEpoch((m['dateEpoch'] as num).toInt()),
                merchant: (m['merchant'] as String?) ?? '',
                amount: (m['amount'] as num).toDouble(),
                sourceLine: (m['sourceLine'] as String?) ?? '',
              );
            })
            .toList(growable: false);
        final reparsedUnparsed = (reparsedMap['unparsedLines'] as List).map((e) => e.toString()).toList(growable: false);
        final reparsedTrimmedText = (reparsedMap['trimmedText'] as String?) ?? '';
        final result = SimpleParseResult(rawText: reparsedTrimmedText, rows: reparsedRows, unparsedLines: reparsedUnparsed);
        
        final cacheable = reparsedRows.isNotEmpty;
        if (enableSimplePdfCache && cacheable) await _writeSimplePdfCache(cacheKey, result);
        onPageProgress(3, 3);
        return result;
      } catch (e) {
        debugPrint('PDFTRACE[$traceId] unified:discover_fallback_ocr failed $e');
      }
    }

    final result = partialForUi;
    final cacheable = !(_looksLikeDiscoverStatement(result.rawText) && result.rows.isEmpty);
    if (enableSimplePdfCache && cacheable) await _writeSimplePdfCache(cacheKey, result);
    if (!kIsWeb) onPageProgress(3, 3);
    return result;
  }

  /// Cross-platform raw text extraction.
  ///
  /// IMPORTANT: The extraction logic itself is identical across platforms:
  /// page-by-page with `layoutText:false`.
  ///
  /// Execution strategy differs for performance/UX:
  /// - Web: main isolate + yield per page (allows progress updates, avoids compute overhead)
  /// - Native: background isolate via `compute()` (keeps UI responsive)
  static Future<String> _pdfBytesToRawTextAsync(
    Uint8List data, {
    void Function(int done, int total)? onPageProgress,
    String? traceId,
  }) async {
    if (!kIsWeb) return compute(_pdfBytesToRawText, data);

    try {
      final sw = Stopwatch()..start();

      // Web fast/UX-safe path: use PDF.js text layer (and auto-OCR if needed)
      // via JS interop. This is asynchronous and avoids long main-thread blocks.
      if (preferWebSmartExtract) {
        try {
          debugPrint('PDFTRACE[${traceId ?? "web"}] web_smart_extract:start t=${sw.elapsedMilliseconds}ms bytes=${data.lengthInBytes}');
          // Give the UI one more chance to paint before the JS pipeline begins.
          await Future<void>.delayed(Duration.zero);

          final res = await ocr.OcrService.extractSmartResult(
            data,
            lang: 'eng',
            onPageProgress: onPageProgress,
            onPartialText: null,
          );

          debugPrint('PDFTRACE[${traceId ?? "web"}] web_smart_extract:js_returned t=${sw.elapsedMilliseconds}ms');
          final method = (res['method'] as String?) ?? 'unknown';
          final pages = (res['pages'] as List?)?.cast<String>() ?? const <String>[];
          final raw = pages.join('\n');

          debugPrint(
            'PDFTRACE[${traceId ?? "web"}] web_smart_extract:done t=${sw.elapsedMilliseconds}ms method=$method pages=${pages.length} rawLen=${raw.length}',
          );
          if (raw.trim().isNotEmpty) return raw;
          debugPrint('PDFTRACE[${traceId ?? "web"}] web_smart_extract:empty_fallback_to_dart');
        } catch (e) {
          debugPrint('PDFTRACE[${traceId ?? "web"}] web_smart_extract:failed t=${sw.elapsedMilliseconds}ms err=$e');
        }
      }

      debugPrint('PDFTRACE[${traceId ?? "web"}] textlayer:dart_start t=${sw.elapsedMilliseconds}ms');

      final docT0 = sw.elapsedMilliseconds;
      final doc = PdfDocument(inputBytes: data);
      debugPrint('PDFTRACE[${traceId ?? "web"}] textlayer:doc_open t=${sw.elapsedMilliseconds}ms (+${sw.elapsedMilliseconds - docT0}ms)');

      final extractorT0 = sw.elapsedMilliseconds;
      final extractor = PdfTextExtractor(doc);
      debugPrint('PDFTRACE[${traceId ?? "web"}] textlayer:extractor_init t=${sw.elapsedMilliseconds}ms (+${sw.elapsedMilliseconds - extractorT0}ms)');
      final total = doc.pages.count;

      // Fast-path: bulk extraction.
      //
      // NOTE: This is synchronous on web (blocks the main isolate) but is
      // typically faster than per-page extraction on many statements.
      // For Upload UI we still emit a stable (0,total) first so the UI can
      // render a deterministic progress state before the blocking call.
      onPageProgress?.call(0, total);
      // Give the UI a chance to paint the initial progress label before we do
      // the heavy synchronous extract.
      await Future<void>.delayed(Duration.zero);
      try {
        final bulkT0 = sw.elapsedMilliseconds;
        final bulk = extractor.extractText(layoutText: false);
        final bulkMs = sw.elapsedMilliseconds - bulkT0;
        debugPrint('PDFTRACE[${traceId ?? "web"}] textlayer:bulk_extract t=${sw.elapsedMilliseconds}ms ms=$bulkMs rawLen=${bulk.length}');
        if (bulk.trim().length >= 200) {
          onPageProgress?.call(total, total);
          doc.dispose();
          return bulk;
        }
      } catch (e) {
        debugPrint('PDFTRACE[${traceId ?? "web"}] textlayer:bulk_extract_failed t=${sw.elapsedMilliseconds}ms err=$e');
      }

      // Per-page fallback with stable progress totals.
      final buffer = StringBuffer();

      // Yielding every page adds noticeable overhead on some browsers.
      // Yield periodically to keep UI responsive without slowing extraction too much.
      const int yieldEveryPages = 4;
      for (int i = 0; i < total; i++) {
        try {
          final pageT0 = DateTime.now();
          final pageText = extractor.extractText(startPageIndex: i, endPageIndex: i, layoutText: false);
          final pageMs = DateTime.now().difference(pageT0).inMilliseconds;
          if (pageMs >= 750) {
            debugPrint('PDFTRACE[${traceId ?? "web"}] textlayer:page_extract_slow page=$i ms=$pageMs len=${pageText.length}');
          }
          buffer.writeln(pageText);
        } catch (e) {
          debugPrint('PDFTRACE[${traceId ?? "web"}] textlayer:page_extract_failed page=$i err=$e');
        }

        onPageProgress?.call(i + 1, total);
        // Yield occasionally to allow frames to render and keep the app interactive.
        if ((i % yieldEveryPages) == (yieldEveryPages - 1)) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      doc.dispose();
      return buffer.toString();
    } catch (e) {
      debugPrint('PDFTRACE[${traceId ?? "web"}] textlayer:extract_failed err=$e');
      return '';
    }
  }

  /// Platform-specific OCR runner. Uses the same interface for both platforms.
  static Future<String> _runPlatformOcr(
    Uint8List data, {
    required String traceId,
    void Function(int done, int total)? onPageProgress,
    int dpi = 300,
  }) async {
    if (kIsWeb) {
      final texts = await ocr.OcrService.extractRasterOnlyTexts(
        data,
        traceId: traceId,
        onPageProgress: onPageProgress,
        lang: 'eng',
        dpi: dpi,
      );
      return texts.join('\n');
    } else {
      // Native: use ML Kit via NativeOcrService
      return native_ocr.NativeOcrService.extractRawTextFromPdf(
        data,
        traceId: traceId,
        onPageProgress: onPageProgress,
        maxPages: 30,
        scale: dpi / 72.0, // Convert DPI to scale factor (72 DPI base)
      );
    }
  }

  /// Clears the cached "simple PDF" extraction results stored in SharedPreferences.
  /// Useful when comparing first-run behavior across web vs mobile.
  static Future<void> clearSimplePdfCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith('spendiq_pdf_simple_')).toList(growable: false);
      for (final k in keys) {
        await prefs.remove(k);
      }
      debugPrint('StatementParserService.clearSimplePdfCache removed=${keys.length}');
    } catch (e) {
      debugPrint('StatementParserService.clearSimplePdfCache error: $e');
    }
  }

  /// Parse plain text that the user pasted or uploaded as a .txt file.
  /// Skips PDF decoding entirely and runs the same trimming + parsing pipeline
  /// as the PDF flow. Useful when PDF extraction on web is slow.
  static Future<SimpleParseResult> extractSimpleFromText(String text) async {
    try {
      await MasterSpreadsheetService.ensureLoaded();
      final trimmed = _presegmentAndTrim(text);
      final parsed = _parseTextToSimpleRows(trimmed);
      return SimpleParseResult(
        rawText: parsed.trimmedText,
        rows: parsed.rows,
        unparsedLines: parsed.unparsedLines,
      );
    } catch (e) {
      debugPrint('StatementParserService.extractSimpleFromText error: $e');
      return const SimpleParseResult(rawText: '', rows: [], unparsedLines: []);
    }
  }

  /// Progressive extractor (UNIFIED for both web and native).
  ///
  /// This now uses the same unified extraction path as extractSimpleFromBytes
  /// to ensure identical behavior across platforms.
  ///
  /// Notes:
  /// - Both platforms use page-by-page extraction with yielding for UI responsiveness.
  /// - Partial results are emitted after each page for progressive UI updates.
  static Future<SimpleParseResult> extractSimpleFromBytesProgressive(
    Uint8List data, {
    required void Function(int donePages, int totalPages) onPageProgress,
    void Function(SimpleParseResult partialResult)? onPartialResult,
  }) async {
    final traceId = _simplePdfCacheKey(data);
    debugPrint('PDFTRACE[$traceId] simple_progressive:start platform=${kIsWeb ? "web" : "native"} bytes=${data.lengthInBytes}');
    
    // UNIFIED: Use the same extraction path for both platforms
    return _extractSimpleFromBytesUnified(
      data,
      traceId: traceId,
      onPageProgress: onPageProgress,
      onPartialResult: onPartialResult,
    );
  }

  /// Web-only helper to satisfy strict user request:
  /// - Render every PDF page to a bitmap at the specified DPI (default 300)
  /// - Ignore embedded text layer completely
  /// - Run OCR over the raster only and return the raw, unmodified text
  /// - No trimming, no parsing
  static Future<String> extractRawOcrOnlyFromPdfWeb(
    Uint8List data, {
    int dpi = 300,
    void Function(int donePages, int totalPages)? onPageProgress,
    void Function(String partialText)? onPartialText,
    String lang = 'eng',
  }) async {
    if (!kIsWeb) {
      throw UnsupportedError('extractRawOcrOnlyFromPdfWeb is only available on web');
    }
    try {
      final texts = await ocr.OcrService.extractRasterOnlyTexts(
        data,
        onPageProgress: onPageProgress,
        onPartialText: onPartialText,
        lang: lang,
        dpi: dpi,
      );
      // Return raw OCR output exactly as produced (joined by newlines between pages)
      return texts.join('\n');
    } catch (e) {
      debugPrint('extractRawOcrOnlyFromPdfWeb error: $e');
      rethrow;
    }
  }

  /// Web-only: Discover fast path OCR with cropping and lower DPI for speed.
  /// Keeps the same behavior (OCR-only, ignore text layer) but crops top/bottom
  /// margins to reduce pixels processed. Safe for Discover layout.
  static Future<String> extractRawOcrOnlyFromPdfWebFastDiscover(
    Uint8List data, {
    int dpi = 260,
    double cropTop = 0.12,
    double cropBottom = 0.08,
    void Function(int donePages, int totalPages)? onPageProgress,
    void Function(String partialText)? onPartialText,
    String lang = 'eng',
  }) async {
    if (!kIsWeb) {
      throw UnsupportedError('extractRawOcrOnlyFromPdfWebFastDiscover is only available on web');
    }
    try {
      final texts = await ocr.OcrService.extractRasterOnlyTextsCropped(
        data,
        onPageProgress: onPageProgress,
        onPartialText: onPartialText,
        lang: lang,
        dpi: dpi,
        cropTop: cropTop,
        cropBottom: cropBottom,
      );
      return texts.join('\n');
    } catch (e) {
      debugPrint('extractRawOcrOnlyFromPdfWebFastDiscover error: $e');
      rethrow;
    }
  }

  /// Web-only: Discover adaptive OCR flow.
  /// First skim all pages at 150 DPI with 12%/10% vertical crop while scanning
  /// for a line that begins with "Transactions". Once detected, the current page
  /// is re-OCRed at 200 DPI and all remaining pages are processed at 200 DPI.
  static Future<String> extractRawOcrOnlyFromPdfWebDiscoverAdaptive(
    Uint8List data, {
    int dpiFast = 150,
    int dpiFull = 200,
    double cropTop = 0.12,
    double cropBottom = 0.10,
    void Function(int donePages, int totalPages)? onPageProgress,
    void Function(String partialText)? onPartialText,
    String lang = 'eng',
  }) async {
    if (!kIsWeb) {
      throw UnsupportedError('extractRawOcrOnlyFromPdfWebDiscoverAdaptive is only available on web');
    }
    try {
      final texts = await ocr.OcrService.extractRasterDiscoverAdaptive(
        data,
        onPageProgress: onPageProgress,
        onPartialText: onPartialText,
        lang: lang,
        dpiFast: dpiFast,
        dpiFull: dpiFull,
        cropTop: cropTop,
        cropBottom: cropBottom,
      );
      return texts.join('\n');
    } catch (e) {
      // If the adaptive JS entry point is missing (e.g., hot reload didn't pick up web/ocr.js)
      // or any other runtime error occurs, fall back to the faster cropped raster-only path,
      // and then to the standard 300 DPI OCR as a last resort.
      debugPrint('extractRawOcrOnlyFromPdfWebDiscoverAdaptive error: $e');
      try {
        debugPrint('Falling back to cropped raster-only OCR (Discover fast path @~260 DPI)…');
        final texts = await ocr.OcrService.extractRasterOnlyTextsCropped(
          data,
          onPageProgress: onPageProgress,
          onPartialText: onPartialText,
          lang: lang,
          dpi: 260,
          cropTop: cropTop,
          cropBottom: cropBottom,
        );
        return texts.join('\n');
      } catch (e2) {
        debugPrint('Cropped raster-only fallback failed: $e2 — trying standard 300 DPI OCR…');
        final texts = await ocr.OcrService.extractRasterOnlyTexts(
          data,
          onPageProgress: onPageProgress,
          onPartialText: onPartialText,
          lang: lang,
          dpi: 300,
        );
        return texts.join('\n');
      }
    }
  }

  static String _simplePdfCacheKey(Uint8List data) {
    // Fast, non-cryptographic hash to avoid pulling in extra packages.
    // Collisions are unlikely for typical statement PDFs; even if they occur,
    // worst case is showing cached results for a different PDF of same size.
    int hash = 0x811C9DC5; // FNV-1a 32-bit offset basis
    const int prime = 0x01000193;
    // Sample the whole file for small PDFs, or stride for large ones.
    final int len = data.length;
    final int step = len <= 64 * 1024 ? 1 : (len ~/ (64 * 1024));
    for (int i = 0; i < len; i += step) {
      hash ^= data[i];
      hash = (hash * prime) & 0xFFFFFFFF;
    }
    hash ^= len;
    hash = (hash * prime) & 0xFFFFFFFF;
    final hex = hash.toRadixString(16).padLeft(8, '0');
    return 'spendiq_pdf_simple_${len}_$hex';
  }

  /// Public helper so UI code can log a stable identifier for the uploaded PDF.
  /// This matches the cache key used by the "simple" extractor, making it
  /// easy to compare desktop vs mobile runs in logs.
  static String debugTraceIdForPdfBytes(Uint8List data) => _simplePdfCacheKey(data);

  static Future<SimpleParseResult?> _readSimplePdfCache(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = _safeJsonDecode(raw);
      if (decoded is! Map) return null;
      final trimmedText = (decoded['rawText'] as String?) ?? '';
      final rowsJson = (decoded['rows'] as List?) ?? const [];
      final unparsed = (decoded['unparsedLines'] as List?) ?? const [];
      final rows = <SimpleTransactionRow>[];
      for (final item in rowsJson) {
        if (item is! Map) continue;
        final epoch = item['dateEpoch'];
        final merchant = item['merchant'];
        final amount = item['amount'];
        final sourceLine = item['sourceLine'];
        if (epoch is! int || merchant is! String || amount is! num || sourceLine is! String) continue;
        final adjustedAmount = _applyInterestNegativity(description: sourceLine.isNotEmpty ? sourceLine : merchant, amount: amount.toDouble());
        rows.add(SimpleTransactionRow(date: DateTime.fromMillisecondsSinceEpoch(epoch), merchant: merchant, amount: adjustedAmount, sourceLine: sourceLine));
      }
      final unparsedLines = unparsed.whereType<String>().toList(growable: false);
      if (rows.isEmpty && trimmedText.isEmpty && unparsedLines.isEmpty) return null;
      return SimpleParseResult(rawText: trimmedText, rows: rows, unparsedLines: unparsedLines);
    } catch (e) {
      debugPrint('PDF(simple): cache read error ($key): $e');
      return null;
    }
  }

  static Future<void> _writeSimplePdfCache(String key, SimpleParseResult result) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rowsJson = result.rows
          .map((r) => {
                'dateEpoch': r.date.millisecondsSinceEpoch,
                'merchant': r.merchant,
                'amount': r.amount,
                'sourceLine': r.sourceLine,
              })
          .toList(growable: false);
      final payload = <String, Object>{
        'rawText': result.rawText,
        'rows': rowsJson,
        'unparsedLines': result.unparsedLines,
        'savedAtEpoch': DateTime.now().millisecondsSinceEpoch,
      };
      await prefs.setString(key, _safeJsonEncode(payload));
    } catch (e) {
      debugPrint('PDF(simple): cache write error ($key): $e');
    }
  }

  static Object? _safeJsonDecode(String raw) {
    try {
      // Keep json helpers local to avoid adding broader dependencies.
      // ignore: avoid_dynamic_calls
      return (raw.isEmpty) ? null : jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  static String _safeJsonEncode(Object value) {
    try {
      // ignore: avoid_dynamic_calls
      return jsonEncode(value);
    } catch (_) {
      return '';
    }
  }

  // Top-level function required for compute().
  static Map<String, Object> _extractSimpleInIsolate(String rawText) {
    final parsed = _parseTextToSimpleRows(rawText);
    final rows = parsed.rows
        .map((r) => <String, Object>{
              'dateEpoch': r.date.millisecondsSinceEpoch,
              'merchant': r.merchant,
              'amount': r.amount,
              'sourceLine': r.sourceLine,
            })
        .toList();
    return <String, Object>{
      'trimmedText': parsed.trimmedText,
      'rows': rows,
      'unparsedLines': parsed.unparsedLines,
    };
  }

  /// Top-level function used with compute() to extract raw text from PDF bytes
  /// off the main isolate. Returns concatenated page text.
  static String _pdfBytesToRawText(Uint8List data) {
    try {
      final document = PdfDocument(inputBytes: data);
      final extractor = PdfTextExtractor(document);

      // Fast-path: try a single bulk extraction first.
      try {
        final bulk = extractor.extractText(layoutText: false);
        if (bulk.trim().length >= 200) {
          document.dispose();
          return bulk;
        }
      } catch (_) {
        // In isolate – swallow and fall back.
      }

      final buffer = StringBuffer();
      for (int i = 0; i < document.pages.count; i++) {
        try {
          // Keep native text-layer extraction aligned with the web path.
          // Web uses layoutText:false in the SIMPLE pipeline, which tends to
          // preserve token separation better for our regex-based parsers.
          final pageText = extractor.extractText(startPageIndex: i, endPageIndex: i, layoutText: false);
          buffer.writeln(pageText);
        } catch (e) {
          // In isolate – no debugPrint. Swallow and continue.
        }
      }
      document.dispose();
      return buffer.toString();
    } catch (_) {
      return '';
    }
  }

  /// Keep only the portion of the statement that looks like the transaction body
  /// without relying on any specific header like "Date of Transaction".
  /// Heuristic:
  /// - Find the first line that STARTS with a date token -> start here
  /// - If none found, return original text (safer than over-trimming)
  static String _trimToTransactionsSection(String text) {
    // Find the first line that STARTS with a date token.
    // This trims page summaries before the first actual transaction-like row.
    final lines = text.split('\n');
    final dateLine = RegExp(
        r'^\s*(\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?|\d{4}\-\d{2}\-\d{2}|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?)',
        caseSensitive: false);
    int charCount = 0;
    for (final line in lines) {
      if (dateLine.hasMatch(line)) {
        return text.substring(charCount);
      }
      charCount += line.length + 1; // +1 for the split newline
    }

    // If nothing matched, return as-is to avoid accidental data loss.
    return text;
  }

  /// Some statements contain multiple adjacent sections (e.g., Purchases, Payments,
  /// Fees, Cash Advances). When these are extracted to plain text, their bodies can
  /// appear back-to-back and confuse the triplet scanner. To be more adaptive,
  /// we first split the raw text into coarse sections by header-like lines, then
  /// trim each section to its first date-starting line, and finally rejoin.
  static String _presegmentAndTrim(String text) {
    // Reverted: remove any Discover-specific pre-trimming. Always run generic segmentation.

    final sections = _splitByHeaders(text);
    final kept = <String>[];

    final isDateStart = RegExp(
        r'^\s*(\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?|\d{4}-\d{2}-\d{2}|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?)',
        caseSensitive: false);
    for (final sec in sections) {
      final trimmed = _trimToTransactionsSection(sec);
      // Keep if the first non-empty, non-header line starts with a date
      final firstLines = trimmed
          .split('\n')
          .map((l) => l.replaceAll('\u0000', '').trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (firstLines.isNotEmpty && isDateStart.hasMatch(firstLines.first)) {
        kept.add(trimmed);
      }
    }
    if (kept.isEmpty) return _trimToTransactionsSection(text);
    return kept.join('\n');
  }

  /// Identify Discover It statements reliably. We check multiple spellings
  /// because PDFs may drop the registered mark or insert whitespace.
  static bool _looksLikeDiscoverStatement(String text) {
    // Apply Discover-only logic STRICTLY to Discover statements.
    // Heuristic: require clear Discover branding to avoid false positives.
    // We look for either specific phrases like "Discover it"/"Discover Card",
    // or the generic word "Discover" together with a Discover-unique section
    // such as "Cashback Bonus" seen on monthly statements.
    final t = text.toLowerCase();
    if (!t.contains('discover')) return false;

    final hasBrand = t.contains('discover it') ||
        t.contains('discover card') ||
        t.contains('discover bank') ||
        t.contains('discover.com');

    final hasUniqueSection = t.contains('cashback bonus') ||
        t.contains('cash back bonus');

    // Only treat as Discover if branding is very likely present.
    return hasBrand || hasUniqueSection;
  }

  /// Heuristic to detect when embedded text extraction likely failed due to
  /// CID-encoded fonts without a usable ToUnicode CMap mapping.
  /// Signals when text contains many replacement/null chars or too few
  /// ASCII letters/digits relative to length.
  static bool _isLikelyCidMappingFailure(String text) {
    final s = text.replaceAll('\n', '');
    if (s.trim().isEmpty) return true;
    final total = s.length;
    int ascii = 0;
    int repl = 0;
    int nulls = 0;
    final asciiRx = RegExp(r'[A-Za-z0-9\s\.,:\-\/$]');
    for (int i = 0; i < s.length; i++) {
      final ch = s[i];
      if (asciiRx.hasMatch(ch)) ascii++;
      if (ch == '\u{FFFD}') repl++;
      if (ch.codeUnitAt(0) == 0) nulls++;
    }
    final asciiRatio = ascii / total;
    // Very short or very low ASCII ratio is a strong indicator. Also, many replacement/null chars.
    return total < 80 || asciiRatio < 0.35 || repl > total * 0.02 || nulls > 0;
  }

  /// For Discover It statements, keep only the text between the
  /// "Transactions" header and the next major section header.
  /// We do a conservative scan to avoid over-trimming if headers are missing.
  static String _extractDiscoverTransactionsSection(String text) {
    // Fast prefilter (Discover-only speed-up):
    // Toss every leading line whose first non-space character is not 't'/'T',
    // and stop as soon as we hit a line that starts with "Transactions".
    // Then proceed with the usual section slicing. This avoids scanning large
    // header blocks on some statements and speeds up parsing.
    String _prefilterToTransactionsLeadIn(String t) {
      final lines = t.split('\n');
      int charCount = 0;

      bool looksLikeTransactionsAt(int idx) {
        String safe(int i) => (i >= 0 && i < lines.length) ? lines[i].replaceAll('\u0000', '') : '';
        final l0 = safe(idx);
        final l1 = safe(idx + 1);
        final l2 = safe(idx + 2);

        String normalize(String s) => s
            .replaceFirst(RegExp(r'^\s+'), '')
            .replaceAll(RegExp(r'-\s*$'), '')
            .replaceAll(RegExp(r'[^A-Za-z]+'), '')
            .toLowerCase();

        // 1) Single-line quick check
        final single = l0.replaceFirst(RegExp(r'^\s+'), '');
        if (single.toLowerCase().startsWith('transactions')) return true;

        // 2) Two-line join tolerant to hyphenation
        final twoJoined = (l0.replaceAll(RegExp(r'-\s*$'), '') + ' ' + l1);
        if (normalize(twoJoined).startsWith('transactions')) return true;

        // 3) Three-line join tolerant to hyphenation
        final threeJoined = (l0.replaceAll(RegExp(r'-\s*$'), '') + ' ' + l1.replaceAll(RegExp(r'-\s*$'), '') + ' ' + l2);
        if (normalize(threeJoined).startsWith('transactions')) return true;

        return false;
      }

      for (int i = 0; i < lines.length; i++) {
        final line = lines[i];
        final trimmedLeft = line.replaceAll('\u0000', '').trimLeft();
        if (trimmedLeft.isEmpty) {
          charCount += line.length + 1; // include newline
          continue;
        }
        if (looksLikeTransactionsAt(i)) {
          return t.substring(charCount);
        }
        charCount += line.length + 1;
      }
      // If nothing matched, return original text to avoid data loss.
      return t;
    }

    final prefiltered = _prefilterToTransactionsLeadIn(text);
    final upper = prefiltered.toUpperCase();
    final startHdrs = [
      'TRANSACTIONS', // primary header seen on Discover statements
      'ACCOUNT ACTIVITY', // fallback some variants
    ];
    int startIdx = -1;
    for (final h in startHdrs) {
      final i = upper.indexOf(h);
      if (i != -1) {
        startIdx = i;
        break;
      }
    }
    if (startIdx == -1) return prefiltered; // can't find a clean start, keep prefiltered/original

    // Candidate end headers that typically follow the Transactions block
    final endHdrs = <String>[
      'FEES AND INTEREST CHARGED',
      'INTEREST CHARGE CALCULATION',
      'CASHBACK BONUS',
      'CASH BACK BONUS',
      'INFORMATION FOR YOU',
      'SUMMARY OF CHARGES',
      'YEAR-TO-DATE',
    ];
    int endIdx = prefiltered.length;
    for (final h in endHdrs) {
      final i = upper.indexOf(h, startIdx + 12); // search after start
      if (i != -1 && i < endIdx) endIdx = i;
    }
    // Extract the slice. If no end header found, grab to end of document.
    final slice = prefiltered.substring(startIdx, endIdx);

    // Drop the leading header line itself so follow-up logic doesn't need to.
    final lines = slice.split('\n');
    if (lines.isNotEmpty) {
      // Remove the first non-empty line (the header)
      int firstIdx = 0;
      while (firstIdx < lines.length && lines[firstIdx].trim().isEmpty) {
        firstIdx++;
      }
      final body = lines.sublist(firstIdx + 1).join('\n');
      return body.isEmpty ? slice : body;
    }
    return slice;
  }

  /// Split text by header-like delimiters commonly found in statements.
  /// We do not include the header lines in the resulting chunks.
  static List<String> _splitByHeaders(String text) {
    final lines = text.split('\n');
    final headerRx = RegExp(
      r'^\s*(purchases|transactions|activity|account activity|payments|other credits|credits|fees|interest|cash advances|balance transfers|adjustments|disputes?)\b',
      caseSensitive: false,
    );

    bool looksLikeHeader(String l) {
      final s = l.replaceAll('\u0000', '').trim();
      if (s.isEmpty) return false;
      // Conservative: only split on known keywords to avoid breaking valid lines
      return headerRx.hasMatch(s);
    }

    final chunks = <String>[];
    final buf = StringBuffer();
    for (final l in lines) {
      if (looksLikeHeader(l)) {
        // Close current chunk if it has content
        final chunk = buf.toString();
        if (chunk.trim().isNotEmpty) {
          chunks.add(chunk);
        }
        buf.clear();
        // Skip adding the header line itself
        continue;
      }
      buf.writeln(l);
    }
    final last = buf.toString();
    if (last.trim().isNotEmpty) chunks.add(last);
    return chunks.isEmpty ? [text] : chunks;
  }

  static _SimpleRows _parseTextToSimpleRows(String text) {
    // Discover-specific: use strict row-wise scan on the Transactions section only.
    if (_looksLikeDiscoverStatement(text)) {
      try {
        final slice = _extractDiscoverTransactionsSection(text);
        return _parseDiscoverToSimpleRows(slice);
      } catch (e) {
        debugPrint('Discover(simple) parse fallback to generic: $e');
        // fall through to generic parsing below
      }
    }
    final rawLines = text.split('\n');
    final lines = rawLines
        .map((l) => l.replaceAll('\u0000', '').trim())
        .where((l) => l.isNotEmpty)
        .where((l) => !_looksLikeHeaderOrFooter(l))
        // Per user request: keep all transactions for now, including payments/credits/interest
        // .where((l) => !_isPaymentOrCredit(l))
        .toList();

    final rows = <SimpleTransactionRow>[];
    final unparsed = <String>[];

    // Track character offsets to be able to trim original text when pattern stops.
    // Build a map of cleaned lines back to their approximate positions in the raw text.
    // We approximate by walking original text and matching non-empty, non-header lines in order.
    final originalLines = text.split('\n');
    final headerSkip = (String l) => l.replaceAll('\u0000', '').trim().isEmpty || _looksLikeHeaderOrFooter(l.replaceAll('\u0000', '').trim());
    final originalIndices = <int>[]; // starting char index of each kept line in `text`
    int cursor = 0;
    int keepIdx = 0;
    for (final ol in originalLines) {
      final cleaned = ol.replaceAll('\u0000', '').trim();
      final start = cursor;
      final end = cursor + ol.length + 1; // include newline
      if (!headerSkip(ol) && cleaned.isNotEmpty) {
        if (keepIdx < lines.length && cleaned == lines[keepIdx]) {
          originalIndices.add(start);
          keepIdx++;
        }
      }
      cursor = end;
      if (keepIdx >= lines.length) break;
    }

    // Recognize lines that contain:
    // - Date + optional second Date + Merchant + Amount
    // - Single Date + Merchant + Amount
    final primaryPatterns = [
      // MM/DD or MM/DD/YY(YY) [optional second date]  Description...  Amount
      RegExp(r'^(?<date1>\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?)\s+(?:(?<date2>\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?)\s+)?(?<desc>.+?)\s+(?<amt>[-+]?\(?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})\)?)$'),
      // YYYY-MM-DD [optional second date]  Description...  Amount
      RegExp(r'^(?<date1>\d{4}[\-]\d{2}[\-]\d{2})\s+(?:(?<date2>\d{4}[\-]\d{2}[\-]\d{2})\s+)?(?<desc>.+?)\s+(?<amt>[-+]?\(?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})\)?)$'),
      // Mon D[, YYYY] [optional second date]  Description...  Amount
      RegExp(
        r'^(?<date1>(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?)\s+(?:(?<date2>(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?)\s+)?(?<desc>.+?)\s+(?<amt>[-+]?\(?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})\)?)$',
        caseSensitive: false,
      ),
    ];

    // Tokens for columnar/multiline parsing
    final dateToken = RegExp(
        r'^(\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?|\d{4}-\d{2}-\d{2}|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?)$',
        caseSensitive: false);
    final dateAtStart = RegExp(
        r'^(\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?|\d{4}-\d{2}-\d{2}|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?)\b',
        caseSensitive: false);
    final amtLike = RegExp(r'^[-+]?\(?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})\)?$');

    int cutoffCharIndex = text.length; // default: keep all
    int lastGoodEndChar = 0;
    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      // Normalize possible double-date starts: "date1 date2 ..." -> keep date2 only
      var workLine = _normalizeRepetitiveDelimitedTriplet(line);
      final doubleDateStart = RegExp(
          r'^\s*(?<d1>(?:\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?|\d{4}-\d{2}-\d{2}|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?))\s+(?<d2>(?:\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?|\d{4}-\d{2}-\d{2}|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?))\b',
          caseSensitive: false);
      final ddm = doubleDateStart.firstMatch(workLine);
      if (ddm != null) {
        final d2 = ddm.group(2) ?? '';
        workLine = workLine.replaceFirst(doubleDateStart, '$d2 ');
      }
      Map<String, String>? g;
      for (final p in primaryPatterns) {
        final m = p.firstMatch(workLine);
        if (m != null) {
          // Prefer the second date if present; otherwise use the first
          final d1 = (m.groupCount >= 1 ? (m.group(1) ?? '') : '').trim();
          final d2 = (m.groupCount >= 2 ? (m.group(2) ?? '') : '').trim();
          final chosenDate = d2.isNotEmpty ? d2 : d1;
          g = {
            'date': chosenDate,
            'desc': (m.groupCount >= 3 ? (m.group(3) ?? '') : '').trim(),
            'amt': (m.groupCount >= 4 ? (m.group(4) ?? '') : '').trim(),
          };
          break;
        }
      }

      if (g == null) {
        // Columnar fallback: first token date, last token amount
        final tokens = workLine.split(RegExp(r'\s{2,}|\t+|\s+')).where((t) => t.trim().isNotEmpty).toList();
        if (tokens.length >= 3) {
          final first = tokens.first;
          final second = tokens.length > 1 ? tokens[1] : '';
          final last = tokens.last;
          if (dateToken.hasMatch(first) && amtLike.hasMatch(last)) {
            // If second token is also a date, prefer it and start desc after second
            final hasSecondDate = second.isNotEmpty && dateToken.hasMatch(second);
            final chosenDate = hasSecondDate ? second : first;
            final descStartIdx = hasSecondDate ? 2 : 1;
            final desc = tokens.sublist(descStartIdx, tokens.length - 1).join(' ');
            g = {'date': chosenDate, 'desc': desc, 'amt': last};
          }
        }
      }

      if (g == null) {
        // Multiline triplet parsing: Date line -> one or more merchant lines -> amount line
        if (dateAtStart.hasMatch(workLine)) {
          final dStr = dateAtStart.firstMatch(workLine)!.group(1)!.trim();
          final descParts = <String>[];
          int k = i + 1;
          for (; k < lines.length; k++) {
            final next = lines[k];
            if (amtLike.hasMatch(next)) {
              final amtStr = next.trim();
              final desc = descParts.join(' ').trim();
              if (desc.isNotEmpty) {
                // IMPORTANT: the original `line` may contain only the date token.
                // For downstream categorization + merchant master matching we
                // need a sourceLine that actually includes the merchant text.
                g = {
                  'date': dStr,
                  'desc': desc,
                  'amt': amtStr,
                  'sourceLine': '$dStr $desc $amtStr',
                };
                // Update lastGoodEndChar using originalIndices if possible
                if (k < originalIndices.length) {
                  final start = originalIndices[k];
                  final nextNl = text.indexOf('\n', start);
                  lastGoodEndChar = nextNl == -1 ? text.length : nextNl + 1;
                }
                i = k; // skip to amount line
              }
              break;
            }
            if (dateAtStart.hasMatch(next)) break; // new block started without amount
            descParts.add(next);
          }
        }
      }

      if (g == null) {
        // No match on this line; just record as unparsed and keep scanning.
        // We'll trim the raw text to the last successful amount line later.
        unparsed.add(line);
        continue;
      }

      final d = _parseDate(g['date']!);
      final rawDesc = g['desc']!;
      final a = _applyInterestNegativity(description: rawDesc, amount: _parseAmount(g['amt']!));
      final desc = _extractMerchant(rawDesc);
      if (d == null) {
        // Bad date parse; treat as unparsed and continue.
        unparsed.add(line);
        continue;
      }
      // Prefer the computed full triplet sourceLine when available.
      final sourceLine = (g['sourceLine'] ?? '').trim().isNotEmpty ? g['sourceLine']!.trim() : line;
      rows.add(SimpleTransactionRow(date: d, merchant: desc, amount: a, sourceLine: sourceLine));
      // Update lastGoodEndChar using originalIndices mapping if available.
      // If this match came from a multiline scan we may already have advanced
      // lastGoodEndChar in that branch. For single-line matches, update here.
      if (i < originalIndices.length) {
        final start = originalIndices[i];
        final nextNl = text.indexOf('\n', start);
        lastGoodEndChar = nextNl == -1 ? text.length : nextNl + 1; // include newline
      }
    }

    // Preserve original appearance order from the statement text.
    // Per user request: "then go back and delete everything up until the last charge"
    // i.e., trim any trailing non-transaction tail after the last detected amount line.
    // If no successful rows were found, keep the original text to avoid data loss.
    if (lastGoodEndChar > 0) {
      cutoffCharIndex = lastGoodEndChar;
    }
    final trimmedText = text.substring(0, cutoffCharIndex);
    final filteredRows = _filterDateOutliers<SimpleTransactionRow>(
      rows,
      getDate: (r) => r.date,
      label: 'generic_simple',
    );
    return _SimpleRows(rows: filteredRows, unparsedLines: unparsed, trimmedText: trimmedText);
  }

  /// Convert raw extracted text into transactions using heuristics.
  static List<SpendTransaction> _parseTextToTransactions(String text) {
    // Special-case: Discover statements should be parsed row-wise, strictly
    // left-to-right per user request. We only consider lines that:
    // - start with a date token at the beginning of the row
    // - contain an amount token somewhere later in the row
    // Merchant/description is whatever lies between the date token(s) and
    // the final amount token on that same row. Everything else on the row is ignored.
    if (_looksLikeDiscoverStatement(text)) {
      try {
        final slice = _extractDiscoverTransactionsSection(text);
        return _parseDiscoverTextToTransactions(slice);
      } catch (e) {
        debugPrint('Discover parse fallback to generic: $e');
        // If anything goes wrong, proceed with the generic parser below.
      }
    }

    // Try to ensure the optional Excel-based category mapping is loaded.
    // If the asset does not exist, this will no-op silently.
    CategoryMappingService.ensureLoaded();
    final now = DateTime.now();
    final rawLines = text.split('\n');
    final lines = rawLines
        .map((l) => l.replaceAll('\u0000', '').trim())
        .where((l) => l.isNotEmpty)
        .where((l) => !_looksLikeHeaderOrFooter(l))
        // Per user request: keep all transactions for now, including payments/credits/interest
        // .where((l) => !_isPaymentOrCredit(l))
        .toList();

    // Regex patterns for typical statement rows: date, description, amount, optional category
    /* final datePatterns = [
      RegExp(r'^(?<date>\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})\s+(?<desc>.+?)\s+(?<amt>[-+]?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*(?<cat>[A-Za-z\-\/ ]+)?\$? ? ? ? ?'),
      RegExp(r'^(?<date>\d{4}[\-]\d{2}[\-]\d{2})\s+(?<desc>.+?)\s+(?<amt>[-+]?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*(?<cat>[A-Za-z\-\/ ]+)?$'),
    ]; */

    // Helpers for alternative parsing modes
    final dateToken = RegExp(
        r'^(\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?|\d{4}-\d{2}-\d{2}|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?)$',
        caseSensitive: false);
    final dateAtStart = RegExp(
        r'^(\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?|\d{4}-\d{2}-\d{2}|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?)\b',
        caseSensitive: false);
    final amtLike = RegExp(r'^[-+]?\(?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})\)?$');

    final txs = <SpendTransaction>[];
    int idCounter = 0;

    // Keep scanning entire text and only record complete triplets
    for (final line in lines) {
      // Normalize possible double-date starts: "date1 date2 ..." -> keep date2 only
      var workLine = _normalizeRepetitiveDelimitedTriplet(line);
      final doubleDateStart = RegExp(
          r'^\s*(?<d1>(?:\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?|\d{4}-\d{2}-\d{2}|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?))\s+(?<d2>(?:\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?|\d{4}-\d{2}-\d{2}|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?))\b',
          caseSensitive: false);
      final ddm = doubleDateStart.firstMatch(workLine);
      if (ddm != null) {
        final d2 = ddm.group(2) ?? '';
        workLine = workLine.replaceFirst(doubleDateStart, '$d2 ');
      }
      Map<String, String>? groups;
      // Build regex patterns locally to avoid any corruption from invalid characters
      final localDatePatterns = <RegExp>[
        // M/D/YYYY style with optional category at end
        RegExp(
            r'^(?<date>\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})\s+(?<desc>.+?)\s+(?<amt>[-+]?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*(?<cat>[A-Za-z\-\/ ]+)?$'),
        // ISO date style with optional category at end
        RegExp(
            r'^(?<date>\d{4}[\-]\d{2}[\-]\d{2})\s+(?<desc>.+?)\s+(?<amt>[-+]?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})?)\s*(?<cat>[A-Za-z\-\/ ]+)?$'),
      ];
      for (final p in localDatePatterns) {
        final m = p.firstMatch(workLine);
        if (m != null) {
          final d1 = (m.groupCount >= 1 ? (m.group(1) ?? '') : '').trim();
          final d2 = (m.groupCount >= 2 ? (m.group(2) ?? '') : '').trim();
          final chosenDate = d2.isNotEmpty ? d2 : d1;
          groups = {
            'date': chosenDate,
            'desc': (m.groupCount >= 3 ? (m.group(3) ?? '') : '').trim(),
            'amt': (m.groupCount >= 4 ? (m.group(4) ?? '') : '').trim(),
            'cat': (m.groupCount >= 5 ? (m.group(5) ?? '') : '').trim(),
          };
          break;
        }
      }

      if (groups == null) {
        // Try columnar parse: date ... description ... amount
        final tokens = workLine.split(RegExp(r'\s{2,}|\t+|\s+')).where((t) => t.trim().isNotEmpty).toList();
        if (tokens.length >= 3) {
          final first = tokens.first;
          final second = tokens.length > 1 ? tokens[1] : '';
          final last = tokens.last;
          if (dateToken.hasMatch(first) && amtLike.hasMatch(last)) {
            final hasSecondDate = second.isNotEmpty && dateToken.hasMatch(second);
            final chosenDate = hasSecondDate ? second : first;
            final descStartIdx = hasSecondDate ? 2 : 1;
            final desc = tokens.sublist(descStartIdx, tokens.length - 1).join(' ');
            groups = {'date': chosenDate, 'desc': desc, 'amt': last, 'cat': ''};
          } else {
            // Fallback: detect any date and amount anywhere in the line
            final dateAny = RegExp(
                r'(\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?|\d{4}\-\d{2}\-\d{2}|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?)',
                caseSensitive: false);
            final amtAny = RegExp(r'[-+]?\(?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})\)?');
            final d = dateAny.firstMatch(line)?.group(0);
            final a = amtAny.firstMatch(line)?.group(0);
            if (d != null && a != null) {
              final desc2 = line.replaceAll(d, '').replaceAll(a, '').trim();
              groups = {'date': d, 'desc': desc2, 'amt': a, 'cat': ''};
            }
          }
        }
      }

      if (groups == null) {
        // New: multiline triplet parsing – line starts with date, then description line(s), then amount line
        if (dateAtStart.hasMatch(line)) {
          final dStr = dateAtStart.firstMatch(line)!.group(1)!.trim();
          final descParts = <String>[];
          // Find index of current line in lines (already iterating, so we can use a moving index)
          // We'll build using a temporary forward scan from current position
          int forwardIdx = lines.indexOf(line) + 1;
          for (; forwardIdx < lines.length; forwardIdx++) {
            final nxt = lines[forwardIdx];
            if (amtLike.hasMatch(nxt)) {
              final amtStr = nxt.trim();
              final desc = descParts.join(' ').trim();
              if (desc.isNotEmpty) {
                groups = {'date': dStr, 'desc': desc, 'amt': amtStr, 'cat': ''};
              }
              break;
            }
            if (dateAtStart.hasMatch(nxt)) break; // hit a new block unexpectedly
            descParts.add(nxt);
          }
        }
        // If still no groups, this line is not a complete triplet start; skip and continue scanning
        if (groups == null) continue;
      }

      final parsedDate = _parseDate(groups['date']!);
      final rawDesc = (groups['desc'] ?? '').trim();
      final hasAmount = (groups['amt'] ?? '').trim().isNotEmpty;
      if (parsedDate == null || rawDesc.isEmpty || !hasAmount) {
        // Require all three attributes: date, merchant/desc, amount
        continue;
      }
      final parsedAmount = _parseAmount(groups['amt']!);
      final adjustedAmount = _applyInterestNegativity(description: rawDesc, amount: parsedAmount);
      // Per user request: keep all transactions, including negative amounts and credits

      final merchant = _extractMerchant(rawDesc);
      final cz = SpendCategorizer.categorize(merchant: merchant, description: rawDesc);
      final t = SpendTransaction(
        id: 'pdf_${idCounter++}',
        date: parsedDate,
        description: _cleanDescription(rawDesc),
        merchant: merchant,
        category: cz.level1,
        subcategory: cz.level2,
        brand: cz.level3,
        special: cz.special,
        amount: adjustedAmount,
        createdAt: now,
        updatedAt: now,
      );
      txs.add(applyNonNegotiableOverrides(t));
    }

    return _filterDateOutliers<SpendTransaction>(
      txs,
      getDate: (t) => t.date,
      label: 'generic_pdf',
    );
  }

  /// Discover-only row-wise parser using Visual Lines Mode (see _parseDiscoverToSimpleRows).
  static List<SpendTransaction> _parseDiscoverTextToTransactions(String text) {
    CategoryMappingService.ensureLoaded();
    final now = DateTime.now();
    final cleaned = text.replaceAll('\u0000', '');
    // Discover single-line capture (improved): same as in _parseDiscoverToSimpleRows
    // Allow optional second date and trailing junk after amount.
    final strictLine = RegExp(
        r'^\s*(?<m>\d{1,2})\/(?<d>\d{1,2})(?:\/(?<y>\d{2,4}))?\b(?:\s+\d{1,2}\/\d{1,2}(?:\/\d{2,4})?)?\s+(?<desc>.+?)\s+(?<amt>[-+]?\(?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})\)?)\b.*$',
        caseSensitive: false);
    final dateAtStart = RegExp(r'^\s*(?<m>\d{1,2})\/(?<d>\d{1,2})(?:\/(?<y>\d{2,4}))?\b');
    final firstDollarAmount = RegExp(r'[-+]?\(?\$\s*\d{1,3}(?:,\d{3})*(?:\.\d{2})\)?');

    final lines = cleaned
        .split('\n')
        .map((l) => l.replaceAll('\u0000', '').trimRight())
        .where((l) => l.trim().isNotEmpty)
        // Speed-up for Discover only: only keep lines that start with a date
        // at the beginning of the line.
        .where((l) => dateAtStart.hasMatch(l))
        .toList();

    final txs = <SpendTransaction>[];
    int idCounter = 0;

    for (final line in lines) {
      final RegExpMatch? m = strictLine.firstMatch(line);
      String rawDesc;
      String amtStr;
      int mm;
      int dd;
      if (m == null) {
        final RegExpMatch? dm = dateAtStart.firstMatch(line);
        final am = firstDollarAmount.firstMatch(line);
        if (dm == null || am == null || am.start <= dm.end) {
          continue;
        }
        mm = int.tryParse(dm.namedGroup('m') ?? '') ?? 1;
        dd = int.tryParse(dm.namedGroup('d') ?? '') ?? 1;
        final yy = _normalizeYear(dm.namedGroup('y'));
        rawDesc = line.substring(dm.end, am.start).trim();
        amtStr = am.group(0)!.trim();

        final dt = _buildDate(mm: mm, dd: dd, yyyy: yy);
        final parsedAmount = _parseAmount(amtStr);
        final amount = _applyInterestNegativity(description: rawDesc, amount: parsedAmount);
        final merchant = _extractMerchant(rawDesc);

        final cz = SpendCategorizer.categorize(merchant: merchant, description: rawDesc);
        txs.add(applyNonNegotiableOverrides(SpendTransaction(
          id: 'disc_${idCounter++}',
          date: dt,
          description: _cleanDescription(rawDesc),
          merchant: merchant,
          category: cz.level1,
          subcategory: cz.level2,
          brand: cz.level3,
          special: cz.special,
          amount: amount,
          createdAt: now,
          updatedAt: now,
        )));
        continue;
      } else {
        mm = int.tryParse(m.namedGroup('m') ?? '') ?? 1;
        dd = int.tryParse(m.namedGroup('d') ?? '') ?? 1;
        final yy = _normalizeYear(m.namedGroup('y'));
        rawDesc = (m.namedGroup('desc') ?? '').trim();
        amtStr = (m.namedGroup('amt') ?? '').trim();

        final dt = _buildDate(mm: mm, dd: dd, yyyy: yy);
        final parsedAmount = _parseAmount(amtStr);
        final amount = _applyInterestNegativity(description: rawDesc, amount: parsedAmount);
        final merchant = _extractMerchant(rawDesc);

        final cz = SpendCategorizer.categorize(merchant: merchant, description: rawDesc);
        txs.add(applyNonNegotiableOverrides(SpendTransaction(
          id: 'disc_${idCounter++}',
          date: dt,
          description: _cleanDescription(rawDesc),
          merchant: merchant,
          category: cz.level1,
          subcategory: cz.level2,
          brand: cz.level3,
          special: cz.special,
          amount: amount,
          createdAt: now,
          updatedAt: now,
        )));
        continue;
      }
    }

    return _filterDateOutliers<SpendTransaction>(
      txs,
      getDate: (t) => t.date,
      label: 'discover_pdf',
    );
  }

  static List<T> _filterDateOutliers<T>(
    List<T> items, {
    required DateTime Function(T item) getDate,
    required String label,
  }) {
    // If there are only a couple of items, it's too easy to accidentally remove
    // valid history; keep everything.
    //
    // We intentionally allow outlier filtering for small datasets (e.g., 3–5
    // rows). A single far-off transaction (years away) is overwhelmingly likely
    // to be a parsing/import issue and should be dropped.
    if (items.length < 3) return items;

    int monthIndex(DateTime d) => d.year * 12 + d.month; // month is 1-12

    final months = items.map((e) => monthIndex(getDate(e))).toList(growable: false);
    final uniqueMonths = months.toSet().toList()..sort();
    if (uniqueMonths.isEmpty) return items;

    // First pass: median-centered window.
    // This is extremely robust when there is a dominant cluster (e.g., 49/50 in 2026)
    // even if the dataset spans many years.
    final sortedMonths = [...months]..sort();
    final median = sortedMonths[sortedMonths.length ~/ 2];
    final medianStart = median - ((_majorityWindowMonths - 1) ~/ 2);
    final medianEnd = medianStart + (_majorityWindowMonths - 1);
    int medianCount = 0;
    for (final m in months) {
      if (m >= medianStart && m <= medianEnd) medianCount++;
    }

    // Find the densest contiguous window of up to 13 months.
    int bestStart = uniqueMonths.first;
    int bestCount = -1;

    for (final start in uniqueMonths) {
      final end = start + (_majorityWindowMonths - 1);
      int count = 0;
      for (final m in months) {
        if (m >= start && m <= end) count++;
      }
      if (count > bestCount) {
        bestCount = count;
        bestStart = start;
      }
    }

    final bestEnd = bestStart + (_majorityWindowMonths - 1);
    final minMajority = (items.length / 2).floor() + 1;

    // Prefer whichever strategy yields a true majority.
    int chosenStart;
    int chosenEnd;
    int chosenCount;
    if (medianCount >= minMajority && medianCount >= bestCount) {
      chosenStart = medianStart;
      chosenEnd = medianEnd;
      chosenCount = medianCount;
    } else {
      chosenStart = bestStart;
      chosenEnd = bestEnd;
      chosenCount = bestCount;
    }

    if (chosenCount < minMajority) {
      // If we can't establish a 13-month majority, we STILL want to drop
      // extreme single-item parses (e.g., one stray 2019 among mostly 2026)
      // without harming legitimate multi-year history.
      //
      // Extreme-outlier pass:
      // - Compute distance from median month
      // - If ≥80% of items are within 24 months of the median, drop the rest.
      final distances = months.map((m) => (m - median).abs()).toList(growable: false);
      const extremeMonths = 24; // 2 years away from the median is almost always a bad parse/import.
      int withinExtreme = 0;
      for (final d in distances) {
        if (d <= extremeMonths) withinExtreme++;
      }
      final needsSanitization = withinExtreme >= (items.length * 0.80).ceil();
      if (needsSanitization && withinExtreme < items.length) {
        final kept = <T>[];
        int dropped = 0;
        for (int i = 0; i < items.length; i++) {
          if (distances[i] <= extremeMonths) {
            kept.add(items[i]);
          } else {
            dropped++;
          }
        }
        debugPrint(
          'StatementParserService: dropped $dropped/${items.length} EXTREME date outlier(s) '
          'for $label (no 13-mo majority, but within±$extremeMonths-mo cluster around median).',
        );
        return kept;
      }

      // Diagnostic: when we can't establish a majority window and there is no
      // obvious extreme outlier, keep everything.
      final dates = items.map(getDate).toList()..sort((a, b) => a.compareTo(b));
      final minD = dates.first;
      final maxD = dates.last;
      debugPrint(
        'StatementParserService: kept all ${items.length} items for $label (no 13-mo majority). '
        'Span ${minD.year}-${minD.month.toString().padLeft(2, "0")} '
        'to ${maxD.year}-${maxD.month.toString().padLeft(2, "0")}. '
        'bestCount=$bestCount medianCount=$medianCount minMajority=$minMajority',
      );
      return items;
    }

    final kept = <T>[];
    int dropped = 0;
    for (int i = 0; i < items.length; i++) {
      final m = months[i];
      if (m >= chosenStart && m <= chosenEnd) {
        kept.add(items[i]);
      } else {
        dropped++;
      }
    }

    if (dropped > 0) {
      DateTime toDate(int idx) {
        // idx is year*12+month where month is 1-12.
        final y = (idx - 1) ~/ 12;
        final m = ((idx - 1) % 12) + 1;
        return DateTime(y, m, 1);
      }
      final startDt = toDate(chosenStart);
      final endDt = toDate(chosenEnd);
      debugPrint(
        'StatementParserService: dropped $dropped/${items.length} date outlier(s) '
        'for $label using majority window ${startDt.year}-${startDt.month.toString().padLeft(2, "0")} '
        'to ${endDt.year}-${endDt.month.toString().padLeft(2, "0")}',
      );
    }
    return kept;
  }

  /// Public wrapper so other ingest paths (e.g., CSV uploads) can apply the same
  /// majority-window outlier filter as the PDF/text parsers.
  static List<SpendTransaction> filterSpendTransactionDateOutliers(
    List<SpendTransaction> items, {
    required String label,
  }) => _filterDateOutliers<SpendTransaction>(items, getDate: (t) => t.date, label: label);

  /// Flexible date parsing used across ingest paths.
  /// Supports ISO (YYYY-MM-DD), M/D[/YY|YYYY], and MonthName D[, YYYY].
  static DateTime? parseFlexibleDate(String input) => _parseDate(input);

  static int? _normalizeYear(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final v = int.tryParse(raw.trim());
    if (v == null) return null;
    if (v >= 0 && v <= 99) return 2000 + v;
    return v;
  }

  static DateTime _buildDate({required int mm, required int dd, required int? yyyy}) {
    final y = yyyy ?? DateTime.now().year;
    return DateTime(y, mm, dd);
  }

  /// Detects and normalizes lines that use a single repeating non-alphanumeric delimiter
  /// between fields in either of these shapes:
  ///   date <sep> merchant <sep> amount <sep?>
  ///   date <sep> date <sep> merchant <sep> amount <sep?>   -> drops the first date
  /// Returns a space-separated canonical form: "date merchant amount" if detected,
  /// otherwise returns the original line unchanged.
  static String _normalizeRepetitiveDelimitedTriplet(String line) {
    final s = line.trim();
    if (s.isEmpty) return line;
    // Must start with a date token
    final dateAtStart = RegExp(
        r'^(\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?|\d{4}-\d{2}-\d{2}|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?)',
        caseSensitive: false);
    final dm = dateAtStart.firstMatch(s);
    if (dm == null) return line;
    final after = s.substring(dm.end);
    // Find the first non-space char right after the date; use it as the candidate sep
    final nonSpaceIdx = after.indexOf(RegExp(r'\S'));
    if (nonSpaceIdx == -1) return line;
    final sepChar = after[nonSpaceIdx];
    // Only consider a non-alphanumeric single char as delimiter candidate
    if (RegExp(r'[A-Za-z0-9]').hasMatch(sepChar)) return line;
    // Ensure it repeats at least once in a row (e.g., '||' or '--' or just one is fine too)
    final sepRx = RegExp('${RegExp.escape(sepChar)}+');
    // Split by the repeating sep and trim empty parts
    final parts = s.split(sepRx).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (parts.length < 3) return line;
    // parts now are likely: [date1, maybe date2, merchant, amount, ...]
    final isDate = (String x) =>
        RegExp(r'^(\d{1,2}[\/\-]\d{1,2}(?:[\/\-]\d{2,4})?|\d{4}-\d{2}-\d{2}|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2})(?:,\s*\d{4})?)$', caseSensitive: false)
            .hasMatch(x);
    String date = parts[0];
    int descIdx = 1;
    if (parts.length >= 4 && isDate(parts[1])) {
      // Double-date: drop the first date, pick the second
      date = parts[1];
      descIdx = 2;
    }
    // Determine amount (last non-empty token)
    String amount = parts.last;
    // Guard: amount should look like an amount
    final amtLike = RegExp(r'^[-+]?\(?\$?\d{1,3}(?:,\d{3})*(?:\.\d{2})\)?$');
    if (!amtLike.hasMatch(amount)) return line; // don't transform ambiguous lines
    // Description is everything between descIdx and last-1 joined by single space
    final desc = parts.sublist(descIdx, parts.length - 1).join(' ').trim();
    if (desc.isEmpty) return line;
    return '$date $desc $amount';
  }

  static DateTime? _parseDate(String input) {
    try {
      // Try ISO first
      final iso = DateTime.tryParse(input);
      if (iso != null) return iso;
      // Try M/D/YYYY or MM/DD/YY
      final m = RegExp(r'^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2,4})').firstMatch(input);
      if (m != null) {
        final mm = int.parse(m.group(1)!);
        final dd = int.parse(m.group(2)!);
        var yy = int.parse(m.group(3)!);
        if (yy < 100) yy += 2000;
        return DateTime(yy, mm, dd);
      }
      // Try M/D without year -> assume current year
      final m2 = RegExp(r'^(\d{1,2})[\/\-](\d{1,2})$').firstMatch(input.trim());
      if (m2 != null) {
        final now = DateTime.now();
        final mm = int.parse(m2.group(1)!);
        final dd = int.parse(m2.group(2)!);
        return DateTime(now.year, mm, dd);
      }
      // Try MonthName D[, YYYY] (e.g., "Jan 1" or "January 1, 2025")
      final monRx = RegExp(
        r'^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+(\d{1,2})(?:,\s*(\d{4}))?$',
        caseSensitive: false,
      );
      final mmatch = monRx.firstMatch(input.trim());
      if (mmatch != null) {
        int _monToNum(String m) {
          final s = m.toLowerCase();
          if (s.startsWith('jan')) return 1;
          if (s.startsWith('feb')) return 2;
          if (s.startsWith('mar')) return 3;
          if (s.startsWith('apr')) return 4;
          if (s == 'may' || s.startsWith('may')) return 5;
          if (s.startsWith('jun')) return 6;
          if (s.startsWith('jul')) return 7;
          if (s.startsWith('aug')) return 8;
          if (s.startsWith('sep')) return 9;
          if (s.startsWith('oct')) return 10;
          if (s.startsWith('nov')) return 11;
          return 12; // dec
        }
        final mmStr = mmatch.group(1)!;
        final dd = int.parse(mmatch.group(2)!);
        final yy = mmatch.group(3) != null ? int.parse(mmatch.group(3)!) : DateTime.now().year;
        final mm = _monToNum(mmStr);
        return DateTime(yy, mm, dd);
      }
    } catch (e) {
      debugPrint('Date parse error: $e');
    }
    return null;
  }

  static double _parseAmount(String input) {
    var s = input.replaceAll(' ', '');
    s = s.replaceAll(' ', '');
    s = s.replaceAll(',', '').replaceAll(' ', '');
    final isNegative = s.contains('-');
    s = s.replaceAll(RegExp(r'[^0-9.]'), '');
    final v = double.tryParse(s) ?? 0;
    // Treat parentheses as negative as well: (12.34)
    if (input.contains('(') && input.contains(')')) {
      return -v;
    }
    return isNegative ? -v : v;
  }

  static String _cleanDescription(String input) {
    var s = input;
    // Replace asterisks with spaces per user request; helps matching/recognition
    s = s.replaceAll('*', ' ');
    // Remove excessive spaces and statement artifacts
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ');
    s = s.replaceAll(RegExp(r'POS\s+PURCHASE', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'ONLINE\s+PURCHASE', caseSensitive: false), '');
    return s.trim();
  }

  // ignore: unused_element
  static String _normalizeCategory(String raw) {
    final n = raw.toLowerCase().trim();
    if (_knownCategories.contains(n)) return n;
    // map variants
    if (n.contains('grocery')) return 'groceries';
    if (n.contains('restaurant') || n.contains('dining')) return 'dining';
    if (n.contains('fuel') || n == 'gas') return 'gas';
    if (n.contains('travel') || n.contains('flight') || n.contains('airfare') || n.contains('airline') || n.contains('hotel')) return 'travel';
    if (n.contains('subscription')) return 'subscriptions';
    if (n.contains('fee')) return 'fees';
    if (n.contains('utility') || n.contains('electric') || n.contains('water')) return 'utilities';
    if (n.contains('phone') || n.contains('mobile')) return 'phone';
    if (n.contains('internet') || n.contains('wifi')) return 'internet';
    if (n.contains('pharmacy')) return 'pharmacy';
    return 'uncategorized';
  }

  static bool _containsAirToken(String s) {
    if (s.isEmpty) return false;
    // "air" must be at start OR preceded by a non-alphanumeric.
    // Allows: "aircanada", " air canada"; blocks: "kauairooftoptent".
    return RegExp(r'(^|[^a-z0-9])air').hasMatch(s);
  }

  // ignore: unused_element
  static String _inferCategoryFromMerchant({required String rawDesc}) {
    final d = rawDesc.toLowerCase();
    for (final entry in _keywordToCategory.entries) {
      if (d.contains(entry.key)) return entry.value;
    }
    // Common generic words
    if (d.contains('market') || d.contains('grocery')) return 'groceries';
    if (d.contains('restaurant') || d.contains('cafe')) return 'dining';
    if (d.contains('fuel') || d.contains('gas ')) return 'gas';
    if (_containsAirToken(d) || d.contains('hotel') || d.contains('inn')) return 'travel';
    if (d.contains('uber') || d.contains('lyft')) return 'travel';
    if (d.contains('pharmacy')) return 'pharmacy';
    if (d.contains('subscription') || d.contains('monthly')) return 'subscriptions';
    if (d.contains('fitness') || d.contains('gym')) return 'fitness';
    if (d.contains('coffee')) return 'dining';
    if (d.contains('amzn') || d.contains('amazon')) return 'online';
    return 'uncategorized';
  }

  static String _extractMerchant(String rawDesc) {
    // Normalize before matching: replace '*' with spaces, preserve true hyphens,
    // but normalize dash variants to '-' for better brand matching (e.g., 7-Eleven)
    final pre = rawDesc
        .replaceAll('*', ' ')
        .replaceAll('–', '-')
        .replaceAll('—', '-')
        .replaceAll('‑', '-')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();

    // IMPORTANT (user requirement): Never overwrite the merchant name shown to
    // the user with the Merchant Master “clean merchant” label.
    //
    // The Merchant Master should only influence categorization (Level 1/2) and
    // diagnostics, not the merchant display value.

    // Heuristic: remove order/platform words and keep leading words
    var s = pre;
    s = s.replaceAll(RegExp(r'POS PURCHASE|ONLINE PURCHASE|ECOM|WEB|CARD\s+\d+', caseSensitive: false), '').trim();
    // Cut trailing city/state codes if present
    s = s.replaceAll(RegExp(r'\s+[A-Z]{2}(?:\s+USA)?$'), '').trim();
    // Keep first 3 words as merchant brand guess
    final parts = s.split(RegExp(r'\s+'));
    if (parts.isEmpty) return s;
    final guess = parts.take(3).join(' ');
    return guess;
  }

  static bool _looksLikeHeaderOrFooter(String line) {
    final l = line.toLowerCase();
    return l.contains('account number') ||
        l.contains('statement period') ||
        l.contains('page ') ||
        l.contains('summary') ||
        l.contains('opening balance') ||
        l.contains('closing balance') ||
        l.contains('total payments') ||
        l.contains('total credits') ||
        l.contains('total fees') ||
        l.contains('total interest');
  }

  // ignore: unused_element
  static bool _isPaymentOrCredit(String line) {
    final l = line.toLowerCase();
    return l.contains('payment due') ||
        l.contains('minimum payment') ||
        l.contains('autopay') ||
        l.contains('payment -') ||
        l.contains('payment received') ||
        (l.contains('thank you') && l.contains('payment')) ||
        l.contains('statement credit') ||
        l.contains('cashback') ||
        l.contains('rewards credit') ||
        l.contains('refund') ||
        l.contains('return ');
  }

  // ignore: unused_element
  static String _mapToLevel1({required String category, required String merchant, required String rawDesc}) {
    final d = (merchant.isNotEmpty ? merchant : rawDesc).toLowerCase();
    // Merchant keyword routing for finer travel splits
    bool any(List<String> keys) => keys.any((k) => d.contains(k));

    if (any(['whole foods','trader joe','kroger','safeway','aldi','grocery','market'])) return Level1Categories.groceries;
    if (any(['mcdonald','starbucks','chipotle','restaurant','cafe','eatery','pizza','ubereats','doordash','grubhub','deli','coffee'])) return Level1Categories.dining;
    if (any(['shell','chevron','exxon','bp ','fuel','gas '])) return Level1Categories.gas;
    if (any(['delta','united','american airlines','southwest','jetblue','alaska','frontier airlines','spirit airlines'])) return Level1Categories.travel;
    if (any(['marriott','hilton','hyatt','ihg','airbnb','hotel','inn','resort'])) return Level1Categories.travel;
    if (any(['avis','hertz','enterprise','alamo','national car','budget car'])) return Level1Categories.travel;
    if (any(['uber','lyft','metro','mta','bart','transit','bus','train','subway','rideshare'])) return Level1Categories.travel;
    if (any(['amazon','etsy','ebay','shopify','wayfair','shein'])) return Level1Categories.onlineRetail;
    if (any(['costco','sam\'s club','bj\'s'])) return Level1Categories.wholesale;
    if (any(['netflix','spotify','hulu','disney+','max ','paramount+','onlyfans','patreon','subscription'])) return Level1Categories.streaming;
    if (any(['cvs','walgreens','rite aid','pharmacy'])) return Level1Categories.drugstores;
    if (any(['pg&e','duke energy','coned','electric','utility','water','gas utility'])) return Level1Categories.utilities;
    if (any(['geico','progressive','allstate','state farm','insurance'])) return Level1Categories.insurance;
    if (any(['clinic','hospital','dentist','optometry','urgent care','medical','healthcare'])) return Level1Categories.healthcare;
    if (any(['walmart','target','best buy','apple','electronics','department store','general store'])) return Level1Categories.generalMerch;
    if (any(['amc','regal','theater','concert','museum','zoo','eventbrite','ticketmaster','gaming','steam','playstation','xbox'])) return Level1Categories.entertainment;
    if (any(['aws','azure','google cloud','adobe','zoom','slack','atlassian','notion','mailchimp','business'])) return Level1Categories.business;

    // Fallback by coarse category
    switch (category) {
      case 'groceries':
        return Level1Categories.groceries;
      case 'dining':
        return Level1Categories.dining;
      case 'gas':
        return Level1Categories.gas;
      case 'travel':
        if (any(['air','flight'])) return Level1Categories.travel;
        if (any(['hotel','inn','resort','airbnb'])) return Level1Categories.travel;
        if (any(['car'])) return Level1Categories.travel;
        return Level1Categories.travel;
      case 'subscriptions':
      case 'internet':
      case 'phone':
        return Level1Categories.streaming;
      case 'pharmacy':
        return Level1Categories.drugstores;
      case 'utilities':
        return Level1Categories.utilities;
      case 'insurance':
        return Level1Categories.insurance;
      case 'health':
        return Level1Categories.healthcare;
      case 'online':
      case 'electronics':
      case 'shopping':
        return Level1Categories.onlineRetail;
      default:
        return Level1Categories.other;
    }
  }
}

 
