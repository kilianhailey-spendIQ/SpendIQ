import 'dart:io';
import 'package:excel/excel.dart';

void main() async {
  try {
    final bytes = await File('assets/documents/SpendIQ_MASTER_UPDATED_v106.xlsx').readAsBytes();
    final excel = Excel.decodeBytes(bytes);
    
    print('=== Available Sheets ===');
    for (final sheetName in excel.tables.keys) {
      print('  - $sheetName');
    }
    
    // Inspect Credits tab
    final creditsSheet = excel.tables['Credits'];
    if (creditsSheet != null) {
      print('\n=== Credits Tab Structure ===');
      final headers = creditsSheet.rows.first.map((c) => c?.value?.toString() ?? '').toList();
      print('Columns: $headers');
      print('Total rows: ${creditsSheet.maxRows}');
      
      print('\n=== First 3 Data Rows ===');
      for (int i = 1; i < creditsSheet.rows.length && i < 4; i++) {
        final row = creditsSheet.rows[i].map((c) => c?.value?.toString() ?? '').toList();
        print('Row ${i + 1}: $row');
      }
    }
    
    // Inspect Accepted_Establishments_Master
    final estabSheet = excel.tables['Accepted_Establishments_Master'];
    if (estabSheet != null) {
      print('\n=== Accepted_Establishments_Master Tab Structure ===');
      final headers = estabSheet.rows.first.map((c) => c?.value?.toString() ?? '').toList();
      print('Columns: $headers');
      print('Total rows: ${estabSheet.maxRows}');
      
      print('\n=== First 3 Data Rows ===');
      for (int i = 1; i < estabSheet.rows.length && i < 4; i++) {
        final row = estabSheet.rows[i].map((c) => c?.value?.toString() ?? '').toList();
        print('Row ${i + 1}: $row');
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
      print('\n=== $creditMerchSheet Tab Structure ===');
      final sheet = excel.tables[creditMerchSheet];
      final headers = sheet!.rows.first.map((c) => c?.value?.toString() ?? '').toList();
      print('Columns: $headers');
      print('Total rows: ${sheet.maxRows}');
      
      print('\n=== First 3 Data Rows ===');
      for (int i = 1; i < sheet.rows.length && i < 4; i++) {
        final row = sheet.rows[i].map((c) => c?.value?.toString() ?? '').toList();
        print('Row ${i + 1}: $row');
      }
    }
    
  } catch (e) {
    print('Error: $e');
  }
}
