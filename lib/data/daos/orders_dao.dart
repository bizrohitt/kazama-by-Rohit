/// Order/ticket DAO — the persistence half of the counter flow (Task T3).
///
/// Two invariants that must not be split across transactions:
///  * a ticket and its lines commit together (`replaceTicket`), so a crash can
///    never leave an order row whose lines were half-written;
///  * the payment insert recomputes `orders.paid_paise` in the same transaction,
///    which is what keeps the derived cache honest (SKILLS.md §B3).
/// The outbox row is *not* written here — that's the repository's job (T5), so a
/// raw DAO call can be used by the seed/restore paths without journalling noise.
part of '../../core/db/app_database.dart';

class OrdersDao extends KazamaDao {
  /// Derived, not typed out, so adding a status to the enum cannot leave it
  /// invisible on the held-tickets screen (O4) — the list and the rule live in
  /// one place (`OrderStatus.appearsInHeldList`).
  static final List<String> _openStatuses = [
    for (final s in OrderStatus.values)
      if (s.appearsInHeldList) s.name,
  ];

  /// Same trick for the KDS feed (K1); a status that is not "in the kitchen"
  /// can never accidentally be shown to the cooks as their job.
  static final List<String> _kitchenStatuses = [
    for (final s in OrderStatus.values)
      if (s.appearsOnKds) s.name,
  ];

  /// Whole-aggregate write used by the seed, the restore (T4) and every order-taking
  /// edit (O2-O6). Ids are supplied by the caller, so a restore is idempotent.
  /// [billNumber] is the one field a caller may override at write time: numbers
  /// must be allocated inside this transaction (see `nextBillNumber`), and
  /// passing it here keeps "allocate" and "persist" atomic instead of two await
  /// points an app kill can land between.
  /// [event] writes the audit row in the *same* transaction, which is the only
  /// way "every mutation is recorded" (SKILLS.md §C5) can hold: an event
  /// appended after the write is a gap on every crash between them.
  /// [journalPayload] is the *post-write* order row for the sync outbox (T5).
  /// It is a parameter and not a flag because the payload's shape is the
  /// repository's business (what a server needs) while the ATOMICITY is the DAO's:
  /// the outbox row must be inserted in this same transaction, or a crash between
  /// the two writes is a sale the server never hears about and no log can find.
  /// Seed and restore pass null, which is why the DAO's own header still says the
  /// outbox "is not written here" — it is not written *for them*.
  Future<void> replaceTicket(
    OrderTicket t, {
    DateTime? at,
    int? billNumber,
    String? event,
    Map<String, Object?> eventPayload = const <String, Object?>{},
    String actorId = 'system',
    Map<String, Object?>? journalPayload,
  }) async {
    final now = at ?? DateTime.now();
    await db.transaction(() async {
      if (event != null) {
        await appendEvent(
          orderId: t.id,
          eventType: event,
          actorId: actorId,
          payload: eventPayload,
          at: now,
        );
      }
      await into(orders).insert(
        OrdersCompanion.insert(
          id: t.id,
          billNumber: Value(billNumber ?? t.billNumber),
          type: t.type.name,
          status: t.status.name,
          tableOrName: Value(t.tableOrName),
          note: Value(t.note),
          discountKind: Value(t.discount.kind.index),
          discountValue: Value(t.discount.value),
          subtotalPaise: Value(t.totals.lineBase.paise - t.totals.discount.paise),
          taxPaise: Value(t.totals.tax.paise),
          totalPaise: Value(t.totals.total.paise),
          paidPaise: Value(t.paid.paise),
          duePaise: Value(t.due.paise),
          roundingPaise: Value(t.totals.rounding.paise),
          voidReason: Value(t.voidReason),
          openedBy: t.openedBy,
          openedAt: t.openedAt,
          firedAt: Value(t.firedAt),
          readyAt: Value(t.readyAt),
          servedAt: Value(t.servedAt),
          closedAt: Value(t.closedAt),
          updatedAt: Value(now),
        ),
      );

      // Lines are replaced rather than diffed: the aggregate always knows the
      // full truth, and a diff would need a second source of ordering (O2).
      if (journalPayload != null) {
        await enqueueMutation(Mutation(
          id: 'outbox-${t.id}-${now.microsecondsSinceEpoch}',
          entity: 'order',
          entityId: t.id,
          op: MutationOp.update,
          payload: journalPayload,
          // One key per (ticket, write instant): a re-run of the same write (the
          // seed, or a retried repository call) is then a no-op by constraint.
          idempotencyKey: 'order:${t.id}:${now.microsecondsSinceEpoch}',
          queuedAt: now,
        ));
      }

      // Lines are replaced rather than diffed: the aggregate always knows the
      // full truth, and a diff would need a second source of ordering (O2).
      await (delete(orderLines)..where((l) => l.orderId.equalsValue(t.id))).go();
      var index = 0;
      for (final l in t.lines) {
        await into(orderLines).insert(
          OrderLinesCompanion.insert(
            id: l.id,
            orderId: t.id,
            itemId: Value(l.itemId),
            nameSnapshot: l.nameSnapshot,
            kitchenLabelSnapshot: Value(l.kitchenLabel),
            unitPricePaise: l.unitPrice.paise,
            taxPercent: Value(l.taxPercent),
            modifiersJson: Value(jsonEncode([for (final m in l.modifiers) m.toJson()])),
            quantity: Value(l.quantity),
            cancelledQuantity: Value(l.cancelledQuantity),
            lineStatus: Value(l.status.name),
            note: Value(l.note),
            sortIndex: Value(index),
            updatedAt: Value(now),
          ),
        );
        index++;
      }
    });
  }

  /// Insert-only audit row (SKILLS.md §C5). There is deliberately no update or
  /// delete on this table anywhere in the app.
  Future<void> appendEvent({
    required String orderId,
    required String eventType,
    required String actorId,
    Map<String, Object?> payload = const <String, Object?>{},
    DateTime? at,
  }) {
    return into(orderEvents).insert(
      OrderEventsCompanion.insert(
        orderId: orderId,
        eventType: eventType,
        actorId: actorId,
        payloadJson: Value(jsonEncode(payload)),
        at: at ?? DateTime.now(),
      ),
    );
  }

  Future<void> insertPayment(Payment p) async {
    p.validateShape(); // refuse a malformed row before it can poison the cache
    await db.transaction(() async {
      await into(payments).insert(
        PaymentsCompanion.insert(
          id: p.id,
          orderId: p.orderId,
          mode: p.mode.name,
          amountPaise: p.amount.paise,
          tenderedPaise: Value(p.tendered?.paise),
          changePaise: Value(p.change?.paise),
          reference: Value(p.reference),
          recordedBy: p.recordedBy,
          at: p.at,
        ),
      );
      // Derived cache refresh — the ledger stays the truth, but every report and
      // the due list read these columns, so they must never lag a payment.
      final paid = await _sumPaid(p.orderId);
      await (update(orders)..where((o) => o.id.equalsValue(p.orderId))).write(
        OrdersCompanion(paidPaise: Value(paid.paise)),
      );
    });
  }

  Future<Money> _sumPaid(String orderId) async {
    final rows = await (select(payments)..where((p) => p.orderId.equalsValue(orderId))).get();
    return Money.sum([for (final r in rows) Money(r.amountPaise)]);
  }

  /// Bill-number allocation, monotonic and gap-tolerant (SKILLS.md §C2). Must be
  /// called inside the same transaction that writes the closing order row — that
  /// is what makes "no two bills share a number" true even if the app is killed
  /// mid-close, and why the number is never re-derived from `COUNT(*)`.
  Future<int> nextBillNumber() async {
    // Seed first, then read: `insertOnConflictUpdate` is an upsert of a *known*
    // row, and on a fresh install there is no `bill.seq` row to update.
    await _putMeta(MetaKeys.billSeq, '0');
    final current = int.tryParse(await _readMeta(MetaKeys.billSeq) ?? '') ?? 0;
    final next = current + 1;
    await _putMeta(MetaKeys.billSeq, '$next');
    return next;
  }

  /// Public read for settings the UI displays (paper width, tax mode, shop
  /// profile). Kept next to the private meta helpers so there is exactly one
  /// place that knows `app_meta` stores strings.
  Future<String?> metaValue(String key) => _readMeta(key);

  Future<void> setMetaValue(String key, String value) => _putMeta(key, value);

  /// Deleting is how a setting falls back to its default (e.g. "clear the shop
  /// address so the receipt prints without one").
  Future<void> clearMetaValue(String key) =>
      (delete(appMeta)..where((m) => m.metaKey.equalsValue(key))).go();

  Future<String?> _readMeta(String key) async {
    final row = await (select(appMeta)..where((m) => m.metaKey.equalsValue(key))).getSingleOrNull();
    return row?.metaValue;
  }

  Future<void> _putMeta(String key, String value) => into(appMeta).insertOnConflictUpdate(
    AppMetaCompanion.insert(metaKey: key, metaValue: value, updatedAt: DateTime.now()),
  );

  // ----------------------------------------------------------------- reads --

  /// The whole payment ledger for one ticket, oldest first — the receipt's
  /// payment section and the split-tender list read this (Y2), never the cached
  /// `paid` on the aggregate, because a receipt that disagrees with the ledger is
  /// the worst kind of bug in a till.
  Future<List<Payment>> paymentsFor(String ticketId) async {
    final rows = await (select(payments)
          ..where((p) => p.orderId.equalsValue(ticketId))
          ..orderBy([(p) => OrderingTerm.asc(p.at)]))
        .get();
    return [
      for (final r in rows)
        Payment(
          id: r.id,
          orderId: r.orderId,
          mode: PaymentMode.fromName(r.mode),
          amount: Money(r.amountPaise),
          tendered: r.tenderedPaise == null ? null : Money(r.tenderedPaise!),
          change: r.changePaise == null ? null : Money(r.changePaise!),
          reference: r.reference,
          recordedBy: r.recordedBy,
          at: r.at,
        ),
    ];
  }

  /// Receipts issued for a ticket, in order. Reprint count is a *receipt*
  /// property, so the billing screen can print "REPRINT n" without a counter
  /// column on the order that would have to be kept in sync by hand (P3).
  Future<List<ReceiptRow>> receiptsFor(String ticketId) =>
      (select(receipts)..where((r) => r.orderId.equalsValue(ticketId))).get();

  /// Held-tickets / due list (O4): everything not settled, newest touched first.
  Stream<List<OrderTicket>> watchOpenTickets() =>
      (select(orders)..where((o) => o.status.isIn(_openStatuses))
            ..orderBy([(o) => OrderingTerm.desc(o.updatedAt)]))
          .watch()
          .asyncMap(_hydrateAll);

  /// KDS feed (K1): what the kitchen owes the floor, oldest fired first.
  Stream<List<OrderTicket>> watchKitchenTickets() =>
      (select(orders)..where((o) => o.status.isIn(_kitchenStatuses))
            ..orderBy([(o) => OrderingTerm.asc(o.firedAt)]))
          .watch()
          .asyncMap(_hydrateAll);

  Future<OrderTicket?> ticketById(String id) async {
    final row = await (select(orders)..where((o) => o.id.equalsValue(id))).getSingleOrNull();
    return row == null ? null : _hydrate(row);
  }

  Stream<List<OrderTicket>> watchTicketsFor(String? tableOrName) {
    final q = select(orders)..where((o) => o.status.isIn(_openStatuses));
    if (tableOrName != null && tableOrName.isNotEmpty) {
      q.where((o) => o.tableOrName.like('%$tableOrName%'));
    }
    return q.watch().asyncMap(_hydrateAll);
  }

  Future<List<OrderTicket>> _hydrateAll(List<OrderRow> rows) =>
      Future.wait([for (final r in rows) _hydrate(r)]);

  Future<OrderTicket> _hydrate(OrderRow r) async {
    final lineRows = await (select(orderLines)
          ..where((l) => l.orderId.equalsValue(r.id))
          ..orderBy([
            (l) => OrderingTerm.asc(l.sortIndex),
            (l) => OrderingTerm.asc(l.id),
          ]))
        .get();
    return OrderTicket(
      id: r.id,
      billNumber: r.billNumber,
      type: OrderType.fromName(r.type),
      status: OrderStatus.fromName(r.status),
      tableOrName: r.tableOrName,
      note: r.note,
      openedBy: r.openedBy,
      openedAt: r.openedAt,
      firedAt: r.firedAt,
      readyAt: r.readyAt,
      servedAt: r.servedAt,
      closedAt: r.closedAt,
      updatedAt: r.updatedAt,
      paid: Money(r.paidPaise),
      due: Money(r.duePaise),
      voidReason: r.voidReason,
      discount: OrderDiscount(DiscountKind.values[r.discountKind], r.discountValue),
      lines: [for (final l in lineRows) _line(l)],
    );
  }

  static TicketLine _line(OrderLineRow l) => TicketLine(
    id: l.id,
    itemId: l.itemId ?? '',
    nameSnapshot: l.nameSnapshot,
    kitchenLabel: l.kitchenLabelSnapshot,
    unitPrice: Money(l.unitPricePaise),
    taxPercent: l.taxPercent,
    quantity: l.quantity,
    cancelledQuantity: l.cancelledQuantity,
    status: LineStatus.fromName(l.lineStatus),
    note: l.note,
    modifiers: [
      for (final raw in (jsonDecode(l.modifiersJson) as List<Object?>))
        ModifierOption.fromJson(raw! as Map<String, Object?>),
    ],
  );
}
