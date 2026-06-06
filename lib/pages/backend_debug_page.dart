import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:spendiq/utils/formatters.dart';
import 'package:go_router/go_router.dart';
import 'package:spendiq/core/optimiq.dart';
import 'package:spendiq/models/recommendation.dart';
import 'package:spendiq/models/transaction.dart';
import 'package:spendiq/nav.dart';
import 'package:spendiq/services/master_spreadsheet_service.dart';
import 'package:spendiq/services/spend_categorizer.dart';
import 'package:spendiq/services/statement_parser.dart';
import 'package:spendiq/theme.dart';
import 'package:spendiq/components/glass_panel.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:excel/excel.dart' as xl;

/// TEMPORARY page for internal verification of parsing + calculation outputs.
///
/// Per your request:
/// - purely for visibility/debug (will be deleted later)
/// - only supports Upload PDF and Upload CSV
/// - does NOT change any functional parsing/calculation logic elsewhere
class BackendDebugPage extends StatefulWidget {
  const BackendDebugPage({super.key});

  @override
  State<BackendDebugPage> createState() => _BackendDebugPageState();
}

class _BackendDebugPageState extends State<BackendDebugPage> {
  bool _loading = false;
  String? _error;

  List<SpendTransaction> _transactions = const [];
  RecommendationResult? _rec;
  List<dynamic> _perTx = const [];
  Map<String, double> _spendByCategory = const {};
  Map<String, double> _perCardRewards = const {};
  Map<String, double> _categoryEarnings = const {};

  Future<void> _pickPdf() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf'], withData: true);
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) throw 'No file data available';
      await _analyzePdfBytes(bytes);
    } catch (e) {
      debugPrint('BackendDebugPage PDF error: $e');
      setState(() => _error = 'Failed to import PDF: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickCsv() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv'], withData: true);
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null) throw 'No file data available';
      final content = utf8.decode(bytes);
      final parsed = _parseCsv(content);
      await _analyzeTransactions(parsed);
    } catch (e) {
      debugPrint('BackendDebugPage CSV error: $e');
      setState(() => _error = 'Failed to import CSV: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _inspectSpreadsheet() async {
    try {
      debugPrint('\n========== INSPECTING V106 SPREADSHEET ==========');
      final bytes = (await rootBundle.load('assets/documents/SpendIQ_MASTER_UPDATED_v106.xlsx')).buffer.asUint8List();
      final excel = xl.Excel.decodeBytes(bytes);
      
      debugPrint('\n=== Available Sheets ===');
      for (final sheetName in excel.tables.keys) {
        debugPrint('  - $sheetName');
      }
      
      // Inspect Credits tab
      final creditsSheet = excel.tables['Credits'];
      if (creditsSheet != null) {
        debugPrint('\n=== Credits Tab Structure ===');
        final headers = creditsSheet.rows.first.map((c) => c?.value?.toString() ?? '').toList();
        debugPrint('Columns: $headers');
        debugPrint('Total rows: ${creditsSheet.maxRows}');
        
        debugPrint('\n=== First 3 Data Rows ===');
        for (int i = 1; i < creditsSheet.rows.length && i < 4; i++) {
          final row = creditsSheet.rows[i].map((c) => c?.value?.toString() ?? '').toList();
          debugPrint('Row ${i + 1}: $row');
        }
      }
      
      // Inspect Accepted_Establishments_Master
      final estabSheet = excel.tables['Accepted_Establishments_Master'];
      if (estabSheet != null) {
        debugPrint('\n=== Accepted_Establishments_Master Tab Structure ===');
        final headers = estabSheet.rows.first.map((c) => c?.value?.toString() ?? '').toList();
        debugPrint('Columns: $headers');
        debugPrint('Total rows: ${estabSheet.maxRows}');
        
        debugPrint('\n=== First 3 Data Rows ===');
        for (int i = 1; i < estabSheet.rows.length && i < 4; i++) {
          final row = estabSheet.rows[i].map((c) => c?.value?.toString() ?? '').toList();
          debugPrint('Row ${i + 1}: $row');
        }
      }
      
      // Find Credit_Merchants sheet
      String? creditMerchSheet;
      for (final name in excel.tables.keys) {
        if (name.toLowerCase().contains('credit') && name.toLowerCase().contains('merchant')) {
          creditMerchSheet = name;
          break;
        }
      }
      
      if (creditMerchSheet != null) {
        debugPrint('\n=== $creditMerchSheet Tab Structure ===');
        final sheet = excel.tables[creditMerchSheet]!;
        final headers = sheet.rows.first.map((c) => c?.value?.toString() ?? '').toList();
        debugPrint('Columns: $headers');
        debugPrint('Total rows: ${sheet.maxRows}');
        
        debugPrint('\n=== First 3 Data Rows ===');
        for (int i = 1; i < sheet.rows.length && i < 4; i++) {
          final row = sheet.rows[i].map((c) => c?.value?.toString() ?? '').toList();
          debugPrint('Row ${i + 1}: $row');
        }
      }
      
      debugPrint('\n========== INSPECTION COMPLETE ==========\n');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Spreadsheet inspection complete - check Debug Console')),
        );
      }
    } catch (e) {
      debugPrint('Error inspecting spreadsheet: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _analyzePdfBytes(Uint8List data) async {
    await MasterSpreadsheetService.ensureLoaded();
    final parsed = await StatementParserService.extractSimpleFromBytesWithProgress(
      data,
      onPageProgress: (_, __) {},
    );

    // Match UploadPage behavior: categorize, apply overrides, and sanitize.
    final now = DateTime.now();
    int i = 0;
    final txs = parsed.rows.map((r) {
      final cat = SpendCategorizer.categorize(merchant: r.merchant, description: r.sourceLine);
      final tx = SpendTransaction(
        id: 'dbg_${now.millisecondsSinceEpoch}_$i',
        date: r.date,
        description: r.sourceLine,
        merchant: r.merchant,
        category: cat.level1,
        subcategory: cat.level2,
        brand: cat.level3,
        special: cat.special,
        amount: r.amount,
        uploadOrder: i,
        createdAt: now,
        updatedAt: now,
      );
      i++;
      return StatementParserService.applyNonNegotiableOverrides(tx);
    }).toList(growable: false);

    final sanitized = StatementParserService.sanitizeTransactions(txs, label: 'backend_debug_pdf');
    final deduped = StatementParserService.dedupeExactTransactions(sanitized, label: 'backend_debug_pdf');
    await _analyzeTransactions(deduped);
  }

  Future<void> _analyzeTransactions(List<SpendTransaction> txs) async {
    final engine = OptimIQEngine(cards: MasterSpreadsheetService.getCardModelsOrFallback());
    final rec = engine.recommend(txs);
    final perTx = engine.perTransactionRecords(txs);

    setState(() {
      _transactions = txs;
      _rec = rec;
      _perTx = perTx;
      _spendByCategory = rec.spendByCategory.map((k, v) => MapEntry(k, v.toDouble()));
      _perCardRewards = rec.perCardRewards.map((k, v) => MapEntry(k, v.toDouble()));
      _categoryEarnings = rec.categoryEarnings.map((k, v) => MapEntry(k, v.toDouble()));
    });
  }

  List<SpendTransaction> _parseCsv(String content) {
    final lines = const LineSplitter().convert(content).where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return [];
    final now = DateTime.now();
    final txs = <SpendTransaction>[];
    for (int i = 1; i < lines.length; i++) {
      final row = _splitCsvLine(lines[i]);
      if (row.length < 4) continue;
      final date = StatementParserService.parseFlexibleDate(row[0]) ?? DateTime.tryParse(row[0]) ?? now;
      final desc = row[1];
      final cat = row[2].toLowerCase().trim();
      final parsedAmt = double.tryParse(row[3].replaceAll(',', '')) ?? 0;
      final amt = StatementParserService.isInterestText(desc) ? -parsedAmt.abs() : parsedAmt;
      final guess = SpendCategorizer.categorize(merchant: desc, description: desc);
      final tx = SpendTransaction(
        id: 'dbg_csv_$i',
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
      txs.add(StatementParserService.applyNonNegotiableOverrides(tx));
    }
    return StatementParserService.filterSpendTransactionDateOutliers(txs, label: 'backend_debug_csv');
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
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final rec = _rec;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Backend Debug'),
        centerTitle: true,
        leading: IconButton(
          tooltip: 'Back',
          icon: Icon(Icons.arrow_back, color: cs.onSurface),
          onPressed: () => context.pop(),
        ),
      ),
      body: Container(
        decoration: BoxDecoration(gradient: AppGradients.appBackground(cs)),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              GlassPanel(
                borderRadius: AppRadius.xl,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Uploads (temporary)', style: context.textStyles.titleMedium.bold),
                    const SizedBox(height: 8),
                    Text('Only for checking what the engine is calculating. This page will be deleted later.', style: context.textStyles.bodySmall.withColor(cs.onSurfaceVariant)),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _loading ? null : _pickPdf,
                      icon: Icon(Icons.picture_as_pdf, color: cs.onPrimary),
                      label: Text('Upload PDF', style: TextStyle(color: cs.onPrimary)),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _loading ? null : _pickCsv,
                      icon: Icon(Icons.file_upload, color: cs.primary),
                      label: Text('Upload CSV', style: TextStyle(color: cs.primary)),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: _inspectSpreadsheet,
                      icon: Icon(Icons.table_chart, color: cs.secondary),
                      label: Text('Inspect v106 Spreadsheet', style: TextStyle(color: cs.secondary)),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: context.textStyles.bodyMedium.withColor(cs.error)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (_loading)
                Center(child: Padding(padding: const EdgeInsets.only(top: 18), child: CircularProgressIndicator(color: cs.primary))),
              if (!_loading && rec != null) ...[
                GlassPanel(
                  borderRadius: AppRadius.xl,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Top recommendation', style: context.textStyles.titleMedium.bold),
                      const SizedBox(height: 10),
                      _KV('Card', rec.cardName),
                      _KV('Estimated annual value', Formatters.money(rec.estimatedAnnualValue, decimals: 2)),
                      _KV('Rewards', Formatters.money(rec.totalRewards, decimals: 2)),
                      _KV('Annual fee', Formatters.money(rec.annualFee, decimals: 0)),
                      _KV('Transactions analyzed', '${_transactions.length}'),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                GlassPanel(
                  borderRadius: AppRadius.xl,
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    collapsedIconColor: cs.onSurfaceVariant,
                    iconColor: cs.onSurfaceVariant,
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: Text('Spend by category (Level 1)', style: context.textStyles.titleMedium.bold),
                    children: (() {
                      final sorted = _spendByCategory.entries.where((e) => e.value != 0).toList(growable: false)
                        ..sort((a, b) => b.value.compareTo(a.value));
                      return sorted.take(30).map((e) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _KV(e.key, Formatters.money(e.value, decimals: 2)),
                        );
                      }).toList(growable: false);
                    })(),
                  ),
                ),
                const SizedBox(height: 14),
                GlassPanel(
                  borderRadius: AppRadius.xl,
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    collapsedIconColor: cs.onSurfaceVariant,
                    iconColor: cs.onSurfaceVariant,
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: Text('Per-card rewards', style: context.textStyles.titleMedium.bold),
                    children: (() {
                      final sorted = _perCardRewards.entries.toList(growable: false)
                        ..sort((a, b) => b.value.compareTo(a.value));
                      return sorted.take(30).map((e) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _KV(e.key, Formatters.money(e.value, decimals: 2)),
                        );
                      }).toList(growable: false);
                    })(),
                  ),
                ),
                const SizedBox(height: 14),
                GlassPanel(
                  borderRadius: AppRadius.xl,
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    collapsedIconColor: cs.onSurfaceVariant,
                    iconColor: cs.onSurfaceVariant,
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: Text('Category earnings', style: context.textStyles.titleMedium.bold),
                    children: (() {
                      final sorted = _categoryEarnings.entries.toList(growable: false)
                        ..sort((a, b) => b.value.compareTo(a.value));
                      return sorted.take(30).map((e) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _KV(e.key, Formatters.money(e.value, decimals: 2)),
                        );
                      }).toList(growable: false);
                    })(),
                  ),
                ),
                const SizedBox(height: 14),
                GlassPanel(
                  borderRadius: AppRadius.xl,
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    collapsedIconColor: cs.onSurfaceVariant,
                    iconColor: cs.onSurfaceVariant,
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: Text('Per-transaction routing records', style: context.textStyles.titleMedium.bold),
                    children: [
                      Text('Showing ${_perTx.length} records', style: context.textStyles.bodySmall.withColor(cs.onSurfaceVariant)),
                      const SizedBox(height: 10),
                      ..._perTx.take(50).map((p) {
                        final dp = p as dynamic;
                        final d = '${dp.date.month.toString().padLeft(2, '0')}/${dp.date.day.toString().padLeft(2, '0')}/${dp.date.year}';
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _KV('${dp.merchant} • ${dp.category}', '${dp.cardDisplay} · reward ${Formatters.money(dp.estimatedReward, decimals: 2)} · $d'),
                        );
                      }),
                      if (_perTx.length > 50)
                        Text('Showing 50 of ${_perTx.length}.', style: context.textStyles.labelSmall.withColor(cs.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _KV extends StatelessWidget {
  const _KV(this.k, this.v);
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(k, style: context.textStyles.bodySmall.withColor(cs.onSurfaceVariant))),
        const SizedBox(width: 12),
        Flexible(child: Text(v, textAlign: TextAlign.right, style: context.textStyles.bodySmall.bold)),
      ],
    );
  }
}
