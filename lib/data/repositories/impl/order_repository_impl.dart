/// drift-backed ticket repository (Task O2-O6 + K1-K4 wiring).
///
/// Every write is read-modify-write on the aggregate (see `TicketMutator`), so the
/// model's own guards decide what is legal — this class never re-implements a
/// transition, which would be a second source of truth the moment a transition is
/// added to one and not the other.
library;

import '../../../core/db/app_database.dart';
import '../../../core/money/money.dart';
import '../../../core/utils/id.dart';
import '../../models/enums.dart';
import '../../models/menu.dart';
import '../../models/mutation.dart';
import '../../models/order.dart';
import '../../models/order_line.dart';
import '../../models/payment.dart';
import '../contract/order_repository.dart';
import '../contract/stock_repository.dart';
import 'ticket_mutator.dart';

/// Stock hook, injected rather than imported-from so the order module does not
/// depend on the inventory module (R1). The composition root wires
/// `stockRepo.deductForTicket` in here; with no stock module compiled (unit
/// tests) the order flow still works, which is the point of a typedef seam.
typedef TicketFiredHook = Future<void> Function(
  String ticketId,
  List<StockDeduction> deductions,
  String actorId,
);

class OrderRepositoryImpl with TicketMutator implements OrderRepository {
  OrderRepositoryImpl(this.db, {IdFactory? idFactory, this.onTicketFired}) : ids = idFactory ?? IdFactory();

  @override
  final AppDatabase db;

  @override
  final IdFactory ids;

  final TicketFiredHook? onTicketFired;

  // ----------------------------------------------------------------- reads --

  @override
  Stream<List<OrderTicket>> watchOpenTickets() => db.watchOpenTickets();

  @override
  Stream<List<OrderTicket>> watchKitchenTickets() => db.watchKitchenTickets();

  @override
  Stream<List<OrderTicket>> watchTickets({String? search}) => db.watchTicketsFor(search);

  @override
  Future<OrderTicket?> byId(String ticketId) => db.ticketById(ticketId);

  @override
  Future<OrderTicket?> loadForReceipt(String ticketId) => db.ticketById(ticketId);

  // ------------------------------------------------------------------ open --

  @override
  Future<OrderTicket> startTicket({
    required OrderType type,
    required String openedBy,
    String? tableOrName,
    String? note,
  }) async {
    final now = DateTime.now();
    final ticket = OrderTicket(
      id: ids.newId(),
      type: type,
      // A takeaway that will be paid at once still starts OPEN, not DRAFT:
      // DRAFT exists for "hold an unnumbered ticket", and defaulting to it would
      // leave most of the counter's tickets invisible to the due list (O4).
      status: OrderStatus.open,
      tableOrName: _clean(tableOrName),
      note: _clean(note),
      openedBy: openedBy,
      openedAt: now,
      updatedAt: now,
    );
    await db.replaceTicket(ticket, at: now, event: 'opened', actorId: openedBy);
    return ticket;
  }

  // ----------------------------------------------------------------- lines --

  @override
  Future<void> addMenuItem({
    required String ticketId,
    required MenuItemLike item,
    required int quantity,
    List<ModifierOptionLike> modifiers = const <ModifierOptionLike>[],
    String? note,
  }) {
    if (quantity < 1) throw ArgumentError('quantity must be >= 1');
    // The snapshot is a real `ModifierOption` list because the LINE stores it:
    // a receipt printed next month must show the price that was charged, not
    // what the modifier costs after a price change (O2).
    final snapshot = [
      for (final m in modifiers)
        ModifierOption(id: m.id, groupId: m.groupId, name: m.name, priceDelta: m.priceDelta),
    ];
    final unitPrice = item.price + Money.sum(snapshot.map((m) => m.priceDelta));
    return mutate(
      ticketId,
      (t) => t.withLine(
        TicketLine(
          id: ids.newId(),
          itemId: item.id,
          nameSnapshot: item.name,
          kitchenLabel: item.kitchenLabel,
          unitPrice: unitPrice,
          taxPercent: item.taxPercent,
          quantity: quantity,
          modifiers: snapshot,
          note: _clean(note),
        ),
      ),
      eventType: 'line_added',
      eventPayload: {'item': item.name, 'qty': quantity},
    );
  }

  @override
  Future<void> setQuantity({required String ticketId, required String lineId, required int quantity}) => mutate(
    ticketId,
    (t) => t.withQuantity(lineId, quantity),
    eventType: 'qty_changed',
    eventPayload: {'line': lineId, 'qty': quantity},
  );

  @override
  Future<void> setLineNote({required String ticketId, required String lineId, String? note}) =>
      mutate(ticketId, (t) => t.setLineNote(lineId, note));

  @override
  Future<void> cancelLine({
    required String ticketId,
    required String lineId,
    int? quantity,
    required String actorId,
  }) => mutate(
    ticketId,
    (t) => t.cancelledLine(lineId, quantity: quantity),
    eventType: 'line_cancelled',
    eventPayload: {'line': lineId, if (quantity != null) 'qty': quantity},
    actorId: actorId,
  );

  @override
  Future<void> uncancelLine({required String ticketId, required String lineId, required String actorId}) => mutate(
    ticketId,
    (t) => t.uncancelledLine(lineId),
    eventType: 'line_restored',
    eventPayload: {'line': lineId},
    actorId: actorId,
  );

  @override
  Future<void> setDiscount({
    required String ticketId,
    required DiscountKind kind,
    required int value,
    required String actorId,
  }) => mutate(
    ticketId,
    (t) => t.withDiscount(OrderDiscount(kind, kind == DiscountKind.none ? 0 : value)),
    eventType: 'discount',
    eventPayload: {'kind': kind.name, 'value': value},
    actorId: actorId,
  );

  // ---------------------------------------------------------------- kitchen --

  @override
  Future<void> fire({required String ticketId, required String actorId}) async {
    final before = await load(ticketId);
    // What THIS fire sends, captured before the state moves: stock is deducted
    // for exactly the lines that reach the kitchen, not for course 1 again when
    // the cashier fires course 2 (I2).
    final moving = [
      for (final l in before.lines)
        if (l.status.isFireable && !l.isFullyCancelled) StockDeduction(itemId: l.itemId, quantity: l.liveQuantity),
    ];
    await mutate(
      ticketId,
      (t) => t.fired(at: DateTime.now()),
      eventType: 'fired',
      eventPayload: {'lines': moving.length},
      actorId: actorId,
    );
    if (onTicketFired != null && moving.isNotEmpty) {
      await onTicketFired!(ticketId, moving, actorId);
    }
  }

  @override
  Future<void> markLineReady({required String ticketId, required String lineId}) async {
    final now = DateTime.now();
    final current = await load(ticketId);
    await db.replaceTicket(current.lineReady(lineId).maybeReady(at: now), at: now);
  }

  @override
  Future<void> markTicketReady({required String ticketId}) async {
    final now = DateTime.now();
    final current = await load(ticketId);
    await db.replaceTicket(current.readyAll(at: now), at: now);
  }

  @override
  Future<void> serve({required String ticketId, required String actorId}) => mutate(
    ticketId,
    (t) => t.served(at: DateTime.now()),
    eventType: 'served',
    actorId: actorId,
  );

  // ------------------------------------------------------------------ money --

  @override
  Future<OrderTicket> recordPayment({
    required String ticketId,
    required PaymentMode mode,
    required Money amount,
    Money? tendered,
    String? reference,
    required String actorId,
    String? creditParty,
    String? creditPhone,
  }) async {
    if (mode == PaymentMode.credit && (creditParty == null || creditParty.trim().isEmpty)) {
      throw ArgumentError('a pay-later row needs a party name to be collectable');
    }
    final current = await load(ticketId);
    final applied = current.withPaymentApplied(amount, at: DateTime.now());
    final now = DateTime.now();

    // Tender/change are a cash concept; `Payment.validateShape` enforces the
    // shape, and here we only decide the numbers (Y1).
    final isCash = mode == PaymentMode.cash;
    final given = isCash ? (tendered ?? amount) : null;
    if (isCash && given! < amount) {
      throw ArgumentError('tendered ${given.paise}p is less than the amount applied ${amount.paise}p');
    }
    final payment = Payment(
      id: ids.newId(),
      orderId: ticketId,
      mode: mode,
      amount: amount,
      tendered: given,
      change: isCash ? given! - amount : null,
      reference: _clean(reference),
      recordedBy: actorId,
      at: now,
    );

    await db.transaction(() async {
      // Bill number is allocated INSIDE the write: SKILLS.md §C2's "no two bills
      // share a number" only holds if an app kill cannot land between
      // allocating and persisting it.
      final bill = applied.billNumber == null ? await db.nextBillNumber() : null;
      // The row as it will exist after this transaction: `replaceTicket` writes
      // `billNumber ?? t.billNumber`, and the journalled payload must be that row,
      // not the in-memory one. A server that applied `applied` would store a bill
      // with no number forever — the number is only ever allocated here.
      await db.replaceTicket(
        applied,
        // The order row's mutation carries the paid/due figures too, so it must go
        // through the DAO even here — hence `journalPayload` and no `mutate()` call.
        journalPayload: ticketOutboxPayload(applied.copyWith(billNumber: applied.billNumber ?? bill)),
        at: now,
        billNumber: bill,
        event: 'payment',
        eventPayload: {
          'mode': mode.name,
          'amount': amount.paise,
          if (bill != null) 'bill': bill,
          if (isCash && given! > amount) 'change': (given - amount).paise,
        },
        actorId: actorId,
      );
      await db.insertPayment(payment);
      await journal(
        entity: 'payment',
        entityId: payment.id,
        op: MutationOp.insert,
        payload: {
          'id': payment.id,
          'orderId': payment.orderId,
          'mode': payment.mode.name,
          'amountPaise': payment.amount.paise,
          'tenderedPaise': payment.tendered?.paise,
          'changePaise': payment.change?.paise,
          'reference': payment.reference,
          'recordedBy': payment.recordedBy,
          'at': payment.at.toIso8601String(),
        },
        at: now,
      );
      if (mode == PaymentMode.credit) {
        await db.insertDue(
          id: ids.newId(),
          party: creditParty!.trim(),
          amountPaise: amount.paise,
          phone: _clean(creditPhone),
          linkedOrderId: ticketId,
          actorId: actorId,
          at: now,
        );
      }
    });
    // The caller (billing screen) re-reads via its own watch stream; returning
    // the in-memory object is only for tests and for the receipt's numbers.
    return bill == null ? applied : applied.copyWith(billNumber: bill);
  }

  @override
  Future<OrderTicket> voidTicket({
    required String ticketId,
    required String reason,
    required String actorId,
  }) => mutate(
    ticketId,
    (t) => t.voided(reason: reason, at: DateTime.now()),
    eventType: 'voided',
    eventPayload: {'reason': reason},
    actorId: actorId,
  );

  static String? _clean(String? v) {
    final t = v?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }
}
