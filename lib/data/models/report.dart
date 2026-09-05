/// Report projection models (Task T2). Pure Dart.
///
/// These are *read models*: computed by `ReportDao` SQL (phase R), never written
/// by a feature. They live in `data/models/` because reports are the one place
/// where three features' data (orders, payments, credits) legitimately meet —
/// the join happens in SQL, and the shape crossing the boundary is defined here.
library;

import '../../core/money/money.dart';
import '../../core/money/money_delta.dart';
import 'deep_eq.dart';
import 'enums.dart';

/// One day's headline numbers, the shape the owner actually reads.
final class DailyTotals {
  const DailyTotals({
    required this.day,
    required this.bills,
    required this.covers,
    required this.gross,
    required this.discount,
    required this.tax,
    required this.rounding,
    required this.netSales,
    required this.due,
    this.byMode = const <PaymentMode, Money>{},
    this.voidedBills = 0,
  });

  /// Day-only DateTime (normalise to midnight in the DAO) so the JSON key is stable.
  final DateTime day;
  final int bills;

  /// Items sold, not guests — "covers" here means tickets with >0 items, so the
  /// average-bill figure means "per ticket" (R1). Rename if you want guest counts.
  final int covers;

  final Money gross;
  final Money discount;
  final Money tax;

  /// Signed: the sum of every bill's ROUNDING line. Reports must not lose it, or
  /// `Σ bills != Σ tendered` and the shift count can never be reconciled.
  final MoneyDelta rounding;

  /// `gross - discount` (excludes tax).
  final Money netSales;

  /// Unpaid total across bills still open at day-end.
  final Money due;
  final Map<PaymentMode, Money> byMode;
  final int voidedBills;

  /// Rupees per ticket. Integer maths on purpose — a float average that prints
  /// `₹241.66666` on an owner screen reads as a bug even when it isn't.
  Money get averageBill => bills == 0 ? Money.zero : Money((netSales.paise * 100 / bills).round() ~/ 100);

  /// `netSales + tax + rounding` == what customers were actually charged.
  Money get charged => netSales + tax;

  bool get hasDue => due.isPositive;

  Map<String, Object?> toJson() => {
    'day': _dayKey(day),
    'bills': bills,
    'covers': covers,
    'grossPaise': gross.toJson(),
    'discountPaise': discount.toJson(),
    'taxPaise': tax.toJson(),
    'roundingPaise': rounding.toJson(),
    'netSalesPaise': netSales.toJson(),
    'duePaise': due.toJson(),
    'byMode': {for (final e in byMode.entries) e.key.name: e.value.toJson()},
    'voidedBills': voidedBills,
  };

  factory DailyTotals.fromJson(Map<String, Object?> j) => DailyTotals(
    day: DateTime.parse(j['day']! as String),
    bills: (j['bills'] as int?) ?? 0,
    covers: (j['covers'] as int?) ?? 0,
    gross: Money.fromJson(j['grossPaise'] ?? 0),
    discount: Money.fromJson(j['discountPaise'] ?? 0),
    tax: Money.fromJson(j['taxPaise'] ?? 0),
    rounding: MoneyDelta.fromJson(j['roundingPaise'] ?? 0),
    netSales: Money.fromJson(j['netSalesPaise'] ?? 0),
    due: Money.fromJson(j['duePaise'] ?? 0),
    byMode: {
      for (final raw in (j['byMode'] as Map<String, Object?>? ?? const <String, Object?>{}).entries)
        PaymentMode.fromName(raw.key): Money.fromJson(raw.value),
    },
    voidedBills: (j['voidedBills'] as int?) ?? 0,
  );

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  bool operator ==(Object other) =>
      other is DailyTotals &&
      other.runtimeType == runtimeType &&
      other.day == day &&
      other.bills == bills &&
      other.covers == covers &&
      other.gross == gross &&
      other.discount == discount &&
      other.tax == tax &&
      other.rounding == rounding &&
      other.netSales == netSales &&
      other.due == due &&
      deepEquals(other.byMode, byMode) &&
      other.voidedBills == voidedBills;

  @override
  int get hashCode => Object.hashAll([
      day,
      bills,
      covers,
      gross,
      discount,
      tax,
      rounding,
      netSales,
      due,
      deepHash(byMode),
      voidedBills,
    ]);
}

/// Bestsellers row (R3).
final class BestsellerRow {
  const BestsellerRow({
    required this.itemId,
    required this.name,
    required this.quantity,
    required this.revenue,
  });

  final String itemId;
  final String name;
  final int quantity;
  final Money revenue;

  Map<String, Object?> toJson() => {
    'itemId': itemId,
    'name': name,
    'quantity': quantity,
    'revenuePaise': revenue.toJson(),
  };

  factory BestsellerRow.fromJson(Map<String, Object?> j) => BestsellerRow(
    itemId: j['itemId']! as String,
    name: j['name']! as String,
    quantity: (j['quantity'] as int?) ?? 0,
    revenue: Money.fromJson(j['revenuePaise'] ?? 0),
  );

  @override
  bool operator ==(Object other) =>
      other is BestsellerRow &&
      other.runtimeType == runtimeType &&
      other.itemId == itemId &&
      other.name == name &&
      other.quantity == quantity &&
      other.revenue == revenue;

  @override
  int get hashCode => Object.hashAll([
      itemId,
      name,
      quantity,
      revenue,
    ]);
}

/// Outstanding-credit summary per party (R4 / Y4).
final class DueParty {
  const DueParty({
    required this.party,
    this.phone,
    required this.outstanding,
    required this.ticketCount,
    this.oldestAt,
  });

  final String party;
  final String? phone;
  final Money outstanding;
  final int ticketCount;
  final DateTime? oldestAt;

  /// Chances of collection, as an honest hint — not a decision the app enforces.
  bool get isAging =>
      oldestAt != null && DateTime.now().difference(oldestAt!).inDays > 30;

  Map<String, Object?> toJson() => {
    'party': party,
    'phone': phone,
    'outstandingPaise': outstanding.toJson(),
    'ticketCount': ticketCount,
    'oldestAt': oldestAt?.toIso8601String(),
  };

  factory DueParty.fromJson(Map<String, Object?> j) => DueParty(
    party: j['party']! as String,
    phone: j['phone'] as String?,
    outstanding: Money.fromJson(j['outstandingPaise'] ?? 0),
    ticketCount: (j['ticketCount'] as int?) ?? 0,
    oldestAt: j['oldestAt'] == null ? null : DateTime.parse(j['oldestAt']! as String),
  );

  @override
  bool operator ==(Object other) =>
      other is DueParty &&
      other.runtimeType == runtimeType &&
      other.party == party &&
      other.phone == phone &&
      other.outstanding == outstanding &&
      other.ticketCount == ticketCount &&
      other.oldestAt == oldestAt;

  @override
  int get hashCode => Object.hashAll([
      party,
      phone,
      outstanding,
      ticketCount,
      oldestAt,
    ]);
}

/// Hour-of-day buckets for the rush chart (R2).
final class HourBucket {
  const HourBucket({required this.hour, required this.revenue, required this.bills});

  final int hour;
  final Money revenue;
  final int bills;

  Map<String, Object?> toJson() => {
    'hour': hour,
    'revenuePaise': revenue.toJson(),
    'bills': bills,
  };

  factory HourBucket.fromJson(Map<String, Object?> j) => HourBucket(
    hour: j['hour']! as int,
    revenue: Money.fromJson(j['revenuePaise'] ?? 0),
    bills: (j['bills'] as int?) ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      other is HourBucket &&
      other.runtimeType == runtimeType &&
      other.hour == hour &&
      other.revenue == revenue &&
      other.bills == bills;

  @override
  int get hashCode => Object.hashAll([
      hour,
      revenue,
      bills,
    ]);
}
