/// Shared mutation plumbing for the ticket repositories (Task O2/Y1).
///
/// Every counter edit follows the same three steps — read the current ticket from
/// the DB, apply a model transition, write the whole aggregate back — and the
/// order matters: reading first is what makes two devices (or two taps) converge on
/// the model's own guards instead of clobbering each other with a stale in-memory
/// copy. Keeping it in one place means the "read-modify-write" rule is stated once.
///
/// Note what is NOT here: any rule about what a transition means. `withLine`,
/// `fired`, `withPaymentApplied` etc. live on `OrderTicket` (T2), so a repository
/// cannot invent a transition the domain forgot to allow.
library;

import '../../../core/db/app_database.dart';
import '../../../core/utils/id.dart';
import '../../models/mutation.dart';
import '../../models/order.dart';

mixin TicketMutator {
  AppDatabase get db;

  IdFactory get ids;

  /// Journal one mutation for the sync engine (T5), inside the caller's active
  /// transaction. Only the *money* rows are journalled in v1 — an order and its
  /// payments are what a server would need to reconstruct a day, and menu/stock
  /// edits travel through the snapshot (T4) instead, which keeps the outbox small
  /// enough that `pending()` stays a single indexed read.
  Future<void> journal({
    required String entity,
    required String entityId,
    required MutationOp op,
    required Map<String, Object?> payload,
    DateTime? at,
  }) {
    final when = at ?? DateTime.now();
    final key = '$entity:$entityId:${op.name}:${when.microsecondsSinceEpoch}';
    return db.enqueueMutation(Mutation(
      id: ids.newId(),
      entity: entity,
      entityId: entityId,
      op: op,
      payload: payload,
      idempotencyKey: key,
      queuedAt: when,
    ));
  }

  /// Throws rather than returning null: every call site is an explicit user
  /// action on a ticket the UI was displaying, so a missing ticket means the row
  /// was settled/voided by another tap and the action must be refused, not
  /// silently dropped.
  Future<OrderTicket> load(String ticketId) async {
    final t = await db.ticketById(ticketId);
    if (t == null) {
      throw StateError('ticket $ticketId no longer exists (settled or deleted elsewhere)');
    }
    return t;
  }

  /// [eventType] appends an audit row in the same transaction (SKILLS.md §C5);
  /// pass null for read-only style writes where an event would be noise (e.g. a
  /// kitchen line tick, which is already recorded by the ticket state).
  Future<OrderTicket> mutate(
    String ticketId,
    OrderTicket Function(OrderTicket) transform, {
    String? eventType,
    Map<String, Object?> eventPayload = const <String, Object?>{},
    String? actorId,
    bool journalTicket = true,
  }) async {
    final current = await load(ticketId);
    final next = transform(current);
    final now = DateTime.now();
    await db.transaction(() async {
      await db.replaceTicket(next, at: now);
      if (journalTicket) {
        await journal(
          entity: 'order',
          entityId: ticketId,
          op: MutationOp.update,
          payload: ticketPayload(next),
          at: now,
        );
      }
      if (eventType != null) {
        await db.appendEvent(
          orderId: ticketId,
          eventType: eventType,
          actorId: actorId ?? 'system',
          payload: eventPayload,
          at: now,
        );
      }
    });
    return next;
  }

  /// The wire shape of a ticket. Deliberately a hand-rolled map rather than
  /// `OrderTicket.toJson` (which does not exist): the payload must be the
  /// *minimal* thing a server needs, and every field added to a POS model would
  /// otherwise silently enlarge every outbox row and every backup.
  Map<String, Object?> ticketPayload(OrderTicket t) => {
        'id': t.id,
        'status': t.status.name,
        'billNumber': t.billNumber,
        'openedAt': t.openedAt.toIso8601String(),
        'updatedAt': t.updatedAt?.toIso8601String(),
        'firedAt': t.firedAt?.toIso8601String(),
        'type': t.type.name,
        'tableOrName': t.tableOrName,
        'discount': {'kind': t.discount.kind.name, 'value': t.discount.value},
        'paidPaise': t.paid.paise,
        'duePaise': t.due.paise,
        'note': t.note,
        'lines': [
          for (final l in t.lines)
            {
              'id': l.id,
              'itemId': l.itemId,
              'name': l.nameSnapshot,
              'kitchenLabel': l.kitchenLabel,
              'quantity': l.quantity,
              'cancelledQuantity': l.cancelledQuantity,
              'unitPricePaise': l.unitPrice.paise,
              'taxPercent': l.taxPercent,
              'modifiers': [for (final m in l.modifiers) m.label],
              'note': l.note,
              'status': l.status.name,
            }
        ],
      };
}
