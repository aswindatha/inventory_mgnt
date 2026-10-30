/// Small, total coercion helpers for decoding Postgres rows.
///
/// PostgREST hands back `dynamic` maps. These keep the model constructors free
/// of `as` casts that explode on a null column.
library;

DateTime parseTimestamp(Object? value, {DateTime? fallback}) {
  if (value is DateTime) return value;
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    if (parsed != null) return parsed.toUtc();
  }
  return fallback ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
}

DateTime? parseTimestampOrNull(Object? value) =>
    value == null ? null : parseTimestamp(value);

num parseNum(Object? value, {num fallback = 0}) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value) ?? fallback;
  return fallback;
}

num? parseNumOrNull(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value);
  return null;
}

int parseInt(Object? value, {int fallback = 0}) =>
    parseNum(value, fallback: fallback).toInt();

String parseString(Object? value, {String fallback = ''}) =>
    value is String ? value : (value?.toString() ?? fallback);

String? parseStringOrNull(Object? value) {
  if (value == null) return null;
  final s = value is String ? value : value.toString();
  return s.isEmpty ? null : s;
}

bool parseBool(Object? value, {bool fallback = false}) =>
    value is bool ? value : fallback;

bool? parseBoolOrNull(Object? value) => value is bool ? value : null;

/// Drops keys whose value is `null` so PostgREST applies column defaults
/// instead of writing explicit nulls.
Map<String, Object?> compact(Map<String, Object?> map) =>
    Map.fromEntries(map.entries.where((e) => e.value != null));
