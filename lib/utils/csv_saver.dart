import 'package:spendiq/utils/csv_saver_stub.dart'
    if (dart.library.html) 'package:spendiq/utils/csv_saver_web.dart';

/// Returns true on web where downloading is supported.
bool get canDownloadCsv => canDownloadCsvImpl;

/// Triggers a CSV download when supported (web). No-op on other platforms.
void saveCsv(String filename, String csv) => saveCsvImpl(filename, csv);
