/// Kazama POS — integer minor-unit money.
///
/// Part of Task T1. **Pure Dart on purpose**: this file must never import
/// `package:flutter/...`, `dart:io`, or drift, so it is unit-testable with the
/// bare Dart CLI (`dart run tools/check_money.dart`) and reusable by any future
/// CLI/report generator. See SKILLS.md §B1.
///
/// Why paise and not `double`: ₹0.1 + ₹0.2 is 0.30000000000000004 in binary
/// floating point. A till that accumulates that error across a split-payment
/// bill, a 3-line discount and a change calculation will disagree with its own
/// printed receipt. So every money column in the app is `INTEGER paise`, and
/// `double` is only ever touched inside [Money.parse] and [Money.toString].
library;

/// A non-negative amount of Indian rupees stored as an integer number of paise.
///
/// Invariants (enforced on construction, relied on everywhere):
///  * `paise >= 0` — a negative money value is always a bug at the call site,
///    never a legitimate state. Debts/dues are modelled as their own rows.
///  * Immutable and value-equal, so it can be used as a map key and compared
///    in tests without an accessor dance.
final class Money implements Comparable<Money> {
  Money(this.paise) {
    if (paise < 0) {
      throw ArgumentError.value(
        paise,
        'paise',
        'Money cannot be negative — represent a due as its own amount instead',
      );
    }
  }

  /// Raw constructor for values that are already in paise (DB columns, math results).
  factory Money.fromPaise(int paise) => Money(paise);

  /// From a rupee amount, e.g. `Money.rupees(12.5)` -> `1250` paise.
  /// Rounding here is only a *conversion* convenience; never use it to round a bill.
  factory Money.rupees(num rupees) =>
      Money((rupees * 100).round());

  /// The zero amount. Prefer this over `Money(0)` at call sites for readability.
  static const Money zero = Money._internal(0);
  const Money._internal(this.paise);

  /// The canonical amount stored in paise. This is exactly what goes in the DB.
  final int paise;

  bool get isZero => paise == 0;
  bool get isPositive => paise > 0;

  int get rupeePart => paise ~/ 100;
  int get paisePart => paise % 100;

  // ---------------------------------------------------------------- parsing --

  /// Parses counter input: `'120'`, `'120.5'`, `'₹1,20,000.50'`, `'Rs 45.00'`.
  ///
  /// Deliberately permissive about the decoration (a numeric keypad and an
  /// Indian comma-grouped amount both end up here) and deliberately strict about
  /// the number itself: garbage throws [FormatException] rather than silently
  /// becoming ₹0, because a silent zero on a payment screen is a theft nobody
  /// can audit later.
  factory Money.parse(String input) {
    var s = input.trim();
    if (s.isEmpty) {
      throw const FormatException('Empty amount');
    }
    s = s
        .replaceAll('₹', '')
        .replaceAll('Rs.', '')
        .replaceAll('Rs', '')
        .replaceAll(',', '')
        .replaceAll(' ', '')
        .trim();
    if (s.isEmpty || !_amountPattern.hasMatch(s)) {
      throw FormatException('Not a valid amount', input);
    }
    final dot = s.indexOf('.');
    var whole = dot == -1 ? s : s.substring(0, dot);
    var frac = dot == -1 ? '' : s.substring(dot + 1);

    if (frac.length > 2) {
      // Sub-paise precision is not a thing we can hold; round, don't truncate,
      // so `12.999` is ₹13.00 and not ₹12.99. The carry must reach `whole`,
      // otherwise .999 silently becomes .00 and ₹12.999 turns into ₹12.00.
      final roundedPaise = int.parse(frac.substring(0, 2)) +
          (int.parse(frac[2]) >= 5 ? 1 : 0);
      if (roundedPaise > 99) {
        whole = (int.parse(whole) + 1).toString();
        frac = '00';
      } else {
        frac = roundedPaise.toString().padLeft(2, '0');
      }
    } else {
      frac = frac.padRight(2, '0');
    }

    return Money(int.parse(whole) * 100 + int.parse(frac));
  }

  static final RegExp _amountPattern = RegExp(r'^\d+(\.\d*)?$');

  // -------------------------------------------------------------- arithmetic --

  Money operator +(Money other) => Money(paise + other.paise);
  Money operator -(Money other) => Money(paise - other.paise);
  Money scale(int factor) => Money(paise * factor);

  /// Sum of an iterable; [Money.zero] for an empty one (never null, never throw).
  static Money sum(Iterable<Money> amounts) {
    var total = Money.zero;
    for (final a in amounts) {
      total = total + a;
    }
    return total;
  }

  /// Integer `n * paise / 100`, rounded half-up. The workhorse for tax/percent.
  Money percentOf(int percentBps) =>
      Money(_roundHalfUpDiv(paise * percentBps, 100 * 100));

  // ---------------------------------------------------------- integer maths --

  /// Half-up rounding of `num ~/ den`, for non-negative inputs, with no floats.
  ///
  /// `1375 * 5 = 6875`; `6875 ~/ 100 = 68`, and `(6875 + 50) ~/ 100 = 69`.
  static int _roundHalfUpDiv(int num, int den) => (num + den ~/ 2) ~/ den;

  // -------------------------------------------------------------- tax maths --
  //
  /// GST extraction from a **tax-inclusive** line total.
  ///
  /// Why the formula is `gross * t / (100 + t)` and not `gross / 1.18`: the
  /// division version needs a float and produces 216.9491525 for ₹1400 @18%,
  /// which then rounds differently depending on which half of the CPU you ask.
  /// This one is int-only, so it is deterministic on every device.
  ///
  /// Guaranteed `0 <= tax <= gross` even for absurd percents (which is what
  /// makes a mistyped 150% in the menu editor non-critical).
  static Money taxFromInclusive(Money gross, int percent) {
    if (percent <= 0 || !gross.isPositive) return Money.zero;
    final raw = _roundHalfUpDiv(gross.paise * percent, 100 + percent);
    return Money(raw < 0 ? 0 : (raw > gross.paise ? gross.paise : raw));
  }

  /// GST added on top of a **tax-exclusive** line total.
  static Money taxOnExclusive(Money base, int percent) {
    if (percent <= 0 || !base.isPositive) return Money.zero;
    final raw = _roundHalfUpDiv(base.paise * percent, 100);
    return Money(raw < 0 ? 0 : raw);
  }

  /// Gross = base + tax, for an exclusive price. Kept here so callers never add
  /// tax by hand and forget a line.
  static Money grossFromExclusive(Money base, int percent) =>
      base + taxOnExclusive(base, percent);

  // ------------------------------------------------------------- bill rules --

  /// Cash-drawer rounding: the nearest whole rupee, half up.
  ///
  /// ₹285.01 and ₹284.99 both become ₹285.00; ₹285.50 becomes ₹286.00.
  Money roundedToRupee() => Money(((paise + 50) ~/ 100) * 100);

  /// The paise that must be **added** to this amount to reach [roundedToRupee].
  ///
  /// Printed as its own `ROUNDING` line on the receipt (SKILLS.md §B2 step 5).
  /// Without it the itemised lines would foot to ₹285.01 while the total says
  /// ₹285.00, and the owner's manual count would never match the register.
  /// Always >= 0: rounding here is only ever *upward* to the rupee, which is
  /// what a drawer short of 1-paise coins needs.
  Money get roundingAdjustment => roundedToRupee() - this;

  /// Change given back for [tendered] against [bill]. Throws if underpaid —
  /// an underpayment is a UI decision ("still due ₹X"), not a negative number.
  static Money changeFor({required Money tendered, required Money bill}) {
    if (tendered.paise < bill.paise) {
      throw ArgumentError(
        'Tendered ${tendered.paise}p < bill ${bill.paise}p — this is a due, not change',
      );
    }
    return tendered - bill;
  }

  // --------------------------------------------------- allocation (fair split)

  /// Splits [total] across [weights] proportionally, losing no paise.
  ///
  /// Used for allocating a bill-level discount or tax across lines: naive
  /// per-line rounding of ₹10.00 across 3 lines gives 333+333+333 = ₹9.99, i.e.
  /// a lost paisa that no report can explain. This does largest-remainder
  /// allocation: exact floors first, then the leftover paise handed out to the
  /// largest fractional remainders (ties -> lower index, so it is reproducible).
  static List<Money> split(Money total, List<int> weights) {
    if (total.paise == 0) return [for (final _ in weights) Money.zero];
    var weightSum = 0;
    for (final w in weights) {
      if (w < 0) throw ArgumentError('Weights must be >= 0');
      weightSum += w;
    }
    if (weightSum <= 0) {
      // Equal-share fallback so a zero-weight edge (all lines free) still foots.
      final each = total.paise ~/ weights.length;
      final extra = total.paise - each * weights.length;
      return [
        for (var i = 0; i < weights.length; i++)
          Money(each + (i < extra ? 1 : 0)),
      ];
    }

    final floors = <int>[];
    final remainders = <int>[];
    for (final w in weights) {
      final scaled = total.paise * w;
      floors.add(scaled ~/ weightSum);
      remainders.add(scaled % weightSum);
    }
    var assigned = 0;
    for (final f in floors) {
      assigned += f;
    }
    var leftover = total.paise - assigned;

    final order = [for (var i = 0; i < weights.length; i++) i]
      ..sort((a, b) {
        final byRemainder = remainders[b].compareTo(remainders[a]);
        return byRemainder != 0 ? byRemainder : a.compareTo(b);
      });

    final out = List<int>.from(floors);
    var idx = 0;
    while (leftover > 0) {
      out[order[idx % order.length]] += 1;
      leftover -= 1;
      idx += 1;
    }
    return out.map(Money.fromPaise).toList(growable: false);
  }

  // --------------------------------------------------------------- plumbing --

  /// Value used by drift: the `INTEGER paise` column. Symmetric with [toJson].
  int toJson() => paise;

  factory Money.fromJson(Object? json) {
    if (json is int) return Money(json);
    if (json is num) return Money(json.round());
    if (json is String) return Money.parse(json);
    throw FormatException('Cannot read a Money value from $json');
  }

  /// `1250` paise -> `'₹12.50'`. Display-only: never feed this back into maths.
  @override
  String toString() => '₹$rupeePart.${paisePart.toString().padLeft(2, '0')}';

  String toCompactString() => '$rupeePart.${paisePart.toString().padLeft(2, '0')}';

  @override
  int compareTo(Money other) => paise.compareTo(other.paise);

  bool operator <(Money other) => paise < other.paise;
  bool operator <=(Money other) => paise <= other.paise;
  bool operator >(Money other) => paise > other.paise;
  bool operator >=(Money other) => paise >= other.paise;

  @override
  bool operator ==(Object other) => other is Money && other.paise == paise;

  @override
  int get hashCode => paise.hashCode;
}
