/// Stock read/write models (Task I1). Pure Dart; milli-unit quantities.
///
/// Why milli-units instead of a double for grams: same reason money is paise
/// (SKILLS.md §B1). `0.1 kg + 0.2 kg` must not print `0.30000000000000004` on a
/// purchase list, and integer subtraction can never go silently negative in a
/// way that breaks the ledger's own reconciliation.
library;

import '../../core/money/money.dart';
import '../tables/stock_tables.dart' show StockMoveKind;

export '../tables/stock_tables.dart' show StockMoveKind;

final class StockItem {
  const StockItem({
    required this.id,
    required this.name,
    this.unit = 'pcs',
    this.onHandMilli = 0,
    this.reorderMilli = 0,
    this.active = true,
  });

  final String id;
  final String name;
  final String unit;
  final int onHandMilli;
  final int reorderMilli;
  final bool active;

  bool get isLow => onHandMilli <= reorderMilli;
  bool get isOut => onHandMilli <= 0;

  /// "250 g" / "12 pcs" — the milli-unit becomes a decimal only for display.
  String get display {
    final whole = onHandMilli ~/ 1000;
    final frac = (onHandMilli % 1000) ~/ 10; // one decimal place is plenty
    final number = frac == 0 ? '$whole' : '$whole.$frac';
    return '$number $unit';
  }

  StockItem copyWith({
    String? name,
    String? unit,
    int? onHandMilli,
    int? reorderMilli,
    bool? active,
  }) => StockItem(
    id: id,
    name: name ?? this.name,
    unit: unit ?? this.unit,
    onHandMilli: onHandMilli ?? this.onHandMilli,
    reorderMilli: reorderMilli ?? this.reorderMilli,
    active: active ?? this.active,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'unit': unit,
    'onHandMilli': onHandMilli,
    'reorderMilli': reorderMilli,
    'active': active,
  };

  factory StockItem.fromJson(Map<String, Object?> j) => StockItem(
    id: j['id']! as String,
    name: j['name']! as String,
    unit: (j['unit'] as String?) ?? 'pcs',
    onHandMilli: (j['onHandMilli'] as int?) ?? 0,
    reorderMilli: (j['reorderMilli'] as int?) ?? 0,
    active: (j['active'] as bool?) ?? true,
  );

  @override
  bool operator ==(Object other) =>
      other is StockItem &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.name == name &&
      other.unit == unit &&
      other.onHandMilli == onHandMilli &&
      other.reorderMilli == reorderMilli &&
      other.active == active;

  @override
  int get hashCode => Object.hashAll([id, name, unit, onHandMilli, reorderMilli, active]);
}

/// One ingredient line of a menu item's recipe.
class RecipeLine {
  const RecipeLine({
    required this.id,
    required this.itemId,
    required this.stockItemId,
    required this.stockName,
    required this.perUnitMilli,
    this.unit = 'pcs',
  });

  final String id;
  final String itemId;
  final String stockItemId;
  final String stockName;
  final int perUnitMilli;
  final String unit;

  /// What [soldQty] units consume — the only place the multiply happens.
  int consumptionFor(int soldQty) => perUnitMilli * soldQty;

  Map<String, Object?> toJson() => {
    'id': id,
    'itemId': itemId,
    'stockItemId': stockItemId,
    'stockName': stockName,
    'perUnitMilli': perUnitMilli,
    'unit': unit,
  };

  factory RecipeLine.fromJson(Map<String, Object?> j) => RecipeLine(
    id: j['id']! as String,
    itemId: j['itemId']! as String,
    stockItemId: j['stockItemId']! as String,
    stockName: (j['stockName'] as String?) ?? '',
    perUnitMilli: (j['perUnitMilli'] as int?) ?? 0,
    unit: (j['unit'] as String?) ?? 'pcs',
  );

  @override
  bool operator ==(Object other) =>
      other is RecipeLine &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.itemId == itemId &&
      other.stockItemId == stockItemId &&
      other.perUnitMilli == perUnitMilli;

  @override
  int get hashCode => Object.hashAll([id, itemId, stockItemId, perUnitMilli]);
}

/// A stock row joined with the menu items that consume it (I3's list view).
final class StockLine {
  const StockLine({
    required this.item,
    required this.usedByItemNames,
    required this.lastMovementAt,
  });

  final StockItem item;
  final List<String> usedByItemNames;
  final DateTime? lastMovementAt;

  bool get needsAttention => item.isLow;
  String get attention =>
      item.isOut ? 'OUT' : (item.isLow ? 'LOW' : 'ok ${item.display}');
}

/// Movement row as the UI sees it.
final class StockMovementRowData {
  const StockMovementRowData({
    required this.id,
    required this.stockItemId,
    required this.kind,
    required this.deltaMilli,
    required this.resultingMilli,
    required this.at,
    this.ticketId,
    this.note,
    this.actorId,
  });

  final String id;
  final String stockItemId;
  final StockMoveKind kind;

  /// Signed milli-units (+receive, -sale/wastage); a `count` row stores the
  /// difference it made, never the absolute figure, so the ledger still sums.
  final int deltaMilli;

  /// On-hand immediately after this row — makes the history replayable.
  final int resultingMilli;
  final DateTime at;

  /// Non-null only for `sale`: the ticket that consumed it (I2's dedup key).
  final String? ticketId;
  final String? note;
  final String? actorId;

  Map<String, Object?> toJson() => {
    'id': id,
    'stockItemId': stockItemId,
    'kind': kind.name,
    'deltaMilli': deltaMilli,
    'resultingMilli': resultingMilli,
    'at': at.toIso8601String(),
    'ticketId': ticketId,
    'note': note,
    'actorId': actorId,
  };

  factory StockMovementRowData.fromJson(Map<String, Object?> j) => StockMovementRowData(
    id: j['id']! as String,
    stockItemId: j['stockItemId']! as String,
    kind: StockMoveKind.fromName(j['kind']! as String),
    deltaMilli: j['deltaMilli']! as int,
    resultingMilli: j['resultingMilli']! as int,
    at: DateTime.parse(j['at']! as String),
    ticketId: j['ticketId'] as String?,
    note: j['note'] as String?,
    actorId: j['actorId'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      other is StockMovementRowData &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.stockItemId == stockItemId &&
      other.kind == kind &&
      other.deltaMilli == deltaMilli &&
      other.resultingMilli == resultingMilli &&
      other.ticketId == ticketId;

  @override
  int get hashCode => Object.hashAll([id, stockItemId, kind, deltaMilli, resultingMilli, ticketId]);
}

/// Pure stock maths, kept separate so it is testable without a database and
/// reusable by a future import-from-CSV tool.
class StockMath {
  StockMath._();

  /// New on-hand after a movement. Clamped at zero is NOT allowed here: a
  /// negative result means the sale should have been blocked, and reporting the
  /// negative number is what makes that visible instead of hiding it.
  static int apply(int onHandMilli, int deltaMilli) => onHandMilli + deltaMilli;

  /// Delta required to move on-hand to a physical count (a `count` movement).
  static int deltaToReach(int onHandMilli, int countedMilli) => countedMilli - onHandMilli;

  /// Whether a ticket of these deductions can be served from current stock.
  static bool canServe({
    required Map<String, int> onHandByStockId,
    required Map<String, int> requiredByStockId,
  }) {
    for (final e in requiredByStockId.entries) {
      if ((onHandByStockId[e.key] ?? 0) < e.value) return false;
    }
    return true;
  }

  /// Monetary value of a stock position, for a future valuation report:
  /// `qty * unitCost` in paise, integer throughout.
  static Money valueOf({required int onHandMilli, required Money unitCost}) =>
      Money((onHandMilli * unitCost.paise) ~/ 1000);
}
