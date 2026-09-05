/// The ticket aggregate (Task T2) — the single object both counter sections share.
///
/// Order-taking writes lines to it and never touches money beyond the price
/// snapshot; billing writes payments to it and never touches the menu. That
/// separation is the Q4 requirement, and putting both halves in one aggregate
/// here is what makes it enforceable rather than a convention.
library;

import '../../core/money/money.dart';
import '../../core/money/money_delta.dart';
import 'bill_totals.dart';
import 'enums.dart';
import 'menu.dart';
import 'order_line.dart';

// The line/discount types live in order_line.dart and the bill arithmetic in
// bill_totals.dart; both are re-exported so a caller keeps ONE import for the
// whole ticket aggregate (R2's split must not become the UI's problem).
export 'bill_totals.dart' show BillTotals;
export 'order_line.dart' show OrderDiscount, DiscountKind, TicketLine;

/// The ticket. Immutable aggregate; the repository is the only thing that may
/// persist it, and every mutation here returns a new instance so a failed
/// transaction leaves no half-written object in memory.
final class OrderTicket {
  const OrderTicket({
    required this.id,
    required this.type,
    required this.status,
    required this.openedBy,
    required this.openedAt,
    this.billNumber,
    this.tableOrName,
    this.lines = const <TicketLine>[],
    this.discount = OrderDiscount.none,
    this.note,
    this.paid = Money.zero,
    this.due = Money.zero,
    this.voidReason,
    this.firedAt,
    this.readyAt,
    this.servedAt,
    this.closedAt,
    this.updatedAt,
    this.syncedAt,
  });

  final String id;
  final int? billNumber;
  final OrderType type;
  final OrderStatus status;

  /// Counter/table name (T3, Sharma ji) — the search key for the due list (O4).
  final String? tableOrName;
  final List<TicketLine> lines;
  final OrderDiscount discount;
  final String? note;

  final Money paid;

  /// Derived from `total - paid` at compute time; stored only as the report cache.
  final Money due;

  final String? voidReason;
  final String openedBy;
  final DateTime? firedAt;
  final DateTime? readyAt;
  final DateTime? servedAt;
  final DateTime? closedAt;
  final DateTime openedAt;
  final DateTime? updatedAt;
  final DateTime? syncedAt;

  BillTotals get totals => BillTotals.compute(lines: lines, discount: discount);
  Money get total => totals.total;
  bool get isSettled => status.isSettled;
  bool get appearsInDueList => status.appearsInDueList && (total - paid).isPositive;
  int get lineCount => lines.where((l) => !l.isFullyCancelled).length;
  int get itemCount => lines.where((l) => !l.isFullyCancelled).fold(0, (a, l) => a + l.liveQuantity);

  /// Held-tickets list row (O4): "T3 · 4 items · ₹450 · 22:15".
  String get summaryLabel =>
      '${tableOrName ?? (billNumber == null ? 'draft' : '#$billNumber')} · '
      '$itemCount item${itemCount == 1 ? '' : 's'} · $total';

  TicketLine? lineById(String lineId) {
    for (final l in lines) {
      if (l.id == lineId) return l;
    }
    return null;
  }

  // ------------------------------------------------------------- mutations --

  OrderTicket withLine(TicketLine line) {
    if (!status.allowsAddingItems) {
      throw StateError('Cannot add items to a ${status.name} ticket');
    }
    return _copy(lines: [...lines, line]);
  }

  OrderTicket withQuantity(String lineId, int quantity) {
    if (quantity < 1) throw ArgumentError('Use cancelLine for quantity 0');
    return _copy(lines: [
      for (final l in lines) l.id == lineId ? l.copyWith(quantity: quantity) : l,
    ]);
  }

  /// Marks the *pending* lines as fired. Course 2 firing must not re-send
  /// course 1 to the kitchen (O5), which is why this is line-level, not a
  /// ticket-level boolean.
  OrderTicket fired({required DateTime at}) {
    if (!lines.any((l) => l.status.isFireable && !l.isFullyCancelled)) {
      throw StateError('Nothing left to fire on a ${status.name} ticket');
    }
    return _copy(
      status: OrderStatus.inKitchen,
      firedAt: firedAt ?? at,
      lines: [
        for (final l in lines) l.status.isFireable ? l.copyWith(status: LineStatus.fired) : l,
      ],
    );
  }

  OrderTicket lineReady(String lineId) => _copy(lines: [
    for (final l in lines) l.id == lineId ? l.copyWith(status: LineStatus.ready) : l,
  ]);

  /// Ticket moves to READY only when every live line is ready or better (K2).
  OrderTicket maybeReady({required DateTime at}) {
    final allReady = lines
        .where((l) => !l.isFullyCancelled)
        .every((l) => l.status == LineStatus.ready || l.status == LineStatus.served);
    if (!allReady || status != OrderStatus.inKitchen) return this;
    return _copy(status: OrderStatus.ready, readyAt: at);
  }

  OrderTicket served({required DateTime at}) => _copy(
    status: OrderStatus.served,
    servedAt: at,
    lines: [
      for (final l in lines) l.status == LineStatus.ready ? l.copyWith(status: LineStatus.served) : l,
    ],
  );

  /// Applies a payment amount and returns the new due. Refuses overpayment
  /// rather than clamping it — an overpayment means a mis-keyed amount, and
  /// silently fixing it loses the customer ₹400 (SKILLS.md §B3).
  OrderTicket withPaymentApplied(Money amount, {required DateTime at}) {
    if (!status.allowsPayment) {
      throw StateError('Cannot take payment on a ${status.name} ticket');
    }
    final newTotal = total;
    final newPaid = paid + amount;
    if (newPaid > newTotal) {
      throw ArgumentError(
        'Paying ${newPaid.paise}p on a ${newTotal.paise}p bill overpays by '
        '${(newPaid - newTotal).paise}p — reduce the amount or record a refund',
      );
    }
    final settled = newPaid.paise == newTotal.paise;
    return _copy(
      paid: newPaid,
      due: settled ? Money.zero : Money(newTotal.paise - newPaid.paise),
      status: settled ? OrderStatus.paid : OrderStatus.partiallyPaid,
      closedAt: settled ? at : null,
    );
  }

  /// Cancels [quantity] units of a line; omit it to cancel the whole live qty.
  /// Partial cancellation keeps the original quantity, so reports can still show
  /// ordered-vs-served (O6).
  OrderTicket cancelledLine(String lineId, {int? quantity}) => _copy(lines: [
    for (final l in lines)
      if (l.id == lineId) _cancel(l, quantity ?? l.liveQuantity) else l,
  ]);

  static TicketLine _cancel(TicketLine l, int qty) {
    final cancelQty = qty.clamp(0, l.quantity);
    final nowCancelled = l.cancelledQuantity + cancelQty;
    return l.copyWith(
      cancelledQuantity: nowCancelled,
      status: nowCancelled >= l.quantity ? LineStatus.cancelled : l.status,
    );
  }

  OrderTicket voided({required String reason, required DateTime at}) {
    if (paid.isPositive) {
      throw StateError(
        'A ticket with ${paid.paise}p already paid cannot be voided — refund or '
        'cancel the specific lines instead',
      );
    }
    if (reason.trim().isEmpty) throw ArgumentError('A void needs a reason');
    return _copy(
      status: OrderStatus.voided,
      voidReason: reason.trim(),
      closedAt: at,
    );
  }

  /// Restores a line cancelled by mistake (O6). Only the cancellation is
  /// undone — quantity, price and note are untouched, so a "2 of 3 cancelled"
  /// row that is restored comes back as the 2 the cashier meant, not as a
  /// fresh 3.
  OrderTicket uncancelledLine(String lineId) => _copy(lines: [
    for (final l in lines)
      if (l.id == lineId) l.copyWith(cancelledQuantity: 0) else l,
  ]);

  OrderTicket withDiscount(OrderDiscount value) => _copy(discount: value);
  OrderTicket withNote(String? value) => _copy(note: value);

  OrderTicket _copy({
    OrderStatus? status,
    Money? paid,
    Money? due,
    List<TicketLine>? lines,
    OrderDiscount? discount,
    String? note,
    String? voidReason,
    DateTime? firedAt,
    DateTime? readyAt,
    DateTime? servedAt,
    DateTime? closedAt,
    bool? touched,
  }) => OrderTicket(
    id: id,
    billNumber: billNumber,
    type: type,
    status: status ?? this.status,
    tableOrName: tableOrName,
    lines: lines ?? this.lines,
    discount: discount ?? this.discount,
    note: note ?? this.note,
    paid: paid ?? this.paid,
    due: due ?? this.due,
    voidReason: voidReason ?? this.voidReason,
    openedBy: openedBy,
    firedAt: firedAt ?? this.firedAt,
    readyAt: readyAt ?? this.readyAt,
    servedAt: servedAt ?? this.servedAt,
    closedAt: closedAt ?? this.closedAt,
    openedAt: openedAt,
    updatedAt: touched == null ? DateTime.now() : updatedAt,
    syncedAt: syncedAt,
  );

  /// The ONE legitimate late change to a ticket header: a bill number allocated
  /// at first settlement (§C2). `_copy` deliberately cannot touch
  /// `billNumber`/`type`/`openedAt`, because a status transition must never
  /// silently re-number or re-date a bill; this method is explicit about it and
  /// is used by the repository only.
  OrderTicket copyWith({int? billNumber, OrderStatus? status, DateTime? updatedAt}) => OrderTicket(
    id: id,
    billNumber: billNumber ?? this.billNumber,
    type: type,
    status: status ?? this.status,
    tableOrName: tableOrName,
    lines: lines,
    discount: discount,
    note: note,
    paid: paid,
    due: due,
    voidReason: voidReason,
    openedBy: openedBy,
    firedAt: firedAt,
    readyAt: readyAt,
    servedAt: servedAt,
    closedAt: closedAt,
    openedAt: openedAt,
    updatedAt: updatedAt ?? this.updatedAt,
    syncedAt: syncedAt,
  );

  /// "Ready all" on the KDS (K2): every live PENDING/FIRED line becomes READY.
  /// Cancelled lines are skipped, which is what stops a cancelled dish from
  /// showing as served to the floor.
  OrderTicket readyAll({required DateTime at}) {
    bool moves(TicketLine l) =>
        !l.isFullyCancelled && (l.status == LineStatus.pending || l.status == LineStatus.fired);
    if (!lines.any(moves)) return this;
    return _copy(
      lines: [for (final l in lines) if (moves(l)) l.copyWith(status: LineStatus.ready) else l],
      readyAt: at,
    );
  }

  /// Re-attaching or clearing a line note after a mis-tap (O3). Passing null
  /// clears it — `copyWith` maps null to "no note" here on purpose, because the
  /// UI's clear button and its "no note" state are the same thing.
  OrderTicket setLineNote(String lineId, String? note) {
    final cleaned = note?.trim();
    return _copy(
      lines: [
        for (final l in lines)
          if (l.id == lineId) l.copyWith(note: (cleaned == null || cleaned.isEmpty) ? null : cleaned) else l,
      ],
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'billNumber': billNumber,
    'type': type.name,
    'status': status.name,
    'tableOrName': tableOrName,
    'lines': lines.map((l) => l.toJson()).toList(),
    'discount': discount.toJson(),
    'note': note,
    'paidPaise': paid.toJson(),
    'duePaise': due.toJson(),
    'voidReason': voidReason,
    'openedBy': openedBy,
    'openedAt': openedAt.toIso8601String(),
    'firedAt': firedAt?.toIso8601String(),
    'readyAt': readyAt?.toIso8601String(),
    'servedAt': servedAt?.toIso8601String(),
    'closedAt': closedAt?.toIso8601String(),
    'updatedAt': updatedAt?.toIso8601String(),
    'syncedAt': syncedAt?.toIso8601String(),
  };

  factory OrderTicket.fromJson(Map<String, Object?> j) => OrderTicket(
    id: j['id']! as String,
    billNumber: j['billNumber'] as int?,
    type: OrderType.fromName(j['type'] as String?),
    status: OrderStatus.fromName(j['status'] as String?),
    tableOrName: j['tableOrName'] as String?,
    lines: [
      for (final raw in (j['lines'] as List<Object?>? ?? const <Object?>[]))
        TicketLine.fromJson(raw! as Map<String, Object?>),
    ],
    discount: OrderDiscount.fromJson(j['discount'] as Map<String, Object?>?),
    note: j['note'] as String?,
    paid: Money.fromJson(j['paidPaise'] ?? 0),
    due: Money.fromJson(j['duePaise'] ?? 0),
    voidReason: j['voidReason'] as String?,
    openedBy: j['openedBy']! as String,
    openedAt: DateTime.parse(j['openedAt']! as String),
    firedAt: _date(j['firedAt']),
    readyAt: _date(j['readyAt']),
    servedAt: _date(j['servedAt']),
    closedAt: _date(j['closedAt']),
    updatedAt: _date(j['updatedAt']),
    syncedAt: _date(j['syncedAt']),
  );

  static DateTime? _date(Object? raw) => raw == null ? null : DateTime.parse(raw! as String);

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is OrderTicket &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.billNumber == billNumber &&
      other.type == type &&
      other.status == status &&
      other.tableOrName == tableOrName &&
      deepEquals(other.lines, lines) &&
      other.discount == discount &&
      other.note == note &&
      other.paid == paid &&
      other.due == due &&
      other.voidReason == voidReason &&
      other.openedBy == openedBy &&
      other.firedAt == firedAt &&
      other.readyAt == readyAt &&
      other.servedAt == servedAt &&
      other.closedAt == closedAt &&
      other.openedAt == openedAt &&
      other.updatedAt == updatedAt &&
      other.syncedAt == syncedAt;

  @override
  int get hashCode => Object.hashAll([
      id.hashCode,
      billNumber.hashCode,
      type.hashCode,
      status.hashCode,
      tableOrName.hashCode,
      deepHash(lines),
      discount.hashCode,
      note.hashCode,
      paid.hashCode,
      due.hashCode,
      voidReason.hashCode,
      openedBy.hashCode,
      firedAt.hashCode,
      readyAt.hashCode,
      servedAt.hashCode,
      closedAt.hashCode,
      openedAt.hashCode,
      updatedAt.hashCode,
      syncedAt.hashCode,
    ]);
}
