/// Tiny structural equality helper (Task T2).
///
/// Value equality on these models exists for ONE reason: so a JSON round-trip
/// can be asserted as `Model.fromJson(m.toJson()) == m`, which catches a field
/// dropped from either `toJson` or `fromJson`. Dart's `==` on List/Map is
/// identity, so nested collections need a deep compare — and pulling in
/// `package:collection` (BSD-3) for one function would also break the
/// "logic files import nothing" rule these models follow (SKILLS.md §A2).
library;

import 'dart:convert';

bool deepEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k)) return false;
      if (!deepEquals(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Set && b is Set) {
    if (a.length != b.length) return false;
    for (final e in a) {
      if (!b.contains(e)) return false;
    }
    return true;
  }
  return a == b;
}

/// Equality for a nested model value (e.g. a `Money` or `MoneyDelta` field that
/// already implements `==` but is wrapped in a collection).
bool moneyLikeEquals(Object? a, Object? b) => deepEquals(a, b);

/// Stable hash for a nested collection, matching `deepEquals` semantics.
int deepHash(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => '${k}:${_hashEntry(value[k])}').toList()..sort();
    return Object.hashAll(keys);
  }
  if (value is List) return Object.hashAll(value.map(_hashEntry));
  if (value is Set) return Object.hashAllUnordered(value.map(_hashEntry));
  return value.hashCode;
}

int _hashEntry(Object? v) {
  if (v is Map || v is List || v is Set) return deepHash(v);
  return v.hashCode;
}

/// Used by the check script to prove `toJson` output is JSON-encodable at all
/// (a stray `DateTime` or non-primitive map key only blows up in `jsonEncode`,
/// never in a `==` comparison).
String encodeStable(Object? value) => jsonEncode(value);
