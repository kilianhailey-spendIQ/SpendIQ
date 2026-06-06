// Web-only OCR service using JS interop to Tesseract.js + PDF.js
// On non-web platforms this file is still importable but will throw if called.

import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:js/js.dart';
import 'package:js/js_util.dart' as jsu;

@JS('ocrExtractTextFromPdf')
external Object _ocrExtractTextFromPdf(Object bytes, String lang, Function progressCb, Function partialCb);

// Smart extractor (tries text layer first, falls back to OCR).
@JS('ocrSmartExtractFromPdf')
external Object _ocrSmartExtractFromPdf(Object bytes, String lang, Function progressCb, Function partialCb);

// Raster-only OCR (ignore embedded text layer entirely). Renders at given DPI.
@JS('ocrRasterOnlyFromPdf')
external Object _ocrRasterOnlyFromPdf(Object bytes, String lang, int dpi, Function progressCb, Function partialCb);

// Raster-only OCR with vertical cropping (discover fast path)
@JS('ocrRasterOnlyFromPdfCropped')
external Object _ocrRasterOnlyFromPdfCropped(Object bytes, String lang, int dpi, num cropTop, num cropBottom, Function progressCb, Function partialCb);

// Discover-only adaptive DPI OCR (150 DPI skim -> detect Transactions -> 200 DPI rest)
@JS('ocrRasterDiscoverAdaptiveFromPdf')
external Object _ocrRasterDiscoverAdaptiveFromPdf(
  Object bytes,
  String lang,
  int dpiFast,
  int dpiFull,
  num cropTop,
  num cropBottom,
  Function progressCb,
  Function partialCb,
);

class OcrService {
  /// Smart extract full result shape returned from web/ocr.js.
  ///
  /// Kept separate from [extractSmartTexts] so existing callers remain unchanged.
  static Future<Map<String, Object?>> extractSmartResult(
    Uint8List bytes, {
    void Function(int done, int total)? onPageProgress,
    void Function(String partialText)? onPartialText,
    String lang = 'eng',
  }) async {
    if (!kIsWeb) throw UnsupportedError('Smart extract is only available on web');
    final arr = jsu.jsify(bytes.toList());

    void progressProxy(int done, int total) => onPageProgress?.call(done, total);
    void partialProxy(String text) => onPartialText?.call(text);

    final promise = _ocrSmartExtractFromPdf(
      arr,
      lang,
      allowInterop(progressProxy),
      allowInterop(partialProxy),
    );
    final result = await jsu.promiseToFuture<Object>(promise);
    final dartResult = jsu.dartify(result);
    if (dartResult is Map) return dartResult.cast<String, Object?>();
    throw StateError('Unexpected smart extract result shape');
  }

  /// Extracts text from a PDF using OCR in the browser.
  /// Requires web/index.html to include pdfjs-dist, tesseract.min.js, and web/ocr.js.
  static Future<List<String>> extractPdfToTexts(
    Uint8List bytes, {
    void Function(int done, int total)? onPageProgress,
    void Function(String partialText)? onPartialText,
    String lang = 'eng',
  }) async {
    if (!kIsWeb) {
      throw UnsupportedError('OCR is only available on web');
    }
    // Convert to a plain JS Array of numbers for compatibility with
    // new Uint8Array(bytes) in web/ocr.js
    final arr = jsu.jsify(bytes.toList());

    void progressProxy(int done, int total) {
      onPageProgress?.call(done, total);
    }

    void partialProxy(String text) {
      onPartialText?.call(text);
    }

    try {
      final promise = _ocrExtractTextFromPdf(
        arr,
        lang,
        allowInterop(progressProxy),
        allowInterop(partialProxy),
      );
      final result = await jsu.promiseToFuture<Object>(promise);
      // Convert JS object -> Dart map for safe access
      final dartResult = jsu.dartify(result);
      if (dartResult is Map && dartResult['pages'] is List) {
        return (dartResult['pages'] as List).cast<String>();
      }
      throw StateError('Unexpected OCR result shape');
    } catch (e) {
      rethrow;
    }
  }

  /// Smart extraction that prefers the embedded text layer via pdf.js and only
  /// uses Tesseract OCR if the PDF appears scanned or the first page is garbled.
  static Future<List<String>> extractSmartTexts(
    Uint8List bytes, {
    void Function(int done, int total)? onPageProgress,
    void Function(String partialText)? onPartialText,
    String lang = 'eng',
  }) async {
    final res = await extractSmartResult(
      bytes,
      onPageProgress: onPageProgress,
      onPartialText: onPartialText,
      lang: lang,
    );
    final pages = res['pages'];
    if (pages is List) return pages.cast<String>();
    throw StateError('Unexpected smart extract result shape');
  }

  /// Force rasterization + OCR only at the specified DPI (default 300).
  /// Ignores any embedded text layer completely.
  static Future<List<String>> extractRasterOnlyTexts(
    Uint8List bytes, {
    String? traceId,
    void Function(int done, int total)? onPageProgress,
    void Function(String partialText)? onPartialText,
    String lang = 'eng',
    int dpi = 300,
  }) async {
    if (!kIsWeb) {
      throw UnsupportedError('Raster-only OCR is only available on web');
    }
    debugPrint('PDFTRACE[${traceId ?? "no-trace"}] web_ocr:raster_only start dpi=$dpi bytes=${bytes.lengthInBytes}');
    final arr = jsu.jsify(bytes.toList());

    void progressProxy(int done, int total) {
      onPageProgress?.call(done, total);
    }

    void partialProxy(String text) {
      onPartialText?.call(text);
    }

    final promise = _ocrRasterOnlyFromPdf(
      arr,
      lang,
      dpi,
      allowInterop(progressProxy),
      allowInterop(partialProxy),
    );
    final result = await jsu.promiseToFuture<Object>(promise);
    final dartResult = jsu.dartify(result);
    if (dartResult is Map && dartResult['pages'] is List) {
      final pages = (dartResult['pages'] as List).cast<String>();
      final totalLen = pages.fold<int>(0, (p, e) => p + e.length);
      debugPrint('PDFTRACE[${traceId ?? "no-trace"}] web_ocr:raster_only done pages=${pages.length} chars=$totalLen');
      return pages;
    }
    throw StateError('Unexpected raster-only OCR result shape');
  }

  /// Raster-only OCR with vertical cropping to skip headers/footers for speed.
  /// Useful for Discover-only fast path.
  static Future<List<String>> extractRasterOnlyTextsCropped(
    Uint8List bytes, {
    String? traceId,
    void Function(int done, int total)? onPageProgress,
    void Function(String partialText)? onPartialText,
    String lang = 'eng',
    int dpi = 260,
    double cropTop = 0.12,
    double cropBottom = 0.08,
  }) async {
    if (!kIsWeb) {
      throw UnsupportedError('Raster-only OCR (cropped) is only available on web');
    }
    debugPrint('PDFTRACE[${traceId ?? "no-trace"}] web_ocr:raster_cropped start dpi=$dpi cropTop=$cropTop cropBottom=$cropBottom bytes=${bytes.lengthInBytes}');
    final arr = jsu.jsify(bytes.toList());

    void progressProxy(int done, int total) {
      onPageProgress?.call(done, total);
    }

    void partialProxy(String text) {
      onPartialText?.call(text);
    }

    final promise = _ocrRasterOnlyFromPdfCropped(
      arr,
      lang,
      dpi,
      cropTop,
      cropBottom,
      allowInterop(progressProxy),
      allowInterop(partialProxy),
    );
    final result = await jsu.promiseToFuture<Object>(promise);
    final dartResult = jsu.dartify(result);
    if (dartResult is Map && dartResult['pages'] is List) {
      final pages = (dartResult['pages'] as List).cast<String>();
      final totalLen = pages.fold<int>(0, (p, e) => p + e.length);
      debugPrint('PDFTRACE[${traceId ?? "no-trace"}] web_ocr:raster_cropped done pages=${pages.length} chars=$totalLen');
      return pages;
    }
    throw StateError('Unexpected raster-only OCR (cropped) result shape');
  }

  /// Discover-only: Adaptive DPI OCR flow.
  /// Skims pages at 150 DPI with 12%/10% top/bottom crop until it detects a line
  /// that starts with "Transactions", then re-OCRs that page at 200 DPI and
  /// continues remaining pages at 200 DPI. Never skips pages.
  static Future<List<String>> extractRasterDiscoverAdaptive(
    Uint8List bytes, {
    String? traceId,
    void Function(int done, int total)? onPageProgress,
    void Function(String partialText)? onPartialText,
    String lang = 'eng',
    int dpiFast = 150,
    int dpiFull = 200,
    double cropTop = 0.12,
    double cropBottom = 0.10,
  }) async {
    if (!kIsWeb) {
      throw UnsupportedError('Raster-only OCR (discover adaptive) is only available on web');
    }
    debugPrint('PDFTRACE[${traceId ?? "no-trace"}] web_ocr:discover_adaptive start dpiFast=$dpiFast dpiFull=$dpiFull cropTop=$cropTop cropBottom=$cropBottom bytes=${bytes.lengthInBytes}');
    final arr = jsu.jsify(bytes.toList());

    void progressProxy(int done, int total) {
      onPageProgress?.call(done, total);
    }

    void partialProxy(String text) {
      onPartialText?.call(text);
    }

    final promise = _ocrRasterDiscoverAdaptiveFromPdf(
      arr,
      lang,
      dpiFast,
      dpiFull,
      cropTop,
      cropBottom,
      allowInterop(progressProxy),
      allowInterop(partialProxy),
    );
    final result = await jsu.promiseToFuture<Object>(promise);
    final dartResult = jsu.dartify(result);
    if (dartResult is Map && dartResult['pages'] is List) {
      final pages = (dartResult['pages'] as List).cast<String>();
      final totalLen = pages.fold<int>(0, (p, e) => p + e.length);
      debugPrint('PDFTRACE[${traceId ?? "no-trace"}] web_ocr:discover_adaptive done pages=${pages.length} chars=$totalLen');
      return pages;
    }
    throw StateError('Unexpected raster-only OCR (discover adaptive) result shape');
  }
}
