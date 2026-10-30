import 'package:intl/intl.dart';

/// Quantities are Postgres `numeric`, so they arrive as `num` — sometimes `5`,
/// sometimes `5.0`. Render integers without a trailing `.0` and keep genuine
/// fractional quantities intact.
String formatQty(num value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value
      .toString()
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll(RegExp(r'\.$'), '');
}

String formatCurrency(num? value, {String currency = 'INR'}) {
  if (value == null) return '—';
  final symbol = switch (currency.toUpperCase()) {
    'INR' => '₹',
    'USD' => r'$',
    'EUR' => '€',
    _ => '$currency ',
  };
  return '$symbol${NumberFormat('#,##0.00').format(value)}';
}

final _dateFormat = DateFormat('d MMM yyyy, HH:mm');

String formatDateTime(DateTime value) => _dateFormat.format(value.toLocal());

String formatRelativeTime(DateTime value) {
  final delta = DateTime.now().toUtc().difference(value.toUtc());
  if (delta.isNegative) return 'just now';
  if (delta.inSeconds < 60) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  if (delta.inDays < 30) return '${delta.inDays}d ago';
  return _dateFormat.format(value.toLocal());
}

/// `2d ago` style, but reads as "never" for the epoch sentinel.
String formatLastFetched(DateTime? value) {
  if (value == null || value.millisecondsSinceEpoch == 0) return 'never';
  return formatRelativeTime(value);
}
