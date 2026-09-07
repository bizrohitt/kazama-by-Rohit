/// Kazama POS shared enums (Task T2). Pure Dart, no Flutter import.
///
/// Enums here are the *only* vocabulary shared between features (R1). A feature
/// may pass an `OrderStatus` to another feature only because it lives in `data/`,
/// never because it imports that feature's file.
///
/// `index` is the stable integer persisted by drift — **never reorder a value**,
/// append new states at the end only. The name strings are display/JSON only.
library;

/// Who the ticket is for. Drives whether payment is expected before or after food.
enum OrderType {
  dineIn('Dine-in'),
  takeaway('Takeaway'),
  delivery('Delivery');

  const OrderType(this.label);
  final String label;

  /// Dine-in is the "eat first, pay later" path the counter described in Q4.
  bool get isPayAfterEating => this == OrderType.dineIn;
  bool get isPayUpfront => this != OrderType.dineIn;

  static OrderType fromName(String? name) => OrderType.values.firstWhere(
    (e) => e.name == name,
    orElse: () => OrderType.takeaway,
  );
}

/// Ticket lifecycle. The transition table itself lives in
/// `features/order_flow/domain/ticket_state.dart` (Task O1) — this enum only
/// carries the display label and the coarse predicates the UI reads.
enum OrderStatus {
  draft('Draft'),
  open('Open'),
  inKitchen('Cooking'),
  ready('Ready'),
  served('Served'),
  partiallyPaid('Part paid'),
  paid('Paid'),
  voided('Voided');

  const OrderStatus(this.label);
  final String label;

  /// Still editable: a new course may be added and lines cancelled.
  /// `paid`/`voided` are terminal, `draft` has no lines yet.
  bool get isSettled => this == OrderStatus.paid || this == OrderStatus.voided;
  bool get isClosed => isSettled;

  /// Voided bills are reported separately (an owner must see them) but never
  /// counted as takings — the reports screen needs this as a first-class
  /// predicate so "excluded from revenue" is one rule, not a string compare
  /// against a status name scattered through R2.
  bool get isVoided => this == OrderStatus.voided;
  /// Everything the counter still has to *do* about a ticket, i.e. the due list
  /// plus an unnumbered draft: `watchOpenTickets()` uses this so a new status
  /// cannot be silently hidden from the held-tickets screen (O4).
  bool get appearsInHeldList => !isSettled;
  bool get appearsInDueList =>
      this == OrderStatus.open ||
      this == OrderStatus.inKitchen ||
      this == OrderStatus.ready ||
      this == OrderStatus.served ||
      this == OrderStatus.partiallyPaid;
  bool get appearsOnKds =>
      this == OrderStatus.inKitchen || this == OrderStatus.ready;
  bool get allowsPayment => !isSettled;
  bool get allowsAddingItems =>
      this == OrderStatus.draft ||
      this == OrderStatus.open ||
      this == OrderStatus.inKitchen;

  static OrderStatus fromName(String? name) => OrderStatus.values.firstWhere(
    (e) => e.name == name,
    orElse: () => throw FormatException('Unknown OrderStatus: $name'),
  );
}

/// Per-line kitchen progress. A table that ordered twice has lines in different
/// states at once — that is why this is NOT derived from [OrderStatus].
enum LineStatus {
  pending('Not fired'),
  fired('Cooking'),
  ready('Ready'),
  served('Served'),
  cancelled('Cancelled');

  const LineStatus(this.label);
  final String label;

  bool get isFireable => this == LineStatus.pending;
  bool get isCancellable =>
      this == LineStatus.pending || this == LineStatus.fired;
  bool get countsTowardsStock =>
      this == LineStatus.fired || this == LineStatus.ready || this == LineStatus.served;

  static LineStatus fromName(String? name) => LineStatus.values.firstWhere(
    (e) => e.name == name,
    orElse: () => throw FormatException('Unknown LineStatus: $name'),
  );
}

/// v1 has no gateway (Q5): UPI and CARD are *recorded*, never verified.
enum PaymentMode {
  cash('Cash'),
  upi('UPI'),
  card('Card'),
  credit('Pay later');

  const PaymentMode(this.label);
  final String label;

  /// Only cash physically enters the drawer, so only cash affects the shift count.
  bool get affectsCashDrawer => this == PaymentMode.cash;
  /// Credit is a promise, not money: it creates a due and must be settled later.
  bool get createsADue => this == PaymentMode.credit;
  /// UPI/CARD need a free-text reference so the cashier can match a bank SMS.
  bool get wantsReference => this == PaymentMode.upi || this == PaymentMode.card;

  static PaymentMode fromName(String? name) => PaymentMode.values.firstWhere(
    (e) => e.name == name,
    orElse: () => PaymentMode.cash,
  );
}

enum UserRole {
  cashier('Cashier'),
  kitchen('Kitchen'),
  manager('Manager');

  const UserRole(this.label);
  final String label;

  bool get canEditMenu => this == UserRole.manager;
  bool get canBill => this != UserRole.kitchen;
  bool get canSeeReports => this == UserRole.manager;
  bool get canVoid => this == UserRole.manager;
  /// Kitchen and manager work at the KDS; a cashier's screen is the counter.
  bool get canViewKds => this == UserRole.kitchen || this == UserRole.manager;

  static UserRole fromName(String? name) => UserRole.values.firstWhere(
    (e) => e.name == name,
    orElse: () => UserRole.cashier,
  );
}

/// Which kind of slip was printed — a reprint must say COPY on it.
enum ReceiptKind {
  sale('Sale'),
  due('Due / token'),
  voidReceipt('Void'),
  copy('Copy');

  const ReceiptKind(this.label);
  final String label;

  bool get mustBeMarkedCopy => this == ReceiptKind.copy;

  static ReceiptKind fromName(String? name) => ReceiptKind.values.firstWhere(
    (e) => e.name == name,
    orElse: () => ReceiptKind.sale,
  );
}

/// Outbox operation kind (Task T5).
enum MutationOp {
  insert('INSERT'),
  update('UPDATE'),
  delete('DELETE');

  const MutationOp(this.wire);
  final String wire;

  static MutationOp fromWire(String? wire) => MutationOp.values.firstWhere(
    (e) => e.wire == wire,
    orElse: () => throw FormatException('Unknown MutationOp: $wire'),
  );
}

/// Outbox row state (Task T5).
enum SyncStatus {
  pending('pending'),
  inFlight('in_flight'),
  stuck('stuck');

  const SyncStatus(this.wire);
  final String wire;

  static SyncStatus fromWire(String? wire) => SyncStatus.values.firstWhere(
    (e) => e.wire == wire,
    orElse: () => SyncStatus.pending,
  );
}
