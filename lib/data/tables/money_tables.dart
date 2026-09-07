/// Drift table definitions — payments, credit, staff, shifts, receipts (Task T3).
///
/// `payments` is a ledger table, not a column on `orders` (SKILLS.md §B3): a bill
/// paid "₹500 cash + ₹400 UPI + ₹300 udhaar" is three rows, and the split is what
/// both your billing flow and the reports need. `orders.paid_paise` is only a cache
/// of their sum — recomputed in the same transaction, cross-checked by
/// `assertPaidConsistency` in `data/models/payment.dart`.
///
/// **FK policy for this app:** child rows (`order_lines`) get real `references()`
/// with a cascade, because deleting a draft ticket legitimately removes its lines.
/// Money rows deliberately do NOT: a payment or a credit entry that points at a
/// removed ticket must survive as a record, so its `order_id` is a plain indexed
/// TEXT. Referential integrity there is a repository concern (T3/T5), not a
/// constraint that can be allowed to cascade away a sale.
library;

import 'package:drift/drift.dart';

@DataClassName('PaymentRow')
class Payments extends Table {
  TextColumn get id => text()();

  /// Plain indexed TEXT, NOT a cascading FK — see the FK policy above.
  TextColumn get orderId => text()();

  /// `PaymentMode.name`: cash | upi | card | credit.
  TextColumn get mode => text()();

  /// Amount applied to the bill. For cash this may be LESS than what was handed
  /// over, which is why tendered/change are separate columns.
  IntColumn get amountPaise => integer()();

  /// Notes physically received. Cash only — `Payment.validateShape` enforces that
  /// a non-cash row never carries these, so a UPI row cannot fake a drawer entry.
  IntColumn get tenderedPaise => integer().nullable()();
  IntColumn get changePaise => integer().nullable()();

  /// Free text (bank RRN, 'GPay 88213'). Unverified by design (Q5) — a memory
  /// aid for matching a payment notification, not a reconciliation record.
  TextColumn get reference => text().nullable()();
  TextColumn get recordedBy => text()();
  DateTimeColumn get at => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Index> get indexes => [
    Index(name: 'idx_payments_order', columns: [orderId]),
    /// Reports group by mode within a day (R2), so both columns go together.
    Index(name: 'idx_payments_mode_at', columns: [mode, at]),
  ];
}

@DataClassName('CreditEntryRow')
class CreditEntries extends Table {
  TextColumn get id => text()();

  /// Party name as typed at the counter ("Sharma ji", "Site B contract").
  TextColumn get party => text()();
  TextColumn get phone => text().nullable()();

  /// Always positive; the sign is implied by `kind`. Two row kinds beat one
  /// signed column because the due list becomes `SUM(due) - SUM(settled)` over
  /// one index instead of an expression index (R4).
  IntColumn get amountPaise => integer()();

  /// `CreditKind.name`: due | settled.
  TextColumn get kind => text()();
  TextColumn get note => text().nullable()();

  /// The ticket the due came from, when there is one. Nullable because a party
  /// can be credited a plain amount at the counter with no bill behind it.
  TextColumn get linkedOrderId => text().nullable()();
  TextColumn get createdBy => text()();
  DateTimeColumn get at => dateTime()();

  /// Set when a `settled` row closes this `due` row. Kept on both sides so the
  /// due list (Y4) needs no self-join.
  TextColumn get settlesEntryId => text().nullable()();
  DateTimeColumn get settledAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Index> get indexes => [
    Index(name: 'idx_credit_party_kind', columns: [party, kind]),
    Index(name: 'idx_credit_open', columns: [kind, settledAt]),
  ];
}

@DataClassName('UserRow')
class Users extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// `UserRole.name`: cashier | kitchen | manager.
  TextColumn get role => text()();

  /// SHA-256 hex of `salt + pin`, computed in `features/staff_auth/` (S1) — never
  /// in a model, so models stay free of crypto imports.
  TextColumn get pinHash => text()();

  /// Per-user random salt stored alongside the hash. That is normal: it stops two
  /// staff with PIN 1234 sharing a hash, it is not a secret. A 4-6 digit PIN over
  /// SHA-256 is brute-forceable in milliseconds by anyone holding the DB file, so
  /// this gate protects against *curious colleagues*, not against a thief — which
  /// is also why there is no server-side password reset in v1.
  TextColumn get pinSalt => text()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true)).named('active')();

  /// Lockout state lives on the row so a crash or app restart cannot reset it.
  IntColumn get failedAttempts => integer().withDefault(const Constant(0))();
  DateTimeColumn get lockedUntil => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ShiftRow')
class Shifts extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text()();
  IntColumn get openingFloatPaise => integer().withDefault(const Constant(0))();
  DateTimeColumn get openedAt => dateTime()();

  /// Null = shift still open. "At most one open shift per user" is enforced in
  /// the repository (S4) — a partial unique index would do it in SQL, but
  /// `drift` can't express one and the table is tiny either way.
  DateTimeColumn get closedAt => dateTime().nullable()();

  /// The cashier's physical count, entered at close (S4). Null until counted,
  /// which is what distinguishes "not closed yet" from "closed, ₹0 counted".
  IntColumn get countedCashPaise => integer().nullable()();
  TextColumn get note => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Index> get indexes => [Index(name: 'idx_shifts_user_open', columns: [userId, closedAt])];
}

/// Which slips actually reached a printer (P2/P4). Answers "was this bill printed
/// twice?" and records which transport produced it — the first thing you need when
/// a real printer starts misbehaving on the counter's Android version.
@DataClassName('ReceiptRow')
class Receipts extends Table {
  TextColumn get id => text()();
  TextColumn get orderId => text()();

  /// `ReceiptKind.name`: sale | due | voidReceipt | copy.
  TextColumn get kind => text()();

  /// 'fake' | 'bt:<mac>' | 'lan:<ip>' — recorded verbatim for debugging.
  TextColumn get transport => text()();
  BoolColumn get delivered => boolean()();
  TextColumn get printerName => text().nullable()();

  /// 32 (58 mm) or 48 (80 mm). Stored per receipt so a template change can never
  /// silently reflow an old reprint into something unreadable.
  IntColumn get paperWidthColumns => integer().withDefault(const Constant(32))();

  /// Where the rendered bytes went (the fake transport writes a shareable file).
  TextColumn get bytesPath => text().nullable()();
  TextColumn get error => text().nullable()();
  DateTimeColumn get at => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Index> get indexes => [Index(name: 'idx_receipts_order', columns: [orderId])];
}
