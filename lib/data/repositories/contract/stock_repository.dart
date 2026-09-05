/// Stock contract (Task I1-I3). Deliberately narrow: consumption happens inside
/// the ORDER transaction (the order repo calls `deductForTicket`), so a sale can
/// never decrement stock without also writing its movement row.
library;

import '../../models/stock.dart';
import '../../../core/money/money.dart';

abstract interface class StockRepository {
  Stream<List<StockLine>> watchStock();

  /// Item ids whose stock is exhausted — the auto sold-out hook for M6.
  Stream<Set<String>> watchSoldOutItemIds();

  Future<StockItem> upsertItem(StockItem item);

  Future<void> deleteItem(String stockItemId);

  /// Manual receive / wastage / count. A `count` row records the delta needed to
  /// reach the counted figure, so the ledger still explains on-hand exactly.
  Future<void> adjust({
    required String stockItemId,
    required StockMoveKind kind,
    required int deltaMilli,
    required int absoluteMilliForCount,
    required String actorId,
    String? note,
  });

  Future<void> setRecipe({required String itemId, required List<RecipeLine> lines});

  Future<List<RecipeLine>> recipeFor(String itemId);

  /// Called from inside the ticket transaction. Idempotent per ticket: a re-fire
  /// or a reprint must NOT deduct twice (I2), which is the whole reason movement
  /// rows carry `ticket_id`.
  /// Rejects the sale when an ingredient runs out (the impl throws
  /// `InsufficientStock`, listing the shortfall) — which is only worth having if
  /// the counter can also say "sell it anyway", so the override exists as an
  /// explicit method rather than a `bool force` flag a UI could pass by
  /// accident.
  Future<void> deductForTicket({
    required String ticketId,
    required List<StockDeduction> deductions,
    required String actorId,
  });

  Future<void> forceDeductForTicket({
    required String ticketId,
    required List<StockDeduction> deductions,
    required String actorId,
  });

  /// Editor-only link between a dish and the stock row its barcodes/quick
  /// availability use. Kept off the general item save path so a menu edit cannot
  /// silently re-point inventory (M6).
  Future<void> linkItemToStock({required String menuItemId, required String? stockItemId});

  /// Rupee value of the shelf, for the one number an owner always asks for (I3).
  Future<Money> positionValue({required Map<String, Money> unitCostByStockId});

  Future<List<StockMovementRowData>> movementsFor(String stockItemId, {int limit = 50});
}

/// What the order flow hands the stock module: item id + sold quantity. The
/// repo resolves recipes, so the order module never imports stock maths (R1).
class StockDeduction {
  const StockDeduction({required this.itemId, required this.quantity});

  final String itemId;
  final int quantity;
}
