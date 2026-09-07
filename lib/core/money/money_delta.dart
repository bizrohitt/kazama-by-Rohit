/// Signed money delta — the counterpart to `Money` (Task T2, SKILLS.md §B5).
///
/// `Money` is deliberately unsigned: a bill total, a line amount or a cash
/// drawer balance can never legitimately be negative, and encoding that in the
/// type is what stops float/negative drift from ever reaching the ledger.
///
/// But three real POS quantities ARE signed:
///   * the `ROUNDING` line on a receipt (`-1p` when lines overshoot the total)
///   * a refund / price correction / void adjustment row
///   * an inventory movement (received +, sold -, spoiled -)
/// Those use this type, so `Money` keeps its invariant and the signed cases
/// stay explicit at the call site instead of becoming "any Money, hopefully".
library;

import 'money.dart';

final class MoneyDelta {
  const MoneyDelta(this.paise);

  static const MoneyDelta zero = MoneyDelta(0);

  /// Raw signed paise. This is what a delta column stores.
  final int paise;

  bool get isZero => paise == 0;
  bool get isPositive => paise > 0;
  bool get isNegative => paise < 0;

  MoneyDelta operator +(MoneyDelta other) => MoneyDelta(paise + other.paise);
  MoneyDelta operator -(MoneyDelta other) => MoneyDelta(paise - other.paise);
  MoneyDelta negate() => MoneyDelta(-paise);
  static MoneyDelta sum(Iterable<MoneyDelta> deltas) {
    var total = 0;
    for (final d in deltas) {
      total += d.paise;
    }
    return MoneyDelta(total);
  }

  /// Applying a delta to a balance. A negative result is ALWAYS a bug at the
  /// call site (a refund larger than the amount paid, a stock count below zero,
  /// a discount bigger than the subtotal), so it throws instead of clamping —
  /// clamping is how a till ends up silently printing a total nobody can audit.
  Money applyTo(Money base) {
    final result = base.paise + paise;
    if (result < 0) {
      throw ArgumentError(
        'delta $this would drive ${base.paise}p negative (result ${result}p) — '
        'reject the operation at the UI instead of clamping',
      );
    }
    return Money(result);
  }

  /// The signed amount by which [target] must be rounded up/down from [base].
  /// Used by the bill ROUNDING line, which may legitimately be negative.
  static MoneyDelta roundingFrom(Money base) =>
      MoneyDelta(base.roundedToRupee().paise - base.paise);

  int toJson() => paise;
  factory MoneyDelta.fromJson(Object? json) {
    if (json is int) return MoneyDelta(json);
    if (json is num) return MoneyDelta(json.round());
    throw FormatException('Cannot read a MoneyDelta from $json');
  }

  /// `+₹1.00` / `-₹0.01` — the sign is shown because a delta line is read by a
  /// human on a receipt, where "1.00" would be ambiguous.
  @override
  String toString() {
    if (paise == 0) return '₹0.00';
    final sign = paise < 0 ? '-' : '+';
    final abs = paise.abs();
    return '$sign₹${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
  }

  @override
  bool operator ==(Object other) => other is MoneyDelta && other.paise == paise;

  @override
  int get hashCode => paise.hashCode;
}

/// Kept as an extension so Task T1's `money.dart` stays frozen (it is already
/// device-verified ✅; a new getter there would force a re-test for no reason).
extension MoneyRounding on Money {
  /// Signed paise needed to reach the nearest whole rupee — may be negative.
  int get roundingSignedPaise => roundedToRupee().paise - paise;
  MoneyDelta get roundingDelta => MoneyDelta(roundingSignedPaise);
}
