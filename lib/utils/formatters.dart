import 'package:flutter/foundation.dart';

/// Safe number formatting helpers.
///
/// Rationale: `double.toStringAsFixed()` throws when the value is `NaN` or
/// `Infinity`. These helpers guarantee we never crash the UI for non-finite
/// values and we log once per call site via [debugPrint] for diagnosis.
class Formatters {
  const Formatters._();

  static String fixed(num? v, {int decimals = 2, String placeholder = '—'}) {
    if (v == null) return placeholder;
    final d = v.toDouble();
    if (!d.isFinite) {
      debugPrint('Non-finite number encountered in Formatters.fixed(): $d');
      return placeholder;
    }
    return d.toStringAsFixed(decimals);
  }

  static String money(num? v, {int decimals = 2, String placeholder = '—', String symbol = r'$'}) {
    final s = fixed(v, decimals: decimals, placeholder: placeholder);
    return s == placeholder ? placeholder : '$symbol$s';
  }

  static String percent(num? ratio, {String placeholder = '—'}) {
    if (ratio == null) return placeholder;
    final r = ratio.toDouble();
    if (!r.isFinite) {
      debugPrint('Non-finite ratio encountered in Formatters.percent(): $r');
      return placeholder;
    }
    final decimals = r.abs() >= 0.1 ? 1 : 2;
    return '${(r * 100).toStringAsFixed(decimals)}%';
  }
}
