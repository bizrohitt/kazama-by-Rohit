/// Drift table definitions — ticket, lines, audit events, sync outbox (Task T3).
///
/// Three rules encoded here, all of them hard to retrofit:
///  1. `orders` carries BOTH halves of the counter flow (lines from order-taking,
///     money from billing) so a held ticket is a query, not a second data source.
///  2. `order_events` is append-only with no FK cascade — the till's forensic
///     trail (SKILLS.md §C5). Deleting it to "clean up" breaks shift audits.
///  3. `bill_number` is allocated locally and UNIQUE. A nullable UNIQUE column
///     allows many NULLs in SQLite, which is exactly what an unsaved draft needs.
library;

import 'package:drift/drift.dart';

@DataClassName('OrderRow')
class Orders extends Table {
  TextColumn get id => text()();

  /// Null while the ticket is an unnumbered draft.
  IntColumn get billNumber => integer().nullable().unique()();
  /// `OrderType.name` — stored as text, see the file header.
  TextColumn get type => text()();

  /// `OrderStatus.name`.
  TextColumn get status => text()();

  /// Table number for dine-in, name for a due, phone for delivery. Also the
  /// search key of the held-tickets list (O4), hence indexed with status.
  TextColumn get tableOrName => text().nullable()();
  TextColumn get note => text().nullable()();

  /// Discount *intent*, re-evaluated on reprint so a rounding fix changes the
  /// maths but not what the cashier chose. `discount_kind` selects the unit:
  /// 0 = none, 1 = absolute paise, 2 = percent (mirrors `DiscountKind.index`).
  IntColumn get discountKind => integer().withDefault(const Constant(0))();
  IntColumn get discountValue => integer().withDefault(const Constant(0))();
  IntColumn get subtotalPaise => integer().withDefault(const Constant(0))();
  IntColumn get taxPaise => integer().withDefault(const Constant(0))();
  IntColumn get totalPaise => integer().withDefault(const Constant(0))();
  IntColumn get paidPaise => integer().withDefault(const Constant(0))();
  IntColumn get duePaise => integer().withDefault(const Constant(0))();

  /// Signed paise of the bill's ROUNDING line (SKILLS.md §B5). Stored per bill,
  /// not re-derived, so a reprint matches what was originally charged.
  IntColumn get roundingPaise => integer().withDefault(const Constant(0))();
  TextColumn get voidReason => text().nullable()();
  TextColumn get openedBy => text()();
  DateTimeColumn get openedAt => dateTime()();
  DateTimeColumn get firedAt => dateTime().nullable()();
  DateTimeColumn get readyAt => dateTime().nullable()();
  DateTimeColumn get servedAt => dateTime().nullable()();
  DateTimeColumn get closedAt => dateTime().nullable()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Index> get indexes => [
    /// The due list and the KDS both filter on exactly this pair (O4, K1).
    Index(name: 'idx_orders_status_updated', columns: [status, updatedAt]),
    Index(name: 'idx_orders_bill', columns: [billNumber], isUnique: false),
  ];
}

@DataClassName('OrderLineRow')
class OrderLines extends Table {
  TextColumn get id => text()();
  TextColumn get orderId => text().references(Orders, #id, onDelete: KeyAction.cascade)();

  /// Null for a one-off line typed at the counter ("extra plate ₹20") — allowed
  /// because a held bill must be fixable without inventing a menu item.
  TextColumn get itemId => text().nullable()();

  /// Frozen at order time. Editing the menu never rewrites history (M4 vs O2).
  TextColumn get nameSnapshot => text()();
  TextColumn get kitchenLabelSnapshot => text().nullable()();
  IntColumn get unitPricePaise => integer()();
  IntColumn get taxPercent => integer().withDefault(const Constant(5))();

  /// Full JSON array of `ModifierOption` snapshots (name + price delta), not ids:
  /// a modifier deleted from the menu must still print on yesterday's receipt.
  TextColumn get modifiersJson => text().withDefault(const Constant('[]'))();
  IntColumn get quantity => integer().withDefault(const Constant(1))();

  /// Units cancelled out of `quantity` (O6). Kept separate so reports can show
  /// ordered-vs-served instead of a silently shrunk line.
  IntColumn get cancelledQuantity => integer().withDefault(const Constant(0))();
  TextColumn get lineStatus => text().withDefault(const Constant('pending'))();
  TextColumn get note => text().nullable()();

  /// Only fired/ready/served lines consume stock (I2); pending ones must not.
  IntColumn get sortIndex => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Index> get indexes => [
    Index(name: 'idx_lines_order', columns: [orderId]),
    Index(name: 'idx_lines_status', columns: [lineStatus]),
  ];
}

/// Append-only audit trail. No updates, no deletes, no FK cascade — a void or a
/// price override made at 22:41 must still be reconstructable in six months.
@DataClassName('OrderEventRow')
class OrderEvents extends Table {
  IntColumn get seq => integer().autoIncrement()();
  TextColumn get orderId => text()();
  TextColumn get eventType => text()();

  /// JSON payload; may be empty for plain state changes.
  TextColumn get payloadJson => text().withDefault(const Constant('{}'))();
  TextColumn get actorId => text()();
  DateTimeColumn get at => dateTime()();

  @override
  Set<Column> get primaryKey => {seq};

  @override
  List<Index> get indexes => [Index(name: 'idx_events_order', columns: [orderId])];
}

/// Outbox (SKILLS.md §C1). Written inside the SAME transaction as the business
/// row — a split write is how an offline till silently loses a sale.
@DataClassName('SyncOutboxRow')
class SyncOutbox extends Table {
  TextColumn get id => text()();
  TextColumn get entity => text()();
  TextColumn get entityId => text()();

  /// INSERT / UPDATE / DELETE (the `MutationOp.wire` vocabulary).
  TextColumn get op => text()();

  /// Full post-write row as JSON, so a replay needs no join and no re-read.
  TextColumn get payloadJson => text()();

  /// Re-sending the same key must be a server-side no-op — this is the only
  /// reason an offline retry can never double-post a sale.
  TextColumn get idempotencyKey => text().unique()();
  TextColumn get deviceId => text().withDefault(const Constant('primary'))();
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  /// pending | in_flight | stuck. A stuck row is a bug report, not a lost sale:
  /// the data is on-device either way (T5).
  TextColumn get status => text().withDefault(const Constant('pending'))();

  /// Why a row is still here, for the settings screen's "unsynced" badge. Kept
  /// nullable and short (the engine truncates it): losing the last error is
  /// never a reason to refuse an insert, and a full stack trace per row would
  /// make this the biggest table in the snapshot.
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get queuedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Index> get indexes => [
    /// Drain order: oldest pending first (T5 batches 50 at a time).
    Index(name: 'idx_outbox_status_queued', columns: [status, queuedAt]),
  ];
}
