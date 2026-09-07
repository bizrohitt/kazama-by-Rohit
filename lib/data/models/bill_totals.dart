/// Bill arithmetic (Task T2) — split out of order.dart for the 600-line rule (R2).
///
/// A pure value type on purpose: nothing here touches drift, so a reviewer can
/// check a printed receipt against this file alone, and `tools/check_money.dart`
/// can exercise it without a database.
library;

import '../../core/money/money.dart';
import '../../core/money/money_delta.dart';
import 'enums.dart';
import 'order_line.dart';

/// Totals recomputed from the lines every time — never stored as truth on the
/// model, only written to `orders` columns as a cache for fast report queries.
final class BillTotals {
  const BillTotals({
    required this.base,
    required this.tax,
    required this.discount,
    required this.netBeforeTax,
    required this.rounding,
    required this.total,
  });

  /// Taxable value after discount, before tax.
  final Money base;
  final Money tax;
  final Money discount;

  /// What the goods cost after discount, excluding tax: `total - tax`.
  /// Defined against the rounded total so `net + tax == total` on the printed bill.
  final Money netBeforeTax;

  /// Sum of line bases (each line's inclusive total minus its tax) before discount.
  final Money lineBase;

  /// Signed paise that makes the printed total foot to a whole rupee.
  final MoneyDelta rounding;

  /// The number on the receipt. `netBeforeTax + tax` (exact, by construction).
  final Money total;

  /// Value of everything ordered before any discount, shown as "Gross" on reports.
  Money get grossBeforeDiscount => lineBase;

  static BillTotals compute({
    required List<TicketLine> lines,
    OrderDiscount discount = OrderDiscount.none,
  }) {
    final live = lines.where((l) => !l.isFullyCancelled).toList(growable: false);
    final lineBase = Money.sum(live.map((l) => l.base));
    final lineGross = Money.sum(live.map((l) => l.lineTotal));
    final discountAmount = discount.amountFor(lineGross);

    Money tax;
    if (live.isEmpty) {
      tax = Money.zero;
    } else {
      // Allocate the discount proportionally to each line's base, then recompute
      // tax on the discounted base (SKILLS.md §B2 step 4). Rounding tax on the
      // undiscounted total is how a discounted bill ends up over-charging GST.
      final shares = Money.split(discountAmount, [for (final l in live) l.base.paise]);
      var acc = Money.zero;
      for (var i = 0; i < live.length; i++) {
        acc += Money.taxOnExclusive(live[i].base - shares[i], live[i].taxPercent);
      }
      tax = acc;
    }

    final base = lineBase - discountAmount;
    final unrounded = base + tax;
    final rounded = unrounded.roundedToRupee();
    return BillTotals(
      base: base,
      tax: tax,
      discount: discountAmount,
      // Net + tax must equal the grand total *as printed*, so net is defined
      // against the rounded total: the ROUNDING line belongs to the goods, not
      // to the tax slab. Deriving it as `base + rounding` instead leaves the
      // receipt one paisa short of footing whenever rounding is negative.
      netBeforeTax: rounded - tax,
      lineBase: lineBase,
      rounding: MoneyDelta(rounded.paise - unrounded.paise),
      total: rounded,
    );
  }

  Map<String, Object?> toJson() => {
    'basePaise': base.toJson(),
    'taxPaise': tax.toJson(),
    'discountPaise': discount.toJson(),
    'netBeforeTaxPaise': netBeforeTax.toJson(),
    'lineBasePaise': lineBase.toJson(),
    'roundingPaise': rounding.toJson(),
    'totalPaise': total.toJson(),
  };

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is BillTotals &&
      other.runtimeType == runtimeType &&
      other.base == base &&
      other.tax == tax &&
      other.discount == discount &&
      other.netBeforeTax == netBeforeTax &&
      other.lineBase == lineBase &&
      other.rounding == rounding &&
      other.total == total;

  @override
  int get hashCode => Object.hashAll([
      base.hashCode,
      tax.hashCode,
      discount.hashCode,
      netBeforeTax.hashCode,
      lineBase.hashCode,
      rounding.hashCode,
      total.hashCode,
    ]);
}
