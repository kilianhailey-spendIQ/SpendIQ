// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

bool canDownloadCsvImpl = true;

void saveCsvImpl(String filename, String csv) {
  final blob = html.Blob([csv], 'text/csv;charset=utf-8');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)..download = filename;
  anchor.click();
  html.Url.revokeObjectUrl(url);
}
