/// Drift table definitions — menu domain (Task T3).
///
/// Schema notes that are easy to get wrong and expensive to change later:
///  * **No `TypeConverter` for `Money`.** Columns are plain `integer paise`
///    (SKILLS.md §B1); the DAO does `Money(row.pricePaise)`. A converter would
///    hide the unit from every raw SQL query in `report_dao`, and reports are
///    exactly where the unit matters. Same reasoning for `MoneyDelta`.
///  * **Enums are stored as `text` names, not indices.** A sync payload read by
///    a Postgres column or eyeballed in a SQLite browser must survive a model
///    reorder. Cost: 6 extra bytes per row, which is free at this scale.
///  * **`active` (delisted) vs `available` (sold out)** are separate columns
///    because the counter treats them differently: one hides the tile, the
///    other greys it out (M6).
library;

import 'package:drift/drift.dart';

/// Naming rule that saves a confusing bug: a getter named `active`, `available`
/// or `required` collides with the column getter drift generates for it, so the
/// *Dart* fields are `isActive`/`isAvailable`/`isRequired` while `.named()` keeps
/// the SQL columns readable (`active`, `available`, `is_required`) for raw
/// report queries. `required` is also a reserved SQL word, hence `is_required`.

@DataClassName('MenuCategoryRow')
class MenuCategories extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// Menu order is operator-driven (M1 reorder), so it lives in the DB, not in
  /// a client-side sort — the KDS and the receipt read the same sequence.
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true)).named('active')();

  /// JSON array of `modifier_groups.id`. Kept as JSON rather than a join table:
  /// a group belongs to exactly one category, the list is short (<10), and it
  /// removes a whole table + DAO round-trip from the order-taking hot path (O3).
  TextColumn get modifierGroupIds => text().withDefault(const Constant('[]'))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ModifierGroupRow')
class ModifierGroups extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// `required` is a reserved word in SQL, and drift quotes identifiers — but a
  /// raw SQL report query would still need quoting, so the column is `is_required`.
  BoolColumn get isRequired => boolean().named('is_required')();
  IntColumn get minSelect => integer().withDefault(const Constant(0))();

  /// 1 = single choice. `0` means "any number" (drift has no nullable-in-default
  /// shortcut, and an explicit 0-sentinel beats a nullable column in every query).
  IntColumn get maxSelect => integer().withDefault(const Constant(1))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ModifierOptionRow')
class ModifierOptions extends Table {
  TextColumn get id => text()();

  /// Owning group. (The reverse pointer lives in `menu_items.modifier_group_ids`,
  /// so a group's options need no join to render.)
  TextColumn get groupId => text().references(ModifierGroups, #id)();
  TextColumn get name => text()();

  /// Added to the parent line's unit price, per unit. Can legitimately be
  /// negative (a "no cheese" removal) — but the line total is clamped upstream,
  /// so the column stays `integer` and `Money`'s non-negative rule survives.
  IntColumn get priceDeltaPaise => integer().withDefault(const Constant(0))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true)).named('active')();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MenuItemRow')
class MenuItems extends Table {
  TextColumn get id => text()();
  TextColumn get categoryId => text().references(MenuCategories, #id)();
  TextColumn get name => text()();

  /// Selling price, tax-INCLUSIVE (the way the menu board reads), paise.
  IntColumn get pricePaise => integer()();

  /// GST percent as an integer (0/5/12/18/28). Integer-only maths lives in
  /// `Money.taxFromInclusive`, so no float ever appears in this row.
  IntColumn get taxPercent => integer().withDefault(const Constant(5))();

  /// What the KDS prints; often shorter than the menu name (K3).
  TextColumn get kitchenLabel => text().nullable()();
  IntColumn get prepSeconds => integer().withDefault(const Constant(180))();

  /// False for a "cover charge"-style line that must bill but never print.
  BoolColumn get isPrintable => boolean().withDefault(const Constant(true)).named('printable')();

  /// Present from day 1 although v1 has no scanner (Q6): adding a UNIQUE column
  /// to a populated table is a migration; having it empty is free.
  TextColumn get barcode => text().nullable().unique()();

  /// FK into `stock_items` when phase I lands. Null = not stock-tracked (combos).
  TextColumn get stockItemId => text().nullable()();
  TextColumn get modifierGroupIds => text().withDefault(const Constant('[]'))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true)).named('active')();

  /// Sold-out toggle. Distinct from `isActive` on purpose (see file header).
  BoolColumn get isAvailable => boolean().withDefault(const Constant(true)).named('available')();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// Rows are never deleted — a bill must still resolve its item after the item
  /// is delisted, so `is_active = 0` is the delete.
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

/// App-wide singletons that don't deserve their own table: the local bill
/// counter (SKILLS.md §C2), printer width, tax mode, last backup timestamp.
/// Read-modify-write of `bill.seq` happens inside the ticket-close transaction.
@DataClassName('AppMetaRow')
class AppMeta extends Table {
  TextColumn get metaKey => text().named('key')();
  TextColumn get metaValue => text().named('value')();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {metaKey};
}

/// Well-known `app_meta` keys, so no feature invents its own spelling.
class MetaKeys {
  MetaKeys._();

  static const String billSeq = 'bill.seq';
  static const String schemaVersion = 'db.schemaVersion';
  static const String backupLastAt = 'backup.lastAt';
  static const String printerPaperColumns = 'printer.paperWidthColumns';
  static const String taxInclusive = 'tax.inclusive';
  static const String deviceId = 'device.id';

  /// Receipt header block. Stored as meta rather than a table: a shop's address
  /// changes twice a decade, and a 4-row table would need a migration + a
  /// backup-table entry for what is one form screen (P4).
  static const String shopName = 'shop.name';
  static const String shopAddress = 'shop.address';
  static const String shopGstin = 'shop.gstin';
  static const String shopPhone = 'shop.phone';
}
