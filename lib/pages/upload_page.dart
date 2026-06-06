import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart';
import 'package:spendiq/models/transaction.dart';
import 'package:spendiq/nav.dart';
import 'package:spendiq/theme.dart';
import 'package:file_picker/file_picker.dart';
import 'package:spendiq/components/disclaimer_banner.dart';
import 'package:spendiq/components/transaction_debug_sheet.dart';
import 'package:spendiq/services/statement_parser.dart';
import 'package:spendiq/utils/csv_saver.dart';
import 'package:spendiq/services/local_storage_service.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:spendiq/services/spend_categorizer.dart';
import 'package:spendiq/services/master_spreadsheet_service.dart';
import 'package:spendiq/components/glass_panel.dart';
import 'package:spendiq/utils/formatters.dart';
import 'package:spendiq/models/results_args.dart';
import 'package:flutter_dropzone/flutter_dropzone.dart';

class UploadPage extends StatefulWidget {
  const UploadPage({super.key});

  @override
  State<UploadPage> createState() => _UploadPageState();
}

class _CategorizedSimpleRow {
  const _CategorizedSimpleRow({
    required this.row,
    required this.level1,
    required this.level2,
    required this.level3,
    required this.special,
    required this.normalizedAmount,
    required this.isInterest,
  });
  final SimpleTransactionRow row;
  final String level1;
  final String level2;
  final String level3;
  final String special;
  /// Amount used for display/export/save. For interest charges this is forced negative.
  final double normalizedAmount;
  final bool isInterest;
}

class _UploadPageState extends State<UploadPage> {
  // Legacy parsed transactions (CSV import). Kept for backward compatibility.
  List<SpendTransaction> _transactions = [];
  // New simple parse outputs for PDF flow
  SimpleParseResult? _pdfResult;
  List<_CategorizedSimpleRow> _categorizedRows = const [];
  String? _error;
  bool _loading = false;
  bool _cancelled = false; // allow user to abort a long-running extraction
  Timer? _watchdog; // auto-timeout guard while extracting
  bool _hidePlaceholder = false; // hide "no transactions" immediately on click
  // Keep the last picked PDF bytes so we can retry with force-OCR if needed
  Uint8List? _lastPdfBytes;
  // Debounce Discover partial OCR re-parsing to avoid heavy repeated work
  Timer? _discoverPartialDebounce;
  // Processing steps UI for PDF uploads. Keep this strictly about upload/parsing
  // (analysis happens only after the user taps Analyze).
  final List<String> _steps = const [
    'Parsing statement…',
    'Saving transactions…',
    'Optimizing cards…',
  ];
  int _currentStep = -1; // -1 means idle
  int _pdfPagesDone = 0;
  int _pdfPagesTotal = 0;
  final _pasteController = TextEditingController();
  final _storage = LocalStorageService();

  // Persisted/staged transactions (across multiple statement uploads).
  List<SpendTransaction> _persistedTxs = const [];
  final Set<String> _uploadedMonthKeys = <String>{};
  // Track months uploaded in THIS session only (resets on page load)
  int _monthsUploadedThisSession = 0;

  // User-selected target coverage (this gates Analyze).
  // DEFAULT: 1 month, since each statement typically spans ~1 billing cycle.
  int _monthsInUpload = 1;
  // 0-based start index for the 12-cell month visualizer.
  // The highlighted window size follows `_monthsInUpload`.
  int _monthWindowStart = 0; // Jan (0-based)

  bool get _isDesktopUploadMode {
    // Desktop *layout* intent: wide screens + web/desktop platforms.
    final w = MediaQuery.sizeOf(context).width;
    final wide = w >= 1024;
    final desktopPlatform = !kIsWeb && (defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux);
    return wide && (kIsWeb || desktopPlatform);
  }

  String _monthKey(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

  void _recomputeMonthCoverage(List<SpendTransaction> txs) {
    _uploadedMonthKeys
      ..clear()
      ..addAll(txs.map((t) => _monthKey(t.date)));
  }

  Future<void> _loadPersistedTransactions() async {
    try {
      final raw = await _storage.readJsonList(_storage.transactionsKey);
      final txs = raw.map(SpendTransaction.fromJson).where((t) => t.id != 'invalid').toList(growable: false);
      final deduped = StatementParserService.dedupeExactTransactions(txs, label: 'load_storage');
      final sanitized = StatementParserService.sanitizeTransactions(deduped, label: 'load_storage');
      if (!mounted) return;
      setState(() {
        _persistedTxs = sanitized;
        _recomputeMonthCoverage(sanitized);
      });
    } catch (e) {
      debugPrint('UploadPage failed to load persisted transactions: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    // CRITICAL: Clear all old transactions at the start of each new session
    // to prevent math errors from stale data being mixed with new uploads.
    unawaited(_clearAndResetSession());
  }

  Future<void> _clearAndResetSession() async {
    try {
      // Wipe all persisted transactions so we start fresh
      await _storage.writeJsonList(_storage.transactionsKey, []);
      if (!mounted) return;
      setState(() {
        _persistedTxs = [];
        _uploadedMonthKeys.clear();
        _monthsUploadedThisSession = 0;
      });
    } catch (e) {
      debugPrint('Failed to clear session: $e');
    }
  }

  Future<void> _appendCategorizedRowsToLocal(List<_CategorizedSimpleRow> rows) async {
    if (rows.isEmpty) return;
    final now = DateTime.now();
    final existingRaw = await _storage.readJsonList(_storage.transactionsKey);
    final existingTxs = existingRaw.map(SpendTransaction.fromJson).where((t) => t.id != 'invalid').toList();
    final baseOrder = existingTxs.isEmpty ? 0 : ((existingTxs.map((t) => t.uploadOrder ?? 0).reduce((a, b) => a > b ? a : b)) + 1);

    final newTxs = <SpendTransaction>[];
    for (int i = 0; i < rows.length; i++) {
      final c = rows[i];
      final tx = SpendTransaction(
        id: 'imp_${now.microsecondsSinceEpoch}_$i',
        date: c.row.date,
        description: c.row.sourceLine,
        merchant: c.row.merchant,
        category: c.level1,
        subcategory: c.level2,
        brand: c.level3,
        special: c.special,
        amount: c.normalizedAmount,
        uploadOrder: baseOrder + i,
        createdAt: now,
        updatedAt: now,
      );
      newTxs.add(StatementParserService.applyNonNegotiableOverrides(tx));
    }

    final filteredNew = StatementParserService.sanitizeTransactions(newTxs, label: 'append_new');
    final merged = [...existingTxs, ...filteredNew];
    final deduped = StatementParserService.dedupeExactTransactions(merged, label: 'append_merged');
    final sanitized = StatementParserService.sanitizeTransactions(deduped, label: 'append_merged');
    await _storage.writeJsonList(_storage.transactionsKey, sanitized.map((t) => t.toJson()).toList(growable: false));

    if (!mounted) return;
    setState(() {
      _persistedTxs = sanitized;
      _recomputeMonthCoverage(sanitized);
    });
  }

  bool get _isUploadComplete {
    final required = _monthsInUpload.clamp(1, 12);
    // Only consider uploads from THIS session, not old persisted data
    final complete = _monthsUploadedThisSession >= required;
    debugPrint('Upload complete check: $_monthsUploadedThisSession/$required months (this session) = $complete');
    return complete;
  }

  void _analyze() async {
    setState(() {
      _loading = true;
      _currentStep = 2; // "Optimizing cards…" is step index 2
    });
    // Show "Optimizing cards..." briefly so user sees the loading state
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    final txs = [..._persistedTxs];
    txs.sort((a, b) => (a.uploadOrder ?? 0).compareTo(b.uploadOrder ?? 0));
    final forResults = StatementParserService.dedupeExactTransactions(txs, label: 'results_nav');
    if (mounted) {
      setState(() {
        _loading = false;
        _currentStep = -1;
      });
      context.go(AppRoutes.results, extra: ResultsArgs(transactions: forResults, monthsInUpload: _monthsInUpload));
    }
  }

  bool _isMonthActive(int monthIndex) {
    final len = _monthsInUpload.clamp(1, 12);
    if (len == 12) return true;
    final normalized = monthIndex % 12;
    final start = _monthWindowStart % 12;
    final endExclusive = (start + len) % 12;
    if (start < endExclusive) return normalized >= start && normalized < endExclusive;
    // Wraps around Dec -> Jan
    return normalized >= start || normalized < endExclusive;
  }

  void _openTxDebugSheet(SpendTransaction tx) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => TransactionDebugSheet(tx: tx),
    );
  }

  void _applyPdfResult(SimpleParseResult? result) {
    _pdfResult = result;
    if (result == null || result.rows.isEmpty) {
      _categorizedRows = const [];
      return;
    }
    // Performance: categorization can be non-trivial (merchant cleaning, matching, rules).
    // Precompute once per parse so we don't redo it on every build/scroll/export.
    _categorizedRows = result.rows.map(_categorizeSimpleRow).toList(growable: false);
  }

  SimpleParseResult _mergeSimpleParseResults(SimpleParseResult? a, SimpleParseResult b) {
    if (a == null) return b;
    return SimpleParseResult(
      rawText: '${a.rawText}\n\n---\n\n${b.rawText}',
      rows: [...a.rows, ...b.rows],
      unparsedLines: [...a.unparsedLines, ...b.unparsedLines],
    );
  }

  _CategorizedSimpleRow _categorizeSimpleRow(SimpleTransactionRow r) {
    // Categorization is master-sheet-driven. Overrides like Interest and ToastTab
    // must be applied consistently everywhere (preview table, debug sheet, saved txs).
    final cat = SpendCategorizer.categorize(merchant: r.merchant, description: r.sourceLine);
    final now = DateTime.now();
    final base = SpendTransaction(
      id: 'preview_${now.microsecondsSinceEpoch}',
      date: r.date,
      description: r.sourceLine,
      merchant: r.merchant,
      category: cat.level1,
      subcategory: cat.level2,
      brand: cat.level3,
      special: cat.special,
      amount: r.amount,
      createdAt: now,
      updatedAt: now,
    );

    final overridden = StatementParserService.applyNonNegotiableOverrides(base);
    final normalizedAmount = overridden.amount;
    final isInterest = overridden.category.trim().toLowerCase() == 'interest';
    return _CategorizedSimpleRow(
      row: r,
      level1: overridden.category,
      level2: (overridden.subcategory ?? '').trim().isEmpty ? 'Other' : overridden.subcategory!.trim(),
      level3: (overridden.brand ?? '').trim(),
      special: (overridden.special ?? '').trim(),
      normalizedAmount: normalizedAmount,
      isInterest: isInterest,
    );
  }

  // Fast byte-level brand sniff: look for clear Discover markers directly in PDF bytes
  bool _pdfBytesLikelyDiscover(Uint8List data) {
    try {
      // Decode as ASCII with invalids allowed; we're only looking for plain words
      final s = ascii.decode(data, allowInvalid: true).toLowerCase();
      if (!s.contains('discover')) return false;
      return s.contains('discover it') ||
          s.contains('discover card') ||
          s.contains('discover bank') ||
          s.contains('discover.com') ||
          s.contains('cashback bonus') ||
          s.contains('cash back bonus');
    } catch (_) {
      return false;
    }
  }

  // Content-level brand sniff: quickly read only the first page and
  // check for the literal phrase "Discover it" so users can upload with any filename.
  Future<bool> _firstPageMentionsDiscoverIt(Uint8List data) async {
    try {
      final doc = PdfDocument(inputBytes: data);
      final extractor = PdfTextExtractor(doc);
      final pageText = extractor.extractText(startPageIndex: 0, endPageIndex: 0, layoutText: false);
      doc.dispose();
      return pageText.toLowerCase().contains('discover it');
    } catch (_) {
      return false;
    }
  }

  Future<void> _saveParsedToLocal({bool andAnalyze = false}) async {
    final r = _pdfResult;
    if (r == null || r.rows.isEmpty) {
      final cs = Theme.of(context).colorScheme;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Nothing to save'), backgroundColor: cs.error));
      return;
    }
    try {
      final now = DateTime.now();
      final txs = <SpendTransaction>[];
      int i = 0;
      final rows = _categorizedRows.isNotEmpty
          ? _categorizedRows
          : r.rows.map((row) {
              return _categorizeSimpleRow(row);
            }).toList(growable: false);
      final existingRaw = await _storage.readJsonList(_storage.transactionsKey);
      final existingTxs = existingRaw.map(SpendTransaction.fromJson).where((t) => t.id != 'invalid').toList(growable: false);
      final baseOrder = existingTxs.isEmpty ? 0 : ((existingTxs.map((t) => t.uploadOrder ?? 0).reduce((a, b) => a > b ? a : b)) + 1);

      for (final c in rows) {
        // IMPORTANT: interest override must be applied AFTER categorization,
        // so we construct the transaction first, then sanitize.
        final tx = SpendTransaction(
          id: 'imp_${now.millisecondsSinceEpoch}_$i',
          date: c.row.date,
          description: c.row.sourceLine,
          merchant: c.row.merchant,
          category: c.level1,
          subcategory: c.level2,
          brand: c.level3,
          special: c.special,
          amount: c.normalizedAmount,
          uploadOrder: baseOrder + i,
          createdAt: now,
          updatedAt: now,
        );
        txs.add(StatementParserService.applyNonNegotiableOverrides(tx));
        i++;
      }

      // Safety: apply the same 13-month majority-window filter again at the
      // final pre-save stage. This ensures that even if a row slipped past earlier
      // parsing, it won't be persisted or used in analysis.
      final filteredTxs = StatementParserService.sanitizeTransactions(txs, label: 'save_parsed');

      // Merge with existing storage, then re-sanitize the FULL set. This is
      // critical because previously-saved outliers (e.g. a stray 2019) would
      // otherwise persist forever.
      final mergedTxs = [...existingTxs, ...filteredTxs];
      // Prevent repeated imports/saves from stacking identical transactions.
      final dedupedMerged = StatementParserService.dedupeExactTransactions(mergedTxs, label: 'merged_storage');
      final sanitizedMerged = StatementParserService.sanitizeTransactions(dedupedMerged, label: 'merged_storage');
      await _storage.writeJsonList(_storage.transactionsKey, sanitizedMerged.map((t) => t.toJson()).toList(growable: false));
      if (andAnalyze) {
        // Ensure analysis preserves the exact upload order.
        sanitizedMerged.sort((a, b) => (a.uploadOrder ?? 0).compareTo(b.uploadOrder ?? 0));
        // Extra safety: results should not show duplicates even if storage
        // already contained them.
        final forResults = StatementParserService.dedupeExactTransactions(sanitizedMerged, label: 'results_nav');
        if (mounted) context.go(AppRoutes.results, extra: ResultsArgs(transactions: forResults, monthsInUpload: _monthsInUpload));
      } else {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Transactions saved')));
      }
    } catch (e) {
      debugPrint('Save parsed error: $e');
      if (!mounted) return;
      final cs = Theme.of(context).colorScheme;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to save: $e'), backgroundColor: cs.error));
    }
  }

  Future<void> _pickCsv() async {
    setState(() {
      _loading = true;
      _currentStep = 1; // "Saving transactions..."
    });
    try {
      // Load master spreadsheet with timeout protection for production
      try {
        await MasterSpreadsheetService.ensureLoaded()
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('CSV master_spreadsheet_timeout: $e');
        // Continue anyway - the service has fallback behavior
      }
      final result = await FilePicker.platform.pickFiles(
          type: FileType.any, withData: true, allowMultiple: false);
      if (result == null || result.files.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No file selected')),
          );
        }
        return;
      }
      
      final file = result.files.first;
      
      // Validate extension
      if (!file.name.toLowerCase().endsWith('.csv')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please select a CSV file'), backgroundColor: Colors.red),
          );
        }
        return;
      }
      
      final bytes = file.bytes;
      if (bytes == null) throw 'No file data available';
      _lastPdfBytes = bytes;
      
      final content = utf8.decode(bytes);
      final parsed = _parseCsv(content);
      
      // CSV uploads follow the same flow as PDFs: append to storage, show in preview
      final now = DateTime.now();
      final existingRaw = await _storage.readJsonList(_storage.transactionsKey);
      final existingTxs = existingRaw.map(SpendTransaction.fromJson).where((t) => t.id != 'invalid').toList();
      final baseOrder = existingTxs.isEmpty ? 0 : ((existingTxs.map((t) => t.uploadOrder ?? 0).reduce((a, b) => a > b ? a : b)) + 1);
      
      // Re-assign upload order and IDs
      final newTxs = <SpendTransaction>[];
      for (int i = 0; i < parsed.length; i++) {
        final t = parsed[i];
        newTxs.add(t.copyWith(
          id: 'csv_${now.microsecondsSinceEpoch}_$i',
          uploadOrder: baseOrder + i,
        ));
      }
      
      final merged = [...existingTxs, ...newTxs];
      final deduped = StatementParserService.dedupeExactTransactions(merged, label: 'csv_upload');
      final sanitized = StatementParserService.sanitizeTransactions(deduped, label: 'csv_upload');
      await _storage.writeJsonList(_storage.transactionsKey, sanitized.map((t) => t.toJson()).toList(growable: false));
      
      if (!mounted) return;
      
      // Track session upload (CSV counts as 1 month)
      if (newTxs.isNotEmpty) {
        _monthsUploadedThisSession++;
        debugPrint('Session upload count (CSV): $_monthsUploadedThisSession');
      }
      
      setState(() {
        _persistedTxs = sanitized;
        _recomputeMonthCoverage(sanitized);
        _transactions = [];
        _pdfResult = null;
        _categorizedRows = const [];
        _error = null;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CSV imported: ${newTxs.length} transactions saved')),
      );
    } catch (e) {
      setState(() => _error = 'Failed to import CSV: $e');
    } finally {
      setState(() {
        _loading = false;
        _currentStep = -1;
      });
    }
  }

  // ignore: unused_element
  Future<void> _pickTxt() async {
    setState(() => _loading = true);
    try {
      // Load master spreadsheet with timeout protection for production
      try {
        await MasterSpreadsheetService.ensureLoaded()
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('TXT master_spreadsheet_timeout: $e');
        // Continue anyway - the service has fallback behavior
      }
      final result = await FilePicker.platform.pickFiles(
          type: FileType.any, withData: true);
      if (result == null || result.files.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No file selected')),
          );
        }
        return;
      }
      
      final file = result.files.first;
      
      // Validate extension
      if (!file.name.toLowerCase().endsWith('.txt')) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please select a TXT file'), backgroundColor: Colors.red),
          );
        }
        return;
      }
      
      final bytes = file.bytes;
      if (bytes == null) throw 'No file data available';
      final content = utf8.decode(bytes);
      final parsed =
          await StatementParserService.extractSimpleFromText(content);
      setState(() {
        _applyPdfResult(parsed);
        _transactions = [];
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'Failed to import text: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  // ignore: unused_element
  Future<void> _pasteText() async {
    _pasteController.clear();
    final cs = Theme.of(context).colorScheme;
    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Paste statement text'),
          content: SizedBox(
            width: 600,
            child: TextField(
              controller: _pasteController,
              maxLines: 16,
              decoration: const InputDecoration(
                hintText: 'Paste raw text extracted from your statement here…',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => context.pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () async {
                final text = _pasteController.text.trim();
                if (text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: const Text('Nothing to parse'),
                        backgroundColor: cs.error),
                  );
                  return;
                }
                context.pop();
                setState(() => _loading = true);
                try {
                  // Load master spreadsheet with timeout protection for production
                  try {
                    await MasterSpreadsheetService.ensureLoaded()
                        .timeout(const Duration(seconds: 10));
                  } catch (e) {
                    debugPrint('Paste master_spreadsheet_timeout: $e');
                    // Continue anyway - the service has fallback behavior
                  }
                  final parsed =
                      await StatementParserService.extractSimpleFromText(text);
                  setState(() {
                    _applyPdfResult(parsed);
                    _transactions = [];
                    _error = null;
                  });
                } catch (e) {
                  setState(() => _error = 'Failed to parse pasted text: $e');
                } finally {
                  setState(() => _loading = false);
                }
              },
              icon: const Icon(Icons.playlist_add_check),
              label: const Text('Parse'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _pickPdf() async {
    try {
      // Immediately hide the placeholder to avoid confusion while picker is open
      if (mounted) setState(() => _hidePlaceholder = true);

      // Let the user pick a file first without showing the spinner yet.
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
        // Desktop (wide) supports selecting multiple PDFs at once.
        allowMultiple: _isDesktopUploadMode,
      );
      
      debugPrint('UPLOADTRACE file_picker_result: result=${result != null} files=${result?.files.length ?? 0}');
      
      if (result == null || result.files.isEmpty) {
        // User canceled: restore placeholder state if nothing to show
        debugPrint('UPLOADTRACE file_picker_cancelled or no files');
        if (mounted) {
          setState(() => _hidePlaceholder = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No file selected')),
          );
        }
        return; // No selection; keep existing UI as-is.
      }
      
      // Validate all files are PDFs
      final invalidFiles = result.files.where((f) => !f.name.toLowerCase().endsWith('.pdf')).toList();
      if (invalidFiles.isNotEmpty) {
        debugPrint('UPLOADTRACE invalid file types detected');
        if (mounted) {
          setState(() => _hidePlaceholder = false);
          final cs = Theme.of(context).colorScheme;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('❌ PDF Required', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(height: 4),
                  Text('Please upload a PDF credit card statement. Browser-saved files may not work.', style: TextStyle(color: Colors.white)),
                  const SizedBox(height: 4),
                  Text('💡 Tip: Save to Files app first', style: TextStyle(fontSize: 12, color: Colors.white70)),
                ],
              ),
              backgroundColor: cs.error,
              duration: const Duration(seconds: 5),
            ),
          );
        }
        return;
      }
      
      // Log file details for debugging
      for (var i = 0; i < result.files.length; i++) {
        final f = result.files[i];
        debugPrint('UPLOADTRACE file[$i]: name=${f.name} size=${f.size} hasBytes=${f.bytes != null} bytesLength=${f.bytes?.length ?? 0}');
      }
      
      final picked = result.files.where((f) => f.bytes != null).toList(growable: false);
      if (picked.isEmpty) {
        debugPrint('UPLOADTRACE no files with bytes data');
        if (mounted) {
          setState(() => _hidePlaceholder = false);
          final cs = Theme.of(context).colorScheme;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('⚠️ File Access Error', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                  const SizedBox(height: 4),
                  Text('Cannot read the selected file. This often happens with browser-saved PDFs.', style: TextStyle(color: Colors.white)),
                  const SizedBox(height: 4),
                  Text('💡 Try: Download statement → Save to Files → Upload from Files', style: TextStyle(fontSize: 12, color: Colors.white70)),
                ],
              ),
              backgroundColor: cs.error,
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return;
      }
      
      debugPrint('UPLOADTRACE picked ${picked.length} files with data');

      // Show loading FIRST so user sees something is happening
      if (mounted) {
        setState(() {
          _loading = true;
          _cancelled = false;
          _error = null;
          _currentStep = 0;
          _pdfPagesDone = 0;
          _pdfPagesTotal = 0;
        });
      }

      // Load master spreadsheet with timeout protection for production
      try {
        await MasterSpreadsheetService.ensureLoaded()
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('UPLOADTRACE master_spreadsheet_timeout: $e');
        // Continue anyway - the service has fallback behavior
      }
      SimpleParseResult? merged;

      for (var idx = 0; idx < picked.length; idx++) {
        if (_cancelled) break;
        final file = picked[idx];
        final bytes = file.bytes!;
        final isLastFile = idx == picked.length - 1;

        final traceId = StatementParserService.debugTraceIdForPdfBytes(bytes);
        debugPrint(
          'PDFTRACE[$traceId] upload:start platform=${kIsWeb ? "web" : "native"} file=${file.name} bytes=${bytes.lengthInBytes} masterSource=${MasterSpreadsheetService.lastMasterSource} multi=${picked.length}',
        );
        // Keep a copy for potential high-DPI OCR retry button
        _lastPdfBytes = bytes;

        // Start a watchdog to avoid indefinite spinner in case extraction hangs
        _watchdog?.cancel();
        _watchdog = Timer(const Duration(seconds: 75), () {
          if (!mounted) return;
          if (_loading && !_cancelled) {
            setState(() {
              _error = 'Extraction is taking too long. Please try again or use the sample PDF.';
              _loading = false;
              _currentStep = -1;
              _pdfPagesDone = 0;
              _pdfPagesTotal = 0;
            });
          }
        });
        // Give the UI a chance to paint the spinner before heavy parsing begins
        try {
          await Future<void>.delayed(Duration.zero);
          await WidgetsBinding.instance.endOfFrame;
        } catch (_) {}

        // Timing probes for investigating browser stalls (observational only).
        final parseStopwatch = Stopwatch()..start();
        int? lastProgressMs;
        int lastDone = -1;
        int lastTotal = -1;
        // STEP 1 — Extracting transaction data…
        // For Discover statements on Web: run REAL OCR (raster-only) immediately and skip artificial waits.
        final isDiscoverByBytes = _pdfBytesLikelyDiscover(bytes);
        // NOTE: Content-based detection can be expensive on web (it may need to
        // open/decode the PDF just to peek at page 1). Only do it when we already
        // strongly suspect Discover by bytes, and never let it block uploads.
        bool isDiscoverByContent = false;
        if (kIsWeb && isDiscoverByBytes) {
          try {
            isDiscoverByContent = await _firstPageMentionsDiscoverIt(bytes).timeout(
              const Duration(milliseconds: 250),
              onTimeout: () => false,
            );
          } catch (_) {
            isDiscoverByContent = false;
          }
        }
        // IMPORTANT: do NOT use filename heuristics for brand detection.
        // Users may upload any PDF name.
        final isDiscover = (isDiscoverByBytes || isDiscoverByContent);

        // Give Discover uploads more time since they commonly require OCR.
        if (isDiscover) {
          try {
            _watchdog?.cancel();
          } catch (_) {}
          _watchdog = Timer(const Duration(minutes: 4), () {
            if (!mounted) return;
            if (_loading && !_cancelled) {
              setState(() {
                _error = 'Extraction is taking unusually long. Please try again or reduce file size.';
                _loading = false;
                _currentStep = -1;
                _pdfPagesDone = 0;
                _pdfPagesTotal = 0;
              });
            }
          });
        }

        final parsed = await StatementParserService.extractSimpleFromBytesWithProgress(
          bytes,
          onPageProgress: (done, total) {
            if (!mounted) return;

            final nowMs = parseStopwatch.elapsedMilliseconds;
            if (lastProgressMs != null) {
              final gap = nowMs - lastProgressMs!;
              if (gap >= 1500) {
                debugPrint('UPLOADTRACE pdf_progress_gap_ms=$gap done=$lastDone/$lastTotal -> $done/$total elapsedMs=$nowMs');
              }
            } else {
              debugPrint('UPLOADTRACE pdf_progress_first done=$done/$total elapsedMs=$nowMs');
            }
            lastProgressMs = nowMs;
            lastDone = done;
            lastTotal = total;

            setState(() {
              _pdfPagesDone = done;
              _pdfPagesTotal = total;
              _currentStep = 0;
            });
          },
          onPartialResult: (partial) {
            if (!mounted || _cancelled) return;
            if (partial.rawText.isEmpty && partial.rows.isEmpty) return;

            debugPrint(
              'UPLOADTRACE partial_result elapsedMs=${parseStopwatch.elapsedMilliseconds} rawLen=${partial.rawText.length} rows=${partial.rows.length} unparsed=${partial.unparsedLines.length}',
            );

            setState(() {
              _applyPdfResult(partial);
              _transactions = [];
            });
          },
        );

        debugPrint(
          'UPLOADTRACE extract_complete elapsedMs=${parseStopwatch.elapsedMilliseconds} rawLen=${parsed.rawText.length} rows=${parsed.rows.length} unparsed=${parsed.unparsedLines.length}',
        );
        
        // DEBUG: Show first 500 chars of extracted text when we get zero rows
        if (parsed.rows.isEmpty && parsed.rawText.isNotEmpty) {
          final sample = parsed.rawText.substring(0, parsed.rawText.length > 500 ? 500 : parsed.rawText.length);
          debugPrint('UPLOADTRACE zero_rows_debug: First 500 chars of extracted text:\n$sample');
        }

        // OCR FALLBACK (post-pass):
        // Keep the normal extraction fast for standard uploads.
        // Only if we got **zero rows**, run an OCR-only pass.
        //
        // Rationale:
        // - Some PDFs (commonly Discover) produce plenty of extracted text, but
        //   the transaction rows are unreadable / missing from the text layer.
        // - The user verified that “Force OCR 400” fixes these.
        // - We only pay the OCR cost on failures (0 rows) so normal uploads stay fast.
        SimpleParseResult finalParsed = parsed;
        final shouldAutoOcrFallback = mounted && !_cancelled && kIsWeb && parsed.rows.isEmpty;
        if (shouldAutoOcrFallback) {
          debugPrint(
            'UPLOADTRACE auto_ocr_fallback_trigger elapsedMs=${parseStopwatch.elapsedMilliseconds} reason=zero_rows',
          );
          try {
            // Extend watchdog for the fallback OCR pass only.
            _watchdog?.cancel();
            _watchdog = Timer(const Duration(minutes: 4), () {
              if (!mounted) return;
              if (_loading && !_cancelled) {
                setState(() {
                  _error = 'OCR fallback is taking too long. Please try again.';
                  _loading = false;
                  _currentStep = -1;
                  _pdfPagesDone = 0;
                  _pdfPagesTotal = 0;
                });
              }
            });

            finalParsed = await StatementParserService.extractSimpleForceOcrFromBytesWithProgress(
              bytes,
              // Match the known-good “Force OCR 400” recovery path.
              dpi: 400,
              onPageProgress: (done, total) {
                if (!mounted) return;
                setState(() {
                  _pdfPagesDone = done;
                  _pdfPagesTotal = total;
                  _currentStep = 0;
                });
              },
            onPartialResult: (partial) {
              if (!mounted || _cancelled) return;
              if (partial.rawText.isEmpty && partial.rows.isEmpty) return;
              debugPrint(
                'UPLOADTRACE auto_ocr_fallback_partial elapsedMs=${parseStopwatch.elapsedMilliseconds} rawLen=${partial.rawText.length} rows=${partial.rows.length}',
              );
              setState(() {
                _applyPdfResult(partial);
                _transactions = [];
              });
            },
          );

          debugPrint(
            'UPLOADTRACE auto_ocr_fallback_complete elapsedMs=${parseStopwatch.elapsedMilliseconds} rawLen=${finalParsed.rawText.length} rows=${finalParsed.rows.length}',
          );
        } catch (e) {
          debugPrint('UPLOADTRACE auto_ocr_fallback_failed err=$e');
        }
      }

        merged = _mergeSimpleParseResults(merged, finalParsed);

        // Save each statement as it completes so the user sees month progress grow.
        if (mounted && !_cancelled) {
          setState(() => _currentStep = 1);
        }
        final categorized = finalParsed.rows.map(_categorizeSimpleRow).toList(growable: false);
        await _appendCategorizedRowsToLocal(categorized);
        
        // Track that we uploaded a statement in this session
        if (categorized.isNotEmpty) {
          _monthsUploadedThisSession++;
          debugPrint('Session upload count: $_monthsUploadedThisSession');
        }

        if (mounted && !_cancelled) {
          setState(() {
            _applyPdfResult(merged);
            _transactions = [];
          });
        }

        // If multiple PDFs were selected, return to extracting for the next file.
        if (!isLastFile && mounted && !_cancelled) {
          setState(() => _currentStep = 0);
        }
      }
      // Do not set a "no transactions found" error — user requested to remove it after upload
    } catch (e, stackTrace) {
      debugPrint('UPLOADTRACE PDF upload failed: $e');
      debugPrint('UPLOADTRACE Stack trace: $stackTrace');
      if (mounted) {
        setState(() => _error = 'Failed to import PDF: $e\n\nIf this persists, try refreshing the page.');
      }
    } finally {
      _watchdog?.cancel();
      if (mounted) {
        setState(() {
          _loading = false;
          _currentStep = -1;
          _pdfPagesDone = 0;
          _pdfPagesTotal = 0;
          // Keep placeholder hidden if we actually produced any result; otherwise restore it
          // We keep placeholder hidden if we have any raw OCR or rows
          _hidePlaceholder = _pdfResult != null &&
              (_pdfResult!.rows.isNotEmpty || _pdfResult!.rawText.isNotEmpty);
        });
      }
    }
  }

  Future<void> _importPdfBytesBatch(List<_NamedBytes> files) async {
    if (files.isEmpty) return;
    try {
      if (mounted) setState(() => _hidePlaceholder = true);
      await MasterSpreadsheetService.ensureLoaded();

      if (mounted) {
        setState(() {
          _loading = true;
          _cancelled = false;
          _error = null;
          _currentStep = 0;
          _pdfPagesDone = 0;
          _pdfPagesTotal = 0;
        });
      }

      SimpleParseResult? merged;

      for (int idx = 0; idx < files.length; idx++) {
        if (_cancelled) break;
        final f = files[idx];
        final bytes = f.bytes;
        final isLastFile = idx == files.length - 1;

        _lastPdfBytes = bytes;
        _watchdog?.cancel();
        _watchdog = Timer(const Duration(seconds: 75), () {
          if (!mounted) return;
          if (_loading && !_cancelled) {
            setState(() {
              _error = 'Extraction is taking too long. Please try again.';
              _loading = false;
              _currentStep = -1;
              _pdfPagesDone = 0;
              _pdfPagesTotal = 0;
            });
          }
        });

        final parsed = await StatementParserService.extractSimpleFromBytesWithProgress(
          bytes,
          onPageProgress: (done, total) {
            if (!mounted) return;
            setState(() {
              _pdfPagesDone = done;
              _pdfPagesTotal = total;
              _currentStep = 0;
            });
          },
          onPartialResult: (partial) {
            if (!mounted || _cancelled) return;
            if (partial.rawText.isEmpty && partial.rows.isEmpty) return;
            setState(() {
              _applyPdfResult(partial);
              _transactions = [];
            });
          },
        );

        SimpleParseResult finalParsed = parsed;
        if (mounted && !_cancelled && kIsWeb && parsed.rows.isEmpty) {
          try {
            _watchdog?.cancel();
            _watchdog = Timer(const Duration(minutes: 4), () {
              if (!mounted) return;
              if (_loading && !_cancelled) {
                setState(() {
                  _error = 'OCR fallback is taking too long. Please try again.';
                  _loading = false;
                  _currentStep = -1;
                  _pdfPagesDone = 0;
                  _pdfPagesTotal = 0;
                });
              }
            });

            finalParsed = await StatementParserService.extractSimpleForceOcrFromBytesWithProgress(
              bytes,
              dpi: 400,
              onPageProgress: (done, total) {
                if (!mounted) return;
                setState(() {
                  _pdfPagesDone = done;
                  _pdfPagesTotal = total;
                  _currentStep = 0;
                });
              },
              onPartialResult: (partial) {
                if (!mounted || _cancelled) return;
                if (partial.rawText.isEmpty && partial.rows.isEmpty) return;
                setState(() {
                  _applyPdfResult(partial);
                  _transactions = [];
                });
              },
            );
          } catch (e) {
            debugPrint('UploadPage OCR fallback failed for ${f.name}: $e');
          }
        }

        merged = _mergeSimpleParseResults(merged, finalParsed);
        if (mounted && !_cancelled) {
          setState(() {
            _applyPdfResult(merged);
            _transactions = [];
            _currentStep = 1;
          });
        }

        final categorized = finalParsed.rows.map(_categorizeSimpleRow).toList(growable: false);
        await _appendCategorizedRowsToLocal(categorized);
        
        // Track session upload
        if (categorized.isNotEmpty) {
          _monthsUploadedThisSession++;
          debugPrint('Session upload count: $_monthsUploadedThisSession');
        }

        if (!isLastFile && mounted && !_cancelled) {
          setState(() => _currentStep = 0);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Failed to import PDF: $e');
    } finally {
      _watchdog?.cancel();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _currentStep = -1;
        _pdfPagesDone = 0;
        _pdfPagesTotal = 0;
        _hidePlaceholder = _pdfResult != null && (_pdfResult!.rows.isNotEmpty || _pdfResult!.rawText.isNotEmpty);
      });
    }
  }

  Future<void> _forceOcr400() async {
    if (!kIsWeb) return; // web-only
    final data = _lastPdfBytes;
    if (data == null) return;
    try {
      setState(() {
        _loading = true;
        _error = null;
        _currentStep = 0;
        _pdfPagesDone = 0;
        _pdfPagesTotal = 0;
      });
      // Extend watchdog because 400 DPI can be slower
      _watchdog?.cancel();
      _watchdog = Timer(const Duration(minutes: 5), () {
        if (!mounted) return;
        if (_loading) {
          setState(() {
            _error =
                'Forced OCR timed out. Try a smaller PDF or different file.';
            _loading = false;
            _currentStep = -1;
          });
        }
      });

      final raw = await StatementParserService.extractRawOcrOnlyFromPdfWeb(
        data,
        dpi: 400,
        onPageProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _pdfPagesDone = done;
            _pdfPagesTotal = total;
            _currentStep = 0;
          });
        },
        onPartialText: (partial) async {
          if (!mounted) return;
          try {
            final parsed =
                await StatementParserService.extractSimpleFromText(partial);
            if (!mounted) return;
            setState(() {
              _applyPdfResult(SimpleParseResult(
                rawText: partial,
                rows: parsed.rows,
                unparsedLines: parsed.unparsedLines,
              ));
              _transactions = [];
            });
          } catch (_) {
            setState(() {
              _applyPdfResult(SimpleParseResult(rawText: partial, rows: const [], unparsedLines: const []));
              _transactions = [];
            });
          }
        },
      );
      // Final parse after full OCR completes
      final parsed = await StatementParserService.extractSimpleFromText(raw);
      if (!mounted) return;
      setState(() {
        _applyPdfResult(SimpleParseResult(
          rawText: raw,
          rows: parsed.rows,
          unparsedLines: parsed.unparsedLines,
        ));
        _transactions = [];
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Force OCR failed: $e');
    } finally {
      _watchdog?.cancel();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _currentStep = -1;
      });
    }
  }

  // ignore: unused_element
  Future<void> _loadSamplePdf() async {
    try {
      const assetPath =
          'assets/documents/DFE21D55-1E65-44E7-817E-58E0388BFA75-list.pdf';
      final bytes = await DefaultAssetBundle.of(context).load(assetPath);
      if (mounted) {
        setState(() {
          _loading = true;
          _error = null;
          _currentStep = 0;
          _pdfPagesDone = 0;
          _pdfPagesTotal = 0;
        });
      }
      // STEP 1 — Extracting transaction data…
      final data = bytes.buffer.asUint8List();
      // UNIFIED: Same extraction path for both web and native
      final parsed = await StatementParserService.extractSimpleFromBytesWithProgress(
        data,
        onPageProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _pdfPagesDone = done;
            _pdfPagesTotal = total;
          });
        },
        onPartialResult: (partial) {
          if (!mounted) return;
          if (partial.rawText.isEmpty && partial.rows.isEmpty) return;
          setState(() {
            _applyPdfResult(partial);
            _transactions = [];
          });
        },
      );
      if (mounted) {
        setState(() {
          _applyPdfResult(parsed);
          _transactions = [];
        });
      }
      // STEP 2 — Standardizing transaction names… (placeholder)
      if (mounted) setState(() => _currentStep = 1);
      await Future.delayed(const Duration(milliseconds: 250));
      // STEP 3 — Running OptimIQ simulation… (placeholder)
      if (mounted) setState(() => _currentStep = 2);
      await Future.delayed(const Duration(milliseconds: 250));
      // STEP 4 — Finalizing recommendations…
      if (mounted) setState(() => _currentStep = 3);
      await Future.delayed(const Duration(milliseconds: 250));
    } catch (e) {
      setState(() => _error = 'Failed to read sample PDF: $e');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _currentStep = -1;
          _pdfPagesDone = 0;
          _pdfPagesTotal = 0;
        });
      }
    }
  }

  String _buildCsv() {
    final r = _pdfResult;
    if (r == null) return '';
    final buf = StringBuffer('Date,Merchant,Amount,Level 1,Level 2,Level 3,Special Logic\n');
    final rows = _categorizedRows.isNotEmpty
        ? _categorizedRows
        : r.rows.map((row) {
            return _categorizeSimpleRow(row);
          }).toList(growable: false);
    for (final c in rows) {
      final row = c.row;
      final d = '${row.date.month.toString().padLeft(2, '0')}/${row.date.day.toString().padLeft(2, '0')}/${row.date.year}';
      final m = row.merchant.replaceAll('"', '""');
      final a = Formatters.fixed(c.normalizedAmount, decimals: 2);
      buf.writeln('$d,"$m",$a,"${c.level1}","${c.level2}","${c.level3}","${c.special}"');
    }
    return buf.toString();
  }

  List<SpendTransaction> _parseCsv(String content) {
    final lines = const LineSplitter()
        .convert(content)
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return [];
    // Expect headers: date,description,category,amount
    final now = DateTime.now();
    final txs = <SpendTransaction>[];
    for (int i = 1; i < lines.length; i++) {
      final row = _splitCsvLine(lines[i]);
      if (row.length < 4) continue;
      // Users often provide dates like "2/19/2019"; DateTime.tryParse only
      // supports ISO, which would incorrectly fall back to `now` and prevent the
      // outlier filter from catching far-off transactions.
      final date = StatementParserService.parseFlexibleDate(row[0]) ?? DateTime.tryParse(row[0]) ?? now;
      final desc = row[1];
      final cat = row[2].toLowerCase().trim();
      final parsedAmt = double.tryParse(row[3].replaceAll(",", "")) ?? 0;
      final amt = StatementParserService.isInterestText(desc) ? -parsedAmt.abs() : parsedAmt;
      final guess = SpendCategorizer.categorize(merchant: desc, description: desc);
      final tx = SpendTransaction(
        id: 't_$i',
        date: date,
        description: desc,
        merchant: desc,
        category: cat.isEmpty ? guess.level1 : cat,
        subcategory: guess.level2,
        brand: guess.level3,
        special: guess.special,
        amount: amt,
        uploadOrder: i - 1,
        createdAt: now,
        updatedAt: now,
      );
      // IMPORTANT: apply the same override pipeline used for PDFs so:
      // - Exclude rows force negative amounts (using absolute value)
      // - ToastTab / Interest overrides apply consistently
      txs.add(StatementParserService.applyNonNegotiableOverrides(tx));
    }

    // Apply the same 13-month majority-window outlier drop that we use for PDFs.
    return StatementParserService.filterSpendTransactionDateOutliers(txs, label: 'csv_upload');
  }

  List<String> _splitCsvLine(String line) {
    final result = <String>[];
    final buffer = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ',' && !inQuotes) {
        result.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(char);
      }
    }
    result.add(buffer.toString());
    return result.map((s) => s.trim()).toList();
  }

  @override
  void dispose() {
    try { _watchdog?.cancel(); } catch (_) {}
    try { _discoverPartialDebounce?.cancel(); } catch (_) {}
    _pasteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final brand = context.brand;

    // Clean dark gradient background matching landing page
    final pageBgGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        const Color(0xFF0E1114),
        const Color(0xFF14181C),
        const Color(0xFF0F1418),
      ],
    );

    // Muted blue CTA sheen (brand-driven) rather than flat gray.
    final primaryCtaGradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        brand.accent.withValues(alpha: 0.95),
        brand.accent2.withValues(alpha: 0.75),
      ],
    );

    final softOutline = cs.outline.withValues(alpha: 0.22);

    Future<void> openUploadPickerSheet() async {
      final choice = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (ctx) {
          final cs = Theme.of(ctx).colorScheme;
          final brand = ctx.brand;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Choose a file', style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text('Upload one statement at a time (each = ~1 month of transactions).', style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: brand.accent,
                      foregroundColor: Colors.white,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    onPressed: () => ctx.pop('pdf'),
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.white.withValues(alpha: 0.3),
                            const Color(0xFF2F5BFF).withValues(alpha: 0.4),
                            const Color(0xFFa8c69f).withValues(alpha: 0.3),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF2F5BFF).withValues(alpha: 0.4),
                            blurRadius: 12,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(Icons.picture_as_pdf, color: Colors.white, size: 20),
                    ),
                    label: const Text(
                      'Upload PDF',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        shadows: [
                          Shadow(
                            color: Colors.black26,
                            blurRadius: 2,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      side: BorderSide(color: brand.accent, width: 2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      backgroundColor: brand.accent.withValues(alpha: 0.1),
                    ),
                    onPressed: () => ctx.pop('csv'),
                    icon: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            brand.accent.withValues(alpha: 0.3),
                            const Color(0xFFa8c69f).withValues(alpha: 0.4),
                            brand.accent2.withValues(alpha: 0.2),
                          ],
                        ),
                        border: Border.all(color: brand.accent.withValues(alpha: 0.4), width: 1.5),
                      ),
                      child: Icon(Icons.file_upload, color: cs.brightness == Brightness.dark ? Colors.white : brand.accent, size: 20),
                    ),
                    label: Text(
                      'Upload CSV',
                      style: TextStyle(
                        color: cs.brightness == Brightness.dark ? Colors.white : brand.accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
      if (!mounted) return;
      if (choice == 'pdf') return _pickPdf();
      if (choice == 'csv') return _pickCsv();
    }

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Upload Transactions', style: TextStyle(color: Colors.white)),
        centerTitle: true,
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => context.go(AppRoutes.landing),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz, color: Colors.white),
            onSelected: (v) async {
              if (v == 'backend_debug') {
                if (mounted) context.push(AppRoutes.backendDebug);
                return;
              }
              if (v == 'reset') {
                final removed = await _storage.clearAllSpendiqLocalData();
                await MasterSpreadsheetService.clearLocalMasterCaches();
                await StatementParserService.clearSimplePdfCache();
                if (!context.mounted) return;
                setState(() {
                  _pdfResult = null;
                  _categorizedRows = const [];
                  _transactions = [];
                  _persistedTxs = const [];
                  _uploadedMonthKeys.clear();
                  _monthsUploadedThisSession = 0;
                  _error = null;
                  _hidePlaceholder = false;
                });
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Local data reset (removed $removed keys)')));
              }
              if (v == 'force_ocr') {
                await _forceOcr400();
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: 'backend_debug', child: Text('Backend debug (temp)')),
              const PopupMenuItem(value: 'reset', child: Text('Reset local data')),
              if (kIsWeb) const PopupMenuItem(value: 'force_ocr', child: Text('Force OCR 400 (web)')),
            ],
          ),
          const SizedBox(width: 6),
        ],
      ),
      bottomNavigationBar: const DisclaimerBanner(
        text: 'SpendIQ recommends strategies based on your data but cannot guarantee results. Users are responsible for their credit card usage and any associated risks.',
      ),
      body: Container(
        decoration: BoxDecoration(gradient: pageBgGradient),
        child: SafeArea(
          // The page already has a bottomNavigationBar; keeping SafeArea bottom
          // padding here lifts the primary CTA unnecessarily on some screens.
          bottom: false,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.md),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView(
                        children: [
                          Text(
                            'How many months are in this upload?',
                            style: context.textStyles.headlineSmall.bold.withColor(Colors.white),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            "Each statement = 1 month. We'll multiply to a full year for analysis.",
                            style: context.textStyles.bodyMedium.withColor(Colors.white.withValues(alpha: 0.85)),
                          ),
                          const SizedBox(height: 16),
                          _MonthsChoiceCard(
                            value: 1,
                            title: 'One month',
                            subtitle: 'Default · 12× multiplier · 1 statement',
                            selected: _monthsInUpload == 1,
                            onTap: () => setState(() => _monthsInUpload = 1),
                            emphasized: true,
                          ),
                          const SizedBox(height: 10),
                          _MonthsChoiceCard(
                            value: 3,
                            title: 'One quarter',
                            subtitle: '3 months · 4× multiplier',
                            selected: _monthsInUpload == 3,
                            onTap: () => setState(() => _monthsInUpload = 3),
                          ),
                          const SizedBox(height: 10),
                          _MonthsChoiceCard(
                            value: 6,
                            title: 'Six months',
                            subtitle: '6 months · 2× multiplier',
                            selected: _monthsInUpload == 6,
                            onTap: () => setState(() => _monthsInUpload = 6),
                          ),
                          const SizedBox(height: 10),
                          _MonthsChoiceCard(
                            value: 12,
                            title: 'Full year',
                            subtitle: 'Most accurate · no projection · 12 statements',
                            selected: _monthsInUpload == 12,
                            onTap: () => setState(() => _monthsInUpload = 12),
                          ),
                          const SizedBox(height: 16),
                          GlassPanel(
                            padding: const EdgeInsets.all(14),
                            borderRadius: AppRadius.lg,
                              borderColor: softOutline,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: List.generate(12, (i) {
                                    const labels = ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'];
                                    final active = _isMonthActive(i);
                                    return _MonthChip(
                                      label: labels[i],
                                      active: active,
                                      onTap: () {
                                        setState(() => _monthWindowStart = i);
                                      },
                                    );
                                  }),
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  'Target coverage: ${_coverageLabelForWindow(_monthWindowStart, _monthsInUpload)} · tap to shift window',
                                  style: context.textStyles.labelMedium.withColor(Colors.white.withValues(alpha: 0.8)),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Note: Each statement may span 2 calendar months (e.g., Jan 15 → Feb 14)',
                                  style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.65)),
                                ),
                              ],
                            ),
                          ),
                          if (_isDesktopUploadMode) ...[
                            const SizedBox(height: 12),
                            _DesktopPdfDropZone(
                              borderColor: softOutline,
                              accent: brand.accent,
                              onPickClick: _loading ? null : () => _pickPdf(),
                              onDropped: _loading ? null : (files) => _importPdfBytesBatch(files),
                            ),
                          ],
                          if (_error != null) ...[
                            const SizedBox(height: 14),
                            Text(_error!, style: context.textStyles.bodyMedium.withColor(cs.error)),
                          ],
                          if (_pdfResult != null || _transactions.isNotEmpty) ...[
                            const SizedBox(height: 18),
                            Text('Preview', style: context.textStyles.titleLarge.bold),
                            const SizedBox(height: 10),
                            if (_pdfResult != null) _PdfPreviewPanel(
                              colorScheme: cs,
                              categorizedRows: _categorizedRows,
                              pdfResult: _pdfResult!,
                              categorize: _categorizeSimpleRow,
                              onWhyTap: (c) {
                                final r = c.row;
                                final now = DateTime.now();
                                _openTxDebugSheet(
                                  StatementParserService.applyNonNegotiableOverrides(
                                    SpendTransaction(
                                      id: 'preview_${now.millisecondsSinceEpoch}',
                                      date: r.date,
                                      description: r.sourceLine,
                                      merchant: r.merchant,
                                      category: c.level1,
                                      subcategory: c.level2,
                                      brand: c.level3,
                                      special: c.special,
                                      amount: c.normalizedAmount,
                                      uploadOrder: null,
                                      createdAt: now,
                                      updatedAt: now,
                                    ),
                                  ),
                                );
                              },
                            ),
                            if (_pdfResult != null) ...[
                              const SizedBox(height: 12),
                              GlassPanel(
                                borderRadius: AppRadius.lg,
                                padding: const EdgeInsets.all(12),
                                borderColor: softOutline,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(Icons.cloud_done, color: _isUploadComplete ? brand.accent : cs.onSurfaceVariant),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            'Uploaded $_monthsUploadedThisSession/${_monthsInUpload.clamp(1, 12)} months',
                                            style: context.textStyles.titleSmall.bold,
                                          ),
                                        ),
                                        if (_isUploadComplete)
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(999),
                                              gradient: LinearGradient(colors: [brand.accent.withValues(alpha: 0.92), brand.accent2.withValues(alpha: 0.7)]),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.check, size: 16, color: cs.onPrimary),
                                                const SizedBox(width: 6),
                                                Text('Ready', style: context.textStyles.labelMedium.bold.withColor(cs.onPrimary)),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(999),
                                      child: LinearProgressIndicator(
                                        value: (_monthsInUpload <= 0) ? 0 : (_monthsUploadedThisSession / _monthsInUpload.clamp(1, 12)).clamp(0, 1),
                                        minHeight: 8,
                                        backgroundColor: cs.surfaceContainerHighest.withValues(alpha: 0.4),
                                        valueColor: AlwaysStoppedAnimation<Color>(brand.accent.withValues(alpha: 0.9)),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    // Only show Download CSV button here (Analyze moved to bottom)
                                    OutlinedButton.icon(
                                      onPressed: () {
                                        final csv = _buildCsv();
                                        if (canDownloadCsv) {
                                          saveCsv('transactions.csv', csv);
                                        } else {
                                          Clipboard.setData(ClipboardData(text: csv));
                                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV copied to clipboard')));
                                        }
                                      },
                                      style: OutlinedButton.styleFrom(
                                        side: BorderSide(color: cs.brightness == Brightness.dark ? Colors.white.withValues(alpha: 0.7) : brand.accent, width: 2),
                                        foregroundColor: cs.brightness == Brightness.dark ? Colors.white : brand.accent,
                                        backgroundColor: cs.brightness == Brightness.dark ? Colors.white.withValues(alpha: 0.08) : brand.accent.withValues(alpha: 0.05),
                                      ),
                                      icon: Icon(Icons.download, color: cs.brightness == Brightness.dark ? Colors.white : brand.accent),
                                      label: Text(
                                        canDownloadCsv ? 'Download CSV' : 'Copy CSV',
                                        style: TextStyle(
                                          color: cs.brightness == Brightness.dark ? Colors.white : brand.accent,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            if (_transactions.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              GlassPanel(
                                borderRadius: AppRadius.xl,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Legacy CSV preview', style: context.textStyles.titleMedium.bold),
                                    const SizedBox(height: 10),
                                    ..._transactions.take(12).map((t) {
                                      return Padding(
                                        padding: const EdgeInsets.only(bottom: 10),
                                        child: ListTile(
                                          contentPadding: EdgeInsets.zero,
                                          leading: Icon(Icons.receipt_long, color: cs.primary),
                                          title: Text(t.description, overflow: TextOverflow.ellipsis),
                                          subtitle: Text('${t.category} • ${t.date.toIso8601String().split('T').first}', style: context.textStyles.labelMedium.withColor(cs.onSurfaceVariant)),
                                          trailing: Text(Formatters.fixed(t.amount, decimals: 2), style: context.textStyles.labelLarge.bold.withColor(t.amount < 0 ? cs.error : cs.primary)),
                                          onTap: () {
                                            final now = DateTime.now();
                                            _openTxDebugSheet(t.copyWith(updatedAt: now));
                                          },
                                        ),
                                      );
                                    }),
                                    if (_transactions.length > 12)
                                      Text('Showing 12 of ${_transactions.length}…', style: context.textStyles.labelSmall.withColor(cs.onSurfaceVariant)),
                                    const SizedBox(height: 10),
                                    OutlinedButton.icon(
                                      onPressed: null,
                                      icon: Icon(Icons.analytics, color: cs.onSurfaceVariant),
                                      label: Text('Analyze is only available after upload + Analyze', style: TextStyle(color: cs.onSurfaceVariant)),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                          const SizedBox(height: 28),
                        ],
                      ),
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          gradient: primaryCtaGradient,
                          boxShadow: [
                            BoxShadow(
                              color: brand.accent.withValues(alpha: 0.35),
                              blurRadius: 16,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                            padding: const EdgeInsets.symmetric(vertical: 18),
                          ),
                          onPressed: _loading
                              ? null
                              : (_isUploadComplete && _persistedTxs.isNotEmpty)
                                  ? _analyze
                                  : openUploadPickerSheet,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_isUploadComplete && _persistedTxs.isNotEmpty) ...[
                                Icon(Icons.analytics, color: Colors.white, size: 24),
                                const SizedBox(width: 12),
                              ],
                              Text(
                                _isUploadComplete && _persistedTxs.isNotEmpty ? 'Analyze now' : 'Continue to upload',
                                style: context.textStyles.titleMedium.bold.copyWith(
                                  fontSize: 17,
                                  color: Colors.white,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black.withValues(alpha: 0.25),
                                      blurRadius: 4,
                                      offset: const Offset(0, 1),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 10),
                              Icon(
                                _isUploadComplete && _persistedTxs.isNotEmpty ? Icons.arrow_forward : Icons.upload_file,
                                color: Colors.white,
                                size: 22,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                ),
              ),
              if (_loading)
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: false,
                    child: Container(
                      color: cs.surface.withValues(alpha: 0.55),
                      child: Center(
                        child: GlassPanel(
                          borderRadius: AppRadius.xl,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 38,
                                height: 38,
                                child: CircularProgressIndicator(color: cs.primary),
                              ),
                              const SizedBox(height: 14),
                              if (_currentStep >= 0 && _currentStep < _steps.length)
                                Text(
                                  _currentStep == 0 && _pdfPagesTotal > 0 ? '${_steps[_currentStep]} ($_pdfPagesDone/$_pdfPagesTotal pages)' : _steps[_currentStep],
                                  textAlign: TextAlign.center,
                                  style: context.textStyles.titleMedium.bold,
                                ),
                              const SizedBox(height: 6),
                              Text(
                                _currentStep == 2 ? 'Analyzing your spending patterns...' : 'This can take a moment on large PDFs.',
                                style: context.textStyles.bodySmall.withColor(cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NamedBytes {
  final String name;
  final Uint8List bytes;
  const _NamedBytes({required this.name, required this.bytes});
}

class _DesktopPdfDropZone extends StatefulWidget {
  const _DesktopPdfDropZone({required this.borderColor, required this.accent, required this.onPickClick, required this.onDropped});
  final Color borderColor;
  final Color accent;
  final VoidCallback? onPickClick;
  final Future<void> Function(List<_NamedBytes> files)? onDropped;

  @override
  State<_DesktopPdfDropZone> createState() => _DesktopPdfDropZoneState();
}

class _DesktopPdfDropZoneState extends State<_DesktopPdfDropZone> {
  DropzoneViewController? _controller;
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return GlassPanel(
      borderRadius: AppRadius.lg,
      borderColor: widget.borderColor,
      padding: const EdgeInsets.all(10),
      child: SizedBox(
        height: 150,
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                child: DropzoneView(
                  onCreated: (c) => _controller = c,
                  operation: DragOperation.copy,
                  cursor: CursorType.grab,
                  onHover: () => setState(() => _hovering = true),
                  onLeave: () => setState(() => _hovering = false),
                  onDropMultiple: (events) async {
                    setState(() => _hovering = false);
                    final controller = _controller;
                    final handler = widget.onDropped;
                    if (controller == null || handler == null) return;
                    try {
                      final out = <_NamedBytes>[];
                      for (final ev in events!) {
                        final name = await controller.getFilename(ev);
                        final mime = await controller.getFileMIME(ev);
                        if (!mime.toLowerCase().contains('pdf') && !name.toLowerCase().endsWith('.pdf')) continue;
                        final data = await controller.getFileData(ev);
                        out.add(_NamedBytes(name: name, bytes: data));
                      }
                      if (out.isNotEmpty) await handler(out);
                    } catch (e) {
                      debugPrint('Dropzone drop failed: $e');
                    }
                  },
                ),
              ),
            ),
            Positioned.fill(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                decoration: BoxDecoration(
                  color: _hovering ? widget.accent.withValues(alpha: 0.10) : cs.surfaceContainerHighest.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: _hovering ? widget.accent.withValues(alpha: 0.65) : widget.borderColor, width: 1.2),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withValues(alpha: 0.25),
                              widget.accent.withValues(alpha: 0.35),
                              const Color(0xFFa8c69f).withValues(alpha: 0.3),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: widget.accent.withValues(alpha: _hovering ? 0.4 : 0.2),
                              blurRadius: _hovering ? 20 : 12,
                              spreadRadius: _hovering ? 4 : 2,
                            ),
                          ],
                        ),
                        child: Icon(Icons.picture_as_pdf, color: Colors.white, size: 22),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'Drag & drop PDFs here',
                        style: context.textStyles.titleSmall.bold.withColor(Colors.white),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'or click to select multiple',
                        style: context.textStyles.bodySmall.withColor(Colors.white.withValues(alpha: 0.7)),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 5),
                      FilledButton.icon(
                        onPressed: widget.onPickClick,
                        style: FilledButton.styleFrom(
                          backgroundColor: widget.accent.withValues(alpha: 0.92),
                          foregroundColor: cs.onPrimary,
                          shadowColor: Colors.transparent,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        ),
                        icon: Icon(Icons.upload_file, color: cs.onPrimary, size: 14),
                        label: Text('Choose PDFs', style: TextStyle(color: cs.onPrimary, fontWeight: FontWeight.w700, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _coverageLabelForWindow(int start, int length) {
  const names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final len = length.clamp(1, 12);
  final s = (start % 12 + 12) % 12;
  if (len == 12) return 'Jan → Dec';
  final end = (s + len - 1) % 12;
  return '${names[s]} → ${names[end]}';
}

class _MonthsChoiceCard extends StatelessWidget {
  const _MonthsChoiceCard({required this.value, required this.title, required this.subtitle, required this.selected, required this.onTap, this.emphasized = false});

  final int value;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final brand = context.brand;
    final accent = cs.inversePrimary;
    // "emphasized" is used to mark the recommended option, but it should not
    // appear selected/highlighted unless the user actually selects it.
    final effectiveEmphasis = emphasized && selected;

    final border = selected
        ? accent.withValues(alpha: 0.65)
        : cs.outline.withValues(alpha: 0.18);
    final bgOpacity = selected ? 0.16 : 0.11;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.xl),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      child: GlassPanel(
        borderRadius: AppRadius.xl,
        backgroundOpacity: effectiveEmphasis ? 0.18 : bgOpacity,
        borderColor: border,
        borderWidth: selected ? 1.3 : 1,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: (selected || effectiveEmphasis)
                  ? AppGradients.primarySheen(cs)
                  : LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withValues(alpha: 0.2),
                        const Color(0xFF2F5BFF).withValues(alpha: 0.3),
                        const Color(0xFFa8c69f).withValues(alpha: 0.2),
                      ],
                    ),
                boxShadow: [
                  BoxShadow(
                    color: (selected || effectiveEmphasis)
                      ? brand.accent.withValues(alpha: 0.3)
                      : const Color(0xFF2F5BFF).withValues(alpha: 0.2),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: Text(
                '$value',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: selected ? accent.withValues(alpha: 0.9) : cs.outline.withValues(alpha: 0.35), width: 1.4),
                color: selected ? accent.withValues(alpha: 0.18) : Colors.transparent,
              ),
              child: selected ? Icon(Icons.check, size: 16, color: accent.withValues(alpha: 0.95)) : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthChip extends StatelessWidget {
  const _MonthChip({required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accent = cs.primary;
    return InkWell(
      onTap: onTap,
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 28,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          gradient: active
            ? LinearGradient(
                colors: [
                  accent.withValues(alpha: 0.9),
                  accent.withValues(alpha: 0.7),
                ],
              )
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.15),
                  const Color(0xFF2F5BFF).withValues(alpha: 0.2),
                ],
              ),
          border: Border.all(
            color: active ? accent.withValues(alpha: 0.6) : Colors.white.withValues(alpha: 0.2),
            width: active ? 1.5 : 1,
          ),
          boxShadow: active ? [
            BoxShadow(
              color: accent.withValues(alpha: 0.4),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ] : null,
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
        ),
      ),
    );
  }
}

class _PdfPreviewPanel extends StatelessWidget {
  const _PdfPreviewPanel({required this.colorScheme, required this.categorizedRows, required this.pdfResult, required this.categorize, required this.onWhyTap});

  final ColorScheme colorScheme;
  final List<_CategorizedSimpleRow> categorizedRows;
  final SimpleParseResult pdfResult;
  final _CategorizedSimpleRow Function(SimpleTransactionRow row) categorize;
  final void Function(_CategorizedSimpleRow c) onWhyTap;

  @override
  Widget build(BuildContext context) {
    final cs = colorScheme;
    final rows = categorizedRows.isNotEmpty ? categorizedRows : pdfResult.rows.map((r) => categorize(r)).toList(growable: false);

    return GlassPanel(
      borderRadius: AppRadius.xl,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.table_chart, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(child: Text('Transactions', style: context.textStyles.titleMedium.bold.withColor(Colors.white))),
              Text('${rows.length}', style: context.textStyles.labelLarge.bold.withColor(Colors.white.withValues(alpha: 0.85))),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 340,
            child: SingleChildScrollView(
              child: Column(
                children: rows.take(25).map((c) {
                  final r = c.row;
                  final amt = c.normalizedAmount;
                  final d = '${r.date.month.toString().padLeft(2, '0')}/${r.date.day.toString().padLeft(2, '0')}/${r.date.year}';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(width: 70, child: Text(d, style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.75)))),
                        const SizedBox(width: 10),
                        Expanded(child: Text(r.merchant, overflow: TextOverflow.ellipsis, style: context.textStyles.bodyMedium.withColor(Colors.white.withValues(alpha: 0.95)))),
                        const SizedBox(width: 10),
                        Text(
                          Formatters.fixed(amt, decimals: 2),
                          style: context.textStyles.labelLarge.bold.withColor(amt < 0 ? const Color(0xFFFF6B6B) : const Color(0xFF4CAF50)),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Why this match/category?',
                          icon: Icon(Icons.help_outline, color: Colors.white.withValues(alpha: 0.8)),
                          onPressed: () => onWhyTap(c),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          if (rows.length > 25) ...[
            const SizedBox(height: 8),
            Text('Showing 25 of ${rows.length}. Export to see all.', style: context.textStyles.labelSmall.withColor(Colors.white.withValues(alpha: 0.7))),
          ],
        ],
      ),
    );
  }
}
