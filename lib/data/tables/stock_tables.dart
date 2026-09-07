/// Stock tables (Task I1). Added as schema v2: a fresh install gets them from
/// `createAll()`, an existing T3-era database gets them from the `from < 2`
/// branch in `AppDatabase.migration.onUpgrade` — both paths are exercised, and
/// the migration is the exact shape every later schema change must follow.
library;

import 'package:drift/drift.dart';

/// A purchasable/raw thing, not a menu item. One item may consume several
/// stocks (a burger = bun + patty + paper wrap), and one stock may serve many
/// items (cheese), so this is its own table rather than columns on menu_items.
@DataClassName('StockItemRow')
class StockItems extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// How a quantity is expressed: `pcs`, `g`, `ml`, `kg`. Kept as text so a
  /// report reads "250 g butter" without a lookup.
  TextColumn get unit => text().withDefault(const Constant('pcs'))();

  /// On-hand quantity in milli-units (1000 = 1 unit), so grams and millilitres
  /// stay integer maths exactly like paise does. A burger patty counted in
  /// whole `pcs` and butter in fractional `g` need one common representation.
  IntColumn get onHandMilli => integer().withDefault(const Constant(0))();

  /// Low-stock alert line, milli-units.
  IntColumn get reorderMilli => integer().withDefault(const Constant(0))();

  /// Soft delete, consistent with the rest of the schema.
  BoolColumn get isActive => boolean().withDefault(const Constant(true)).named('active')();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Per-recipe consumption: 1 sold unit of `menu_item` deducts `perUnitMilli` from
/// `stock_item`. Null `menu_items.stock_item_id` deliberately stays unused —
/// having both a direct link AND a recipe table would let them disagree about
/// what a sale consumed, which is a stock audit you can never resolve.
@DataClassName('ItemRecipeRow')
class ItemRecipes extends Table {
  TextColumn get id => text()();
  TextColumn get itemId => text()();
  TextColumn get stockItemId => text()();

  /// Milli-units consumed per ONE sold unit (2 patties -> 2000).
  IntColumn get perUnitMilli => integer()();

  /// The stock item's unit at the time the recipe was written. A recipe needs
  /// `g` against a `pcs` stock item to render "250 g" on a purchase list, and
  /// joining through stock_items on every read would not survive the stock item
  /// being renamed or deleted.
  TextColumn get unit => text().withDefault(const Constant('pcs'))();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Index> get indexes => [Index(name: 'idx_recipe_item', columns: [itemId])];
}

/// Movement ledger — the only way `on_hand_milli` changes, so a count that
/// disagrees with the ledger is provably a data-entry problem, not a mystery.
/// `sold` rows are written ONCE per ticket, keyed by `ticketId`, which is what
/// makes re-firing a ticket impossible to double-deduct (I2).
@DataClassName('StockMovementRow')
class StockMovements extends Table {
  TextColumn get id => text()();
  TextColumn get stockItemId => text()();

  /// receive | sale | wastage | count  (`StockMoveKind.name`)
  TextColumn get kind => text()();

  /// Signed milli-units: +1000 received, -2000 sold, -500 burnt, count sets the
  /// absolute value via `resulting_milli` instead.
  IntColumn get deltaMilli => integer()();

  /// On-hand right after this row, for a replayable audit.
  IntColumn get resultingMilli => integer()();

  /// The ticket that consumed stock. Null for manual adjustments. UNIQUE per
  /// (stock_item, ticket) is enforced in the DAO query, not a constraint,
  /// because one ticket deducts many stocks.
  TextColumn get ticketId => text().nullable()();
  TextColumn get actorId => text()();
  DateTimeColumn get at => dateTime()();
  TextColumn get note => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<Index> get indexes => [
    Index(name: 'idx_move_stock', columns: [stockItemId, at]),
    Index(name: 'idx_move_ticket', columns: [ticketId]),
  ];
}

enum StockMoveKind {
  receive('Received'),
  sale('Sold'),
  wastage('Wastage'),
  count('Stock count');

  const StockMoveKind(this.label);
  final String label;

  /// Rows are written with `.name` (like every other enum in the schema), so the
  /// read path needs the inverse and must be as loud as the rest of the codebase
  /// about an unknown value: a typo'd kind is a corrupt ledger, not a default.
  static StockMoveKind fromName(String name) => StockMoveKind.values.firstWhere(
    (e) => e.name == name,
    orElse: () => throw FormatException('Unknown StockMoveKind: $name'),
  );
}
