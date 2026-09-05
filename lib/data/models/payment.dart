/// Payment + credit models (Task T2). Pure Dart.
///
/// A bill is settled by a *list* of these rows, never by a status flag
/// (SKILLS.md §B3). `OrderTicket.paid` is a derived cache of their sum, and
/// `assertPaidConsistency` is what keeps the cache honest.
library;

import '../../core/money/money.dart';
import 'enums.dart';
import 'order.dart';

final class Payment {
  const Payment({
    required this.id,
    required this.orderId,
    required this.mode,
    required this.amount,
    this.tendered,
    this.change,
    this.reference,
    required this.recordedBy,
    required this.at,
  });

  final String id;
  final String orderId;
  final PaymentMode mode;

  /// How much of the bill this row settles. This is the number that reduces
  /// `due`, and for cash it may be less than what was physically handed over.
  final Money amount;

  /// Notes actually handed to the till. Cash only — UPI has no tender concept.
  final Money? tendered;

  /// Given back. Cash only, and always `tendered - amount` (never re-derived in
  /// the UI, or a reprint could show different change than the original did).
  final Money? change;

  /// Free text: 'GPay', 'HDFC ••4412', bank RRN. Unverified by design (Q5).
  final String? reference;
  final String recordedBy;
  final DateTime at;

  bool get isCash => mode == PaymentMode.cash;
  bool get createsADue => mode.createsADue;

  /// Change the drawer owes for this row, or null when it isn't a cash row.
  Money get changeOrZero => change ?? Money.zero;

  Payment copyWith({Money? amount, String? reference, Money? tendered, Money? change}) => Payment(
    id: id,
    orderId: orderId,
    mode: mode,
    amount: amount ?? this.amount,
    tendered: tendered ?? this.tendered,
    change: change ?? this.change,
    reference: reference ?? this.reference,
    recordedBy: recordedBy,
    at: at,
  );

  /// A cash row cannot settle more than it received — the drawer cannot invent change.
  void validateShape() {
    if (!amount.isPositive) {
      throw ArgumentError('A payment row of ₹0 records nothing; skip it instead');
    }
    if (isCash && tendered != null && tendered! < amount) {
      throw ArgumentError(
        'Cash tendered ${tendered!.paise}p is less than the amount applied ${amount.paise}p',
      );
    }
    if (!isCash && (tendered != null || change != null)) {
      throw ArgumentError('tendered/change are cash-only fields (mode: ${mode.name})');
    }
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'orderId': orderId,
    'mode': mode.name,
    'amountPaise': amount.toJson(),
    'tenderedPaise': tendered?.toJson(),
    'changePaise': change?.toJson(),
    'reference': reference,
    'recordedBy': recordedBy,
    'at': at.toIso8601String(),
  };

  factory Payment.fromJson(Map<String, Object?> j) => Payment(
    id: j['id']! as String,
    orderId: j['orderId']! as String,
    mode: PaymentMode.fromName(j['mode'] as String?),
    amount: Money.fromJson(j['amountPaise']),
    tendered: j['tenderedPaise'] == null ? null : Money.fromJson(j['tenderedPaise']),
    change: j['changePaise'] == null ? null : Money.fromJson(j['changePaise']),
    reference: j['reference'] as String?,
    recordedBy: j['recordedBy']! as String,
    at: DateTime.parse(j['at']! as String),
  );

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is Payment &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.orderId == orderId &&
      other.mode == mode &&
      other.amount == amount &&
      other.tendered == tendered &&
      other.change == change &&
      other.reference == reference &&
      other.recordedBy == recordedBy &&
      other.at == at;

  @override
  int get hashCode => Object.hashAll([
      id.hashCode,
      orderId.hashCode,
      mode.hashCode,
      amount.hashCode,
      tendered.hashCode,
      change.hashCode,
      reference.hashCode,
      recordedBy.hashCode,
      at.hashCode,
    ]);
}

/// Udhaar / pay-later. Needed by the dine-in flow you described (Q4): a guest
/// may leave with `due > 0` and `status: partiallyPaid`, or even `served` +
/// unpaid, and settle at another time — so a due is a first-class record, not a
/// missing payment row.
final class CreditEntry {
  const CreditEntry({
    required this.id,
    required this.party,
    required this.amount,
    required this.kind,
    this.phone,
    this.note,
    this.linkedOrderId,
    required this.at,
    this.settledAt,
  });

  final String id;
  final String party;
  final Money amount;
  final CreditKind kind;
  final String? phone;
  final String? note;
  final String? linkedOrderId;
  final DateTime at;
  final DateTime? settledAt;

  bool get isOutstanding => kind == CreditKind.due && settledAt == null;

  Map<String, Object?> toJson() => {
    'id': id,
    'party': party,
    'amountPaise': amount.toJson(),
    'kind': kind.name,
    'phone': phone,
    'note': note,
    'linkedOrderId': linkedOrderId,
    'at': at.toIso8601String(),
    'settledAt': settledAt?.toIso8601String(),
  };

  factory CreditEntry.fromJson(Map<String, Object?> j) => CreditEntry(
    id: j['id']! as String,
    party: j['party']! as String,
    amount: Money.fromJson(j['amountPaise']),
    kind: CreditKind.values.firstWhere(
      (e) => e.name == j['kind'],
      orElse: () => CreditKind.due,
    ),
    phone: j['phone'] as String?,
    note: j['note'] as String?,
    linkedOrderId: j['linkedOrderId'] as String?,
    at: DateTime.parse(j['at']! as String),
    settledAt: j['settledAt'] == null ? null : DateTime.parse(j['settledAt']! as String),
  );

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is CreditEntry &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.party == party &&
      other.amount == amount &&
      other.kind == kind &&
      other.phone == phone &&
      other.note == note &&
      other.linkedOrderId == linkedOrderId &&
      other.at == at &&
      other.settledAt == settledAt;

  @override
  int get hashCode => Object.hashAll([
      id.hashCode,
      party.hashCode,
      amount.hashCode,
      kind.hashCode,
      phone.hashCode,
      note.hashCode,
      linkedOrderId.hashCode,
      at.hashCode,
      settledAt.hashCode,
    ]);
}

enum CreditKind {
  due('Due'),
  settled('Settled');

  const CreditKind(this.label);
  final String label;
}

/// Convenience for the billing screen: what's been paid per mode, so a bill
/// paid "₹500 cash + ₹400 UPI" prints both lines instead of one lump.
final class PaymentSummary {
  const PaymentSummary({required this.byMode, required this.total, required this.changeGiven});

  final Map<PaymentMode, Money> byMode;
  final Money total;
  final Money changeGiven;

  static PaymentSummary of(List<Payment> payments) {
    final byMode = <PaymentMode, Money>{};
    var change = Money.zero;
    for (final p in payments) {
      byMode[p.mode] = (byMode[p.mode] ?? Money.zero) + p.amount;
      change = change + p.changeOrZero;
    }
    return PaymentSummary(
      byMode: byMode,
      total: Money.sum(payments.map((p) => p.amount)),
      changeGiven: change,
    );
  }

  List<PaymentMode> get modesUsed => byMode.keys.toList(growable: false);
}

/// Cross-check used by the repository after every payment write and by the
/// report generator: the ticket's cached `paid` must equal the ledger.
void assertPaidConsistency(OrderTicket ticket, List<Payment> payments) {
  final ledger = PaymentSummary.of(payments).total;
  if (ledger.paise != ticket.paid.paise) {
    throw StateError(
      'Ticket ${ticket.id}: paid cache says ${ticket.paid.paise}p but the payment '
      'rows sum to ${ledger.paise}p — recompute from the ledger, never trust the cache',
    );
  }
  if (ticket.paid > ticket.total) {
    throw StateError(
      'Ticket ${ticket.id}: overpaid by ${(ticket.paid - ticket.total).paise}p. '
      'The billing UI must reject, not clamp.',
    );
  }
}

/// The `payments` row, in database-friendly types (ints, enum names). A model
/// that knew about drift companions would drag the DB layer into every widget
/// test; a model that knows nothing about the table would let the DAO invent
/// column names. This is the seam: names live here, `Value()` wrapping lives
/// there, and `tools/check_models.dart` can assert the two agree.
class PaymentRowData {
  const PaymentRowData(this.p);

  final Payment p;

  /// Cash physically added to the drawer by this row: what was handed over
  /// (the applied amount, for a non-cash mode) minus the change given back.
  /// A ₹100 note against a ₹40 bill is +₹100 here and −₹60 of change, so a
  /// till counted against `amount` alone appears to have a ₹60 overage.
  static int drawerPaise({required int amountPaise, int? tenderedPaise, int? changePaise}) =>
      (tenderedPaise ?? amountPaise) - (changePaise ?? 0);

  Map<String, Object?> toColumns() => {
    'id': p.id,
    'order_id': p.orderId,
    'mode': p.mode.name,
    'amount_paise': p.amount.paise,
    'tendered_paise': p.tendered?.paise,
    'change_paise': p.change?.paise,
    'reference': p.reference,
    'recorded_by': p.recordedBy,
    'at': p.at.toIso8601String(),
  };
}
