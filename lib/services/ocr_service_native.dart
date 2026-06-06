import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'dart:ui' show Rect, Size;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdf_render/pdf_render.dart';

/// Native (Android/iOS/macOS/Windows) OCR service.
///
/// On Web we use `ocr_service_web.dart` (Tesseract.js). On native platforms
/// we render PDF pages to images and run ML Kit text recognition.
class NativeOcrService {
  static Uint8List _rgbaToBgra(Uint8List rgba) {
    // pdf_render returns RGBA. ML Kit plugin expects BGRA8888.
    // Swapping R/B significantly improves recognition accuracy on many devices.
    final out = Uint8List(rgba.length);
    for (int i = 0; i + 3 < rgba.length; i += 4) {
      final r = rgba[i];
      final g = rgba[i + 1];
      final b = rgba[i + 2];
      final a = rgba[i + 3];
      out[i] = b;
      out[i + 1] = g;
      out[i + 2] = r;
      out[i + 3] = a;
    }
    return out;
  }

  /// Extracts a single concatenated raw text output for the entire PDF.
  ///
  /// This is intentionally *raw-ish* (no trimming/parsing), so the caller can
  /// reuse the exact same parsing pipeline as the web flow.
  static Future<String> extractRawTextFromPdf(
    Uint8List pdfBytes, {
    String? traceId,
    void Function(int donePages, int totalPages)? onPageProgress,
    int maxPages = 30,
      // Default tuned to approximate the web OCR path (typically 300 DPI).
      // PDF points are ~72 DPI; 300/72 ~= 4.17.
      double scale = 4.0,
  }) async {
    if (kIsWeb) throw UnsupportedError('NativeOcrService is not available on web');

    PdfDocument? doc;
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      doc = await PdfDocument.openData(pdfBytes);
      final total = doc.pageCount;
      final limit = total > maxPages ? maxPages : total;
      debugPrint('PDFTRACE[${traceId ?? "no-trace"}] native_ocr:start pages=$total limit=$limit scale=$scale bytes=${pdfBytes.lengthInBytes}');
      final buffer = StringBuffer();

      int nonEmptyPages = 0;
      int totalChars = 0;

      for (int i = 1; i <= limit; i++) {
        onPageProgress?.call(i, limit);
        final page = await doc.getPage(i);
        try {
          final w = (page.width * scale).round();
          final h = (page.height * scale).round();
          final img = await page.render(width: w, height: h, fullWidth: w.toDouble(), fullHeight: h.toDouble());
          try {
              final bytes = img.pixels;
            if (bytes.isEmpty) continue;

              final bgra = _rgbaToBgra(bytes);

            // pdf_render returns RGBA bytes.
            final inputImage = InputImage.fromBytes(
                bytes: bgra,
              metadata: InputImageMetadata(
                size: Size(w.toDouble(), h.toDouble()),
                rotation: InputImageRotation.rotation0deg,
                  // MLKit Flutter plugin supports bgra8888.
                format: InputImageFormat.bgra8888,
                bytesPerRow: w * 4,
              ),
            );

            final recognized = await recognizer.processImage(inputImage);
            final pageText = _recognizedTextToLineOrderedText(recognized);
            if (pageText.trim().isNotEmpty) {
              nonEmptyPages++;
              totalChars += pageText.length;
              buffer.writeln(pageText);
              buffer.writeln('\n');
            }
          } finally {
            try {
              img.dispose();
            } catch (_) {}
          }
        } finally {
          // PdfPage does not expose a close/dispose in the public interface.
        }

        // Yield to keep UI responsive.
        await Future<void>.delayed(Duration.zero);
      }

      final out = buffer.toString();
      debugPrint('PDFTRACE[${traceId ?? "no-trace"}] native_ocr:done nonEmptyPages=$nonEmptyPages chars=$totalChars outLen=${out.length}');
      return out;
    } catch (e) {
      debugPrint('PDFTRACE[${traceId ?? "no-trace"}] native_ocr:error $e');
      rethrow;
    } finally {
      try {
        await recognizer.close();
      } catch (_) {}
      try {
        await doc?.dispose();
      } catch (_) {}
    }
  }

  /// Converts ML Kit's block/line structure into a deterministic, line-based
  /// string. This makes the downstream parsing much closer to the web OCR output
  /// (which is typically newline-heavy).
  static String _recognizedTextToLineOrderedText(RecognizedText recognized) {
    try {
      final lines = <({String text, Rect? box})>[];
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          final t = line.text.trim();
          if (t.isEmpty) continue;
          lines.add((text: t, box: line.boundingBox));
        }
      }

      if (lines.isEmpty) return recognized.text;

      lines.sort((a, b) {
        final aBox = a.box;
        final bBox = b.box;
        if (aBox == null && bBox == null) return 0;
        if (aBox == null) return 1;
        if (bBox == null) return -1;
        // Primary: top, Secondary: left
        final dy = aBox.top.compareTo(bBox.top);
        if (dy != 0) return dy;
        return aBox.left.compareTo(bBox.left);
      });

      return lines.map((e) => e.text).join('\n');
    } catch (e) {
      debugPrint('NativeOcrService._recognizedTextToLineOrderedText error: $e');
      return recognized.text;
    }
  }
}
