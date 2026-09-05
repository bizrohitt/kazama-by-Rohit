/// Discount + line snapshot models (Task T2, split out of order.dart for the
/// 600-line rule — see SKILLS.md §A3). A "line" is what the counter ordered,
/// frozen at order time: `BillTotals` in order.dart reads these and nothing else.
library;

import '../../core/money/money.dart';
import 'enums.dart';
import 'menu.dart';

/// Discount as entered by the cashier: either a flat amount or a percentage of
/// the discounted base. Kept as the *intent*, so a reprint recomputes the same
/// number instead of trusting a stored paise value that a rounding change could
/// have made stale.
final class OrderDiscount {
  const OrderDiscount(this.kind, this.value);

  final DiscountKind kind;

  /// percent: 10 means 10%. absolute: paise (so `10` here means 10 paise).
  final int value;

  bool get isNone => kind == DiscountKind.none || value <= 0;

  Money amountFor(Money base) => switch (kind) {
    DiscountKind.none => Money.zero,
    DiscountKind.absolute => Money(value > base.paise ? base.paise : value),
    DiscountKind.percent => base.percentOf(value * 100),
  };

  Map<String, Object?> toJson() => {'kind': kind.name, 'value': value};

  factory OrderDiscount.fromJson(Map<String, Object?>? j) {
    if (j == null) return const OrderDiscount(DiscountKind.none, 0);
    return OrderDiscount(
      DiscountKind.values.firstWhere(
        (e) => e.name == j['kind'],
        orElse: () => DiscountKind.none,
      ),
      (j['value'] as int?) ?? 0,
    );
  }

  static const OrderDiscount none = OrderDiscount(DiscountKind.none, 0);

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is OrderDiscount &&
      other.runtimeType == runtimeType &&
      other.kind == kind &&
      other.value == value;

  @override
  int get hashCode => Object.hashAll([
      kind.hashCode,
      value.hashCode,
    ]);
}

enum DiscountKind {
  none('No discount'),
  absolute('₹ off'),
  percent('% off');

  const DiscountKind(this.label);
  final String label;
}

/// A line as it existed *when ordered*. Names, prices and modifiers are
/// snapshotted, not joined, so editing the menu (M4) never rewrites history —
/// a bill from last week must still print last week's price and last week's
/// modifier text, and yesterday's report must not change.
final class TicketLine {
  const TicketLine({
    required this.id,
    required this.itemId,
    required this.nameSnapshot,
    required this.unitPrice,
    required this.taxPercent,
    this.quantity = 1,
    this.kitchenLabel,
    this.modifiers = const <ModifierOption>[],
    this.note,
    this.status = LineStatus.pending,
    this.cancelledQuantity = 0,
  });

  final String id;
  final String itemId;
  final String nameSnapshot;
  final String? kitchenLabel;

  /// Full per-unit price including modifier upcharges, as sold.
  final Money unitPrice;
  final int taxPercent;
  final int quantity;
  final List<ModifierOption> modifiers;
  final String? note;
  final LineStatus status;

  /// Partial cancellation (3 samosas, 2 cancelled, 1 still coming). Keeps the
  /// original quantity so the report can still show what was ordered vs served.
  final int cancelledQuantity;

  int get liveQuantity => quantity - cancelledQuantity;
  bool get isFullyCancelled => liveQuantity <= 0;
  bool get isEditable => status.isCancellable && !status.isSettledInKitchen;

  /// Line total for the *live* quantity only — cancelled paise never bill.
  Money get lineTotal => unitPrice.scale(liveQuantity < 0 ? 0 : liveQuantity);
  Money get tax => Money.taxFromInclusive(lineTotal, taxPercent);
  Money get base => lineTotal - tax;

  String get displayLabel => (kitchenLabel?.isNotEmpty ?? false) ? kitchenLabel! : nameSnapshot;

  TicketLine copyWith({
    int? quantity,
    LineStatus? status,
    String? note,
    int? cancelledQuantity,
    List<ModifierOption>? modifiers,
    bool? noteSet,
  }) => TicketLine(
    id: id,
    itemId: itemId,
    nameSnapshot: nameSnapshot,
    kitchenLabel: kitchenLabel,
    unitPrice: unitPrice,
    taxPercent: taxPercent,
    quantity: quantity ?? this.quantity,
    modifiers: modifiers ?? this.modifiers,
    note: noteSet == true ? note : (note ?? this.note),
    status: status ?? this.status,
    cancelledQuantity: cancelledQuantity ?? this.cancelledQuantity,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'itemId': itemId,
    'nameSnapshot': nameSnapshot,
    'kitchenLabel': kitchenLabel,
    'unitPricePaise': unitPrice.toJson(),
    'taxPercent': taxPercent,
    'quantity': quantity,
    'modifiers': modifiers.map((m) => m.toJson()).toList(),
    'note': note,
    'status': status.name,
    'cancelledQuantity': cancelledQuantity,
  };

  factory TicketLine.fromJson(Map<String, Object?> j) => TicketLine(
    id: j['id']! as String,
    itemId: j['itemId']! as String,
    nameSnapshot: j['nameSnapshot']! as String,
    kitchenLabel: j['kitchenLabel'] as String?,
    unitPrice: Money.fromJson(j['unitPricePaise']),
    taxPercent: (j['taxPercent'] as int?) ?? 0,
    quantity: (j['quantity'] as int?) ?? 1,
    modifiers: [
      for (final raw in (j['modifiers'] as List<Object?>? ?? const <Object?>[]))
        ModifierOption.fromJson(raw! as Map<String, Object?>),
    ],
    note: j['note'] as String?,
    status: LineStatus.fromName(j['status'] as String?),
    cancelledQuantity: (j['cancelledQuantity'] as int?) ?? 0,
  );

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is TicketLine &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.itemId == itemId &&
      other.nameSnapshot == nameSnapshot &&
      other.kitchenLabel == kitchenLabel &&
      other.unitPrice == unitPrice &&
      other.taxPercent == taxPercent &&
      other.quantity == quantity &&
      deepEquals(other.modifiers, modifiers) &&
      other.note == note &&
      other.status == status &&
      other.cancelledQuantity == cancelledQuantity;

  @override
  int get hashCode => Object.hashAll([
      id.hashCode,
      itemId.hashCode,
      nameSnapshot.hashCode,
      kitchenLabel.hashCode,
      unitPrice.hashCode,
      taxPercent.hashCode,
      quantity.hashCode,
      deepHash(modifiers),
      note.hashCode,
      status.hashCode,
      cancelledQuantity.hashCode,
    ]);
}

extension on LineStatus {
  /// Fired-and-later lines are in the kitchen's hands; a counter edit would
  /// desync the ticket from what's actually being cooked (O6).
  bool get isSettledInKitchen =>
      this == LineStatus.ready || this == LineStatus.served || this == LineStatus.cancelled;
}
