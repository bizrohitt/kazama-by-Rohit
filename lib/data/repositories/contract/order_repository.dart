/// Ticket repository contract (Task O2) — the shared spine of BOTH counter
/// sections. Order-taking uses the line methods; billing uses settle/void. No
/// method here mixes the two concerns, which is what keeps the Q4 split real.
library;

import '../../../core/money/money.dart';
import '../../models/enums.dart';
import '../../models/order.dart';
import '../../models/order_line.dart';

abstract interface class OrderRepository {
  /// Held tickets / everything not settled, newest touched first (O4).
  Stream<List<OrderTicket>> watchOpenTickets();

  /// What the kitchen owes the floor (K1).
  Stream<List<OrderTicket>> watchKitchenTickets();

  Stream<List<OrderTicket>> watchTickets({String? search});

  Future<OrderTicket?> byId(String ticketId);

  /// Opens a ticket. `tableOrName` is the search key for the due list; a
  /// takeaway with no name gets a draft label until it is numbered.
  Future<OrderTicket> startTicket({
    required OrderType type,
    required String openedBy,
    String? tableOrName,
    String? note,
  });

  /// Adds one line built from a menu item (price + tax + name snapshotted here,
  /// at order time, by the caller-supplied item).
  Future<void> addMenuItem({
    required String ticketId,
    required MenuItemLike item,
    required int quantity,
    List<ModifierOptionLike> modifiers,
    String? note,
  });

  Future<void> setQuantity({required String ticketId, required String lineId, required int quantity});

  Future<void> setLineNote({required String ticketId, required String lineId, String? note});

  Future<void> cancelLine({
    required String ticketId,
    required String lineId,
    int? quantity,
    required String actorId,
  });

  /// Undoes a line cancellation (O6). Kept separate from `cancelLine` with a
  /// negative quantity: a repo method that takes "how many to cancel" and also
  /// "or restore" ends up with callers passing -1 and the maths getting clever.
  Future<void> uncancelLine({required String ticketId, required String lineId, required String actorId});

  Future<void> setDiscount({
    required String ticketId,
    required DiscountKind kind,
    required int value,
    required String actorId,
  });

  Future<void> fire({required String ticketId, required String actorId});

  Future<void> markLineReady({required String ticketId, required String lineId});

  Future<void> markTicketReady({required String ticketId});

  Future<void> serve({required String ticketId, required String actorId});

  /// Applies one payment row and returns the recomputed ticket. Allocates the
  /// bill number on first settlement (SKILLS.md §C2), writes an audit event, and
  /// refreshes the paid cache — all in one transaction.
  Future<OrderTicket> recordPayment({
    required String ticketId,
    required PaymentMode mode,
    required Money amount,
    Money? tendered,
    String? reference,
    required String actorId,
    String? creditParty,
    String? creditPhone,
  });

  Future<OrderTicket> voidTicket({
    required String ticketId,
    required String reason,
    required String actorId,
  });

  /// For the printing pipeline: the settled ticket as it should appear on paper.
  Future<OrderTicket?> loadForReceipt(String ticketId);
}

/// The slice of a menu item the order flow needs. Declared here (not importing
/// `menu.dart`) so the order feature never gains a compile-time dependency on the
/// menu module (R1) — the UI passes an item in, the repo snapshots what it needs.
abstract interface class MenuItemLike {
  String get id;
  String get name;
  Money get price;
  int get taxPercent;
  String? get kitchenLabel;
}

/// Likewise: only what a line snapshot needs from a modifier.
abstract interface class ModifierOptionLike {
  String get id;
  String get groupId;
  String get name;
  Money get priceDelta;
}
