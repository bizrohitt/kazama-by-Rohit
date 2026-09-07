/// Secondary DAOs (Tasks I1-I3, S1-S4, R1-R4, Y4).
///
/// Split out of `orders_dao.dart` for the 600-line rule (R2). They live in the
/// same `app_database.dart` library because that is what lets a DAO call
/// `select(table)` without importing drift twice over — see the header of
/// `menu_dao.dart` for the reasoning.
library;

part of '../../core/db/app_database.dart';

/// Credit ledger access. Separate DAO because credit is a *customer* record that
/// outlives tickets (a settle row may arrive weeks later), even though it is
/// opened by a ticket.
class CreditDao extends KazamaDao {
  Future<void> insertDue({
    required String id,
    required String party,
    required int amountPaise,
    String? phone,
    String? note,
    String? linkedOrderId,
    required String actorId,
    DateTime? at,
  }) => into(creditEntries).insert(
    CreditEntriesCompanion.insert(
      id: id,
      party: party,
      amountPaise: amountPaise,
      kind: 'due',
      phone: Value(phone),
      note: Value(note),
      linkedOrderId: Value(linkedOrderId),
      createdBy: actorId,
      at: at ?? DateTime.now(),
    ),
  );

  Future<void> insertSettlement({
    required String id,
    required String party,
    required int amountPaise,
    required String settlesEntryId,
    String? note,
    required String actorId,
    DateTime? at,
  }) async {
    final now = at ?? DateTime.now();
    await into(creditEntries).insert(
      CreditEntriesCompanion.insert(
        id: id,
        party: party,
        amountPaise: amountPaise,
        kind: 'settled',
        settlesEntryId: Value(settlesEntryId),
        note: Value(note),
        createdBy: actorId,
        at: now,
        settledAt: Value(at),
      ),
    );
    // Mirror onto the due row so the due list needs no self-join (see the
    // comment on `credit_entries.settled_at`).
    await (update(creditEntries)..where((c) => c.id.equalsValue(settlesEntryId))).write(
      CreditEntriesCompanion(settledAt: Value(at)),
    );
  }

  Stream<List<CreditEntryRow>> watchAll() =>
      (select(creditEntries)..orderBy([(c) => OrderingTerm.desc(c.at)])).watch();

  Future<List<CreditEntryRow>> openDueRows() async {
    final rows = await (select(creditEntries)..where((c) => c.kind.equals('due'))).get();
    return [for (final r in rows) if (r.settledAt == null) r];
  }
}

/// Stock read/write (Task I1-I3). The DAO holds *no* business rule: "may this be
/// deducted twice" is answered here only as data (`alreadyDeducted`), and whether
/// that should stop the sale is the inventory repository's decision.
class StockDao extends KazamaDao {
  Future<void> upsertStockItem(StockItem s, {required DateTime at}) =>
      into(stockItems).insertOnConflictUpdate(
        StockItemsCompanion.insert(
          id: s.id,
          name: s.name,
          unit: Value(s.unit),
          onHandMilli: Value(s.onHandMilli),
          reorderMilli: Value(s.reorderMilli),
          isActive: Value(s.active),
          updatedAt: at,
        ),
      );

  /// The stock item's name is deliberately NOT stored on the recipe row: a
  /// rename must not fork into two different labels. `stockName` on the model is
  /// filled from the join below, purely for display.
  Future<void> upsertRecipe(RecipeLine r, {required DateTime at}) =>
      into(itemRecipes).insertOnConflictUpdate(
        ItemRecipesCompanion.insert(
          id: r.id,
          itemId: r.itemId,
          stockItemId: r.stockItemId,
          perUnitMilli: r.perUnitMilli,
          unit: Value(r.unit),
        ),
      );

  Future<List<StockItem>> stockItems({bool includeInactive = false}) async {
    final q = select(stockItems);
    if (!includeInactive) q.where((t) => t.isActive.equals(true));
    return [for (final r in await q.get()) _stock(r)];
  }

  Stream<List<StockItem>> watchStockItems() => select(stockItems).watch().map(
    (rows) => [for (final r in rows) _stock(r)],
  );

  Stream<StockItem?> watchStockItem(String id) =>
      (select(stockItems)..where((t) => t.id.equalsValue(id))).watch().map(
        (rows) => rows.isEmpty ? null : _stock(rows.first),
      );

  Future<StockItem?> stockItem(String id) async {
    final row = await (select(stockItems)..where((t) => t.id.equalsValue(id))).getSingleOrNull();
    return row == null ? null : _stock(row);
  }

  Future<void> setOnHand(String id, {required int milli, required DateTime at}) =>
      (update(stockItems)..where((t) => t.id.equalsValue(id))).write(
        StockItemsCompanion(onHandMilli: Value(milli), updatedAt: Value(at)),
      );

  /// All recipes keyed by menu item — one query for the fire path, so deducting
  /// a 12-line ticket is 2 selects rather than 12 (KDS latency is a UI issue the
  /// moment it becomes a per-line round trip).
  Future<Map<String, List<RecipeLine>>> recipesByItem() async {
    final rows = await select(itemRecipes).get();
    if (rows.isEmpty) return const {};
    final names = {for (final s in await stockItems(includeInactive: true)) s.id: s.name};
    final out = <String, List<RecipeLine>>{};
    for (final r in rows) {
      out.putIfAbsent(r.itemId, () => []).add(
        RecipeLine(
          id: r.id,
          itemId: r.itemId,
          stockItemId: r.stockItemId,
          stockName: names[r.stockItemId] ?? '',
          perUnitMilli: r.perUnitMilli,
          unit: r.unit,
        ),
      );
    }
    return out;
  }

  Future<void> deleteRecipeLine(String id) => (delete(itemRecipes)..where((r) => r.id.equalsValue(id))).go();

  /// Has a `sale` movement already been booked for this ticket+stock pair?
  /// This is the dedup half of I2; the caller decides whether a duplicate is an
  /// error or a no-op (it must be a no-op: a reprint is not a new sale).
  Future<bool> alreadyDeducted({required String ticketId, required String stockItemId}) async {
    final row = await (select(stockMovements)
          ..where((m) => m.ticketId.equalsValue(ticketId))
          ..where((m) => m.stockItemId.equalsValue(stockItemId))
          ..where((m) => m.kind.equals('sale'))
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  Future<void> insertMovement(StockMovementRowData m) => into(stockMovements).insert(
    StockMovementsCompanion.insert(
      id: m.id,
      stockItemId: m.stockItemId,
      kind: m.kind.name,
      deltaMilli: m.deltaMilli,
      resultingMilli: m.resultingMilli,
      ticketId: Value(m.ticketId),
      actorId: m.actorId ?? 'system',
      at: m.at,
      note: Value(m.note),
    ),
  );

  /// History newest-first. `since` exists so the low-stock screen can say
  /// "nothing moved in 14 days" without pulling the whole ledger.
  Future<List<StockMovementRowData>> movementsFor(String stockItemId, {int limit = 50, DateTime? since}) async {
    final q = select(stockMovements)
      ..where((m) => m.stockItemId.equalsValue(stockItemId))
      ..orderBy([(m) => OrderingTerm.desc(m.at)])
      ..limit(limit);
    if (since != null) q.where((m) => m.at.isBiggerOrEqualValue(since));
    return [for (final r in await q.get()) _movement(r)];
  }

  /// Most recent movement per stock item, for the "last touched" column (I3).
  Future<Map<String, DateTime>> lastMovementAt() async {
    final rows = await (select(stockMovements)..orderBy([(m) => OrderingTerm.desc(m.at)])).get();
    final out = <String, DateTime>{};
    for (final r in rows) {
      out.putIfAbsent(r.stockItemId, () => r.at);
    }
    return out;
  }

  static StockItem _stock(StockItemRow r) => StockItem(
    id: r.id,
    name: r.name,
    unit: r.unit,
    onHandMilli: r.onHandMilli,
    reorderMilli: r.reorderMilli,
    active: r.isActive,
  );

  static StockMovementRowData _movement(StockMovementRow r) => StockMovementRowData(
    id: r.id,
    stockItemId: r.stockItemId,
    kind: StockMoveKind.fromName(r.kind),
    deltaMilli: r.deltaMilli,
    resultingMilli: r.resultingMilli,
    at: r.at,
    ticketId: r.ticketId,
    note: r.note,
    actorId: r.actorId,
  );
}

/// Staff, sessions and shifts (Task S1-S4). The PIN hash is computed by the
/// *caller* (`PinHasher` in features/staff_auth) — a DAO that hashed a PIN would
/// put a security rule in the layer that also has to work during a restore.
class StaffDao extends KazamaDao {
  Future<void> upsertUser(StaffUser u, {required DateTime at}) =>
      into(users).insertOnConflictUpdate(
        UsersCompanion.insert(
          id: u.id,
          name: u.name,
          role: u.role.name,
          pinHash: u.pinHash,
          pinSalt: u.pinSalt,
          isActive: Value(u.active),
          failedAttempts: Value(u.failedAttempts),
          lockedUntil: Value(u.lockedUntil),
          createdAt: u.createdAt,
          updatedAt: at,
        ),
      );

  Future<List<StaffUser>> allUsers({bool includeInactive = false}) async {
    final q = select(users)..orderBy([(u) => OrderingTerm.asc(u.createdAt)]);
    if (!includeInactive) q.where((u) => u.isActive.equals(true));
    return [for (final r in await q.get()) _user(r)];
  }

  Stream<List<StaffUser>> watchUsers() => (select(users)
        ..orderBy([(u) => OrderingTerm.asc(u.createdAt)]))
      .watch()
      .map((rows) => [for (final r in rows) _user(r)]);

  Future<StaffUser?> userById(String id) async {
    final row = await (select(users)..where((u) => u.id.equalsValue(id))).getSingleOrNull();
    return row == null ? null : _user(row);
  }

  Future<StaffUser?> firstUser() async {
    final rows = await (select(users)
          ..orderBy([(u) => OrderingTerm.asc(u.createdAt)])
          ..limit(1))
        .get();
    return rows.isEmpty ? null : _user(rows.first);
  }

  Future<int> userCount() async => (await select(users).get()).length;

  /// Shifts are append-mostly: one open row per user, then a close that fills in
  /// the counted figures. `openShiftFor` is called inside a transaction with an
  /// explicit close of any dangling row (S3).
  Future<void> insertShift(Shift s) => into(shifts).insertOnConflictUpdate(
    ShiftsCompanion.insert(
      id: s.id,
      userId: s.userId,
      openingFloatPaise: s.openingFloat.paise,
      openedAt: s.openedAt,
      closedAt: Value(s.closedAt),
      countedCashPaise: Value(s.countedCash?.paise),
      note: Value(s.note),
    ),
  );

  Future<void> closeShift({
    required String shiftId,
    required Money countedCash,
    String? note,
    DateTime? at,
  }) => (update(shifts)..where((s) => s.id.equalsValue(shiftId))).write(
    ShiftsCompanion(
      closedAt: Value(at ?? DateTime.now()),
      countedCashPaise: Value(countedCash.paise),
      note: note == null ? const Value.absent() : Value(note),
    ),
  );

  Future<Shift?> openShiftFor(String userId) async {
    final rows = await (select(shifts)
          ..where((s) => s.userId.equalsValue(userId))
          ..where((s) => s.closedAt.isNull())
          ..orderBy([(s) => OrderingTerm.desc(s.openedAt)]))
        .get();
    return rows.isEmpty ? null : _shift(rows.first);
  }

  Future<List<Shift>> shiftsInRange({DateTime? from, DateTime? to}) async {
    final q = select(shifts)..orderBy([(s) => OrderingTerm.desc(s.openedAt)]);
    if (from != null) q.where((s) => s.openedAt.isBiggerOrEqualValue(from));
    if (to != null) q.where((s) => s.openedAt.isSmallerOrEqualValue(to));
    return [for (final r in await q.get()) _shift(r)];
  }

  static StaffUser _user(UserRow r) => StaffUser(
    id: r.id,
    name: r.name,
    role: UserRole.fromName(r.role),
    pinHash: r.pinHash,
    pinSalt: r.pinSalt,
    active: r.isActive,
    failedAttempts: r.failedAttempts,
    lockedUntil: r.lockedUntil,
    createdAt: r.createdAt,
  );

  static Shift _shift(ShiftRow r) => Shift(
    id: r.id,
    userId: r.userId,
    openingFloat: Money(r.openingFloatPaise),
    openedAt: r.openedAt,
    closedAt: r.closedAt,
    countedCash: r.countedCashPaise == null ? null : Money(r.countedCashPaise!),
    note: r.note,
  );
}

/// Credit ledger + receipt log + the raw row reads the reports screen aggregates
/// (R1-R4). Report aggregation deliberately lives in Dart over these reads:
/// hand-written drift `CustomSelect`s are unverifiable here, and a 60-cover day is
/// a few hundred rows — correctness beats a micro-optimisation.
class PaymentDao extends KazamaDao {
  Stream<List<CreditEntry>> watchCredit() =>
      (select(creditEntries)..orderBy([(c) => OrderingTerm.desc(c.at)]))
          .watch()
          .map((rows) => [for (final r in rows) _credit(r)]);

  Future<CreditEntry?> creditById(String id) async {
    final row = await (select(creditEntries)..where((c) => c.id.equalsValue(id))).getSingleOrNull();
    return row == null ? null : _credit(row);
  }

  /// Tickets whose money moved in `[from, to)`, as full aggregates.
  ///
  /// Reports read the HYDRATED ticket rather than raw columns because the
  /// discount cache stores `subtotal = base - discount` and `discount_value` is
  /// a *percent* for percentage bills. Re-deriving `lineBase` in a report would
  /// mean a second implementation of discount maths — and the day those two
  /// disagree is the day a report is wrong while every receipt is right.
  Future<List<OrderTicket>> ticketsBetween(DateTime from, DateTime to) =>
      (select(orders)
            ..where((o) => o.updatedAt.isBiggerOrEqualValue(from))
            ..where((o) => o.updatedAt.isSmallerThanValue(to))
            ..orderBy([(o) => OrderingTerm.asc(o.openedAt)]))
          .get()
          .then(_hydrateAll);

  /// Paise the drawer should have gained from every cash row in a window.
  /// ONE implementation, because a shift close (S4) and a cash-up report (R2)
  /// disagreeing about change is the single most confusing till bug there is.
  Future<Money> drawerFromCash({required DateTime from, DateTime? to}) async {
    final rows = await (select(payments)
          ..where((p) => p.at.isBiggerOrEqualValue(from))
          ..where((p) => p.mode.equals('cash')))
        .get();
    final end = to;
    var total = 0;
    for (final r in rows) {
      if (end != null && !r.at.isBefore(end)) continue;
      total += PaymentRowData.drawerPaise(
        amountPaise: r.amountPaise,
        tenderedPaise: r.tenderedPaise,
        changePaise: r.changePaise,
      );
    }
    return Money(total);
  }

  Future<Shift?> shiftById(String id) async {
    final row = await (select(shifts)..where((s) => s.id.equalsValue(id))).getSingleOrNull();
    return row == null ? null : _shift(row);
  }

  Future<List<OrderRow>> ordersBetween(DateTime from, DateTime to) => (select(orders)
        ..where((o) => o.updatedAt.isBiggerOrEqualValue(from))
        ..where((o) => o.updatedAt.isSmallerThanValue(to))
        ..orderBy([(o) => OrderingTerm.asc(o.openedAt)]))
      .get();

  Future<List<PaymentRow>> paymentsBetween(DateTime from, DateTime to) => (select(payments)
        ..where((p) => p.at.isBiggerOrEqualValue(from))
        ..where((p) => p.at.isSmallerThanValue(to)))
      .get();

  Future<List<OrderLineRow>> linesForOrders(List<String> orderIds) {
    if (orderIds.isEmpty) return Future.value(const []);
    return (select(orderLines)..where((l) => l.orderId.isIn(orderIds))).get();
  }

  Future<void> insertReceipt(ReceiptRecord r) => into(receipts).insertOnConflictUpdate(
    ReceiptsCompanion.insert(
      id: r.id,
      orderId: r.orderId,
      kind: r.kind.name,
      transport: r.transport,
      delivered: r.delivered,
      printerName: Value(r.printerName),
      paperWidthColumns: Value(r.paperWidthColumns),
      bytesPath: Value(r.bytesPath),
      error: Value(r.error),
      at: r.at,
    ),
  );

  Future<int> receiptCount(String orderId) async =>
      (await (select(receipts)..where((r) => r.orderId.equalsValue(orderId))).get()).length;

  static CreditEntry _credit(CreditEntryRow r) => CreditEntry(
    id: r.id,
    party: r.party,
    amount: Money(r.amountPaise),
    kind: CreditKind.fromName(r.kind),
    phone: r.phone,
    note: r.note,
    linkedOrderId: r.linkedOrderId,
    at: r.at,
    settledAt: r.settledAt,
  );
}
