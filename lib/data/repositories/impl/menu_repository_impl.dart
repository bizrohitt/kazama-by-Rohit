/// drift-backed menu repository (Task M1/M2/M6).
library;

import '../../../core/db/app_database.dart';
import '../../../core/utils/id.dart';
import '../../models/menu.dart';
import '../../models/stock.dart';
import '../../seed/fast_food_seed.dart';
import '../contract/menu_repository.dart';

class MenuRepositoryImpl implements MenuRepository {
  MenuRepositoryImpl(this.db, {IdFactory? idFactory}) : ids = idFactory ?? IdFactory();

  @override
  final AppDatabase db;

  /// Only used for seeded opening-stock movement ids, but it is an `IdFactory`
  /// so a snapshot test can make those ids deterministic too.
  final IdFactory ids;

  @override
  Stream<List<MenuCategory>> watchCategories() => db.watchCategories();

  @override
  Stream<List<MenuItem>> watchMenu({bool includeInactive = false}) =>
      db.watchItems(includeInactive: includeInactive);

  @override
  Stream<List<MenuItem>> watchItemsByCategory(String categoryId) => db.watchItems(categoryId: categoryId);

  @override
  Future<List<ModifierGroup>> loadGroupsFor(Set<String> groupIds) => db.groupsFor(groupIds);

  @override
  Future<void> saveItem(MenuItem item) => db.upsertItem(item, at: DateTime.now());

  @override
  Future<void> saveCategory(MenuCategory category) => db.upsertCategory(category, at: DateTime.now());

  @override
  Future<void> saveGroup(ModifierGroup group) => db.upsertGroup(group, at: DateTime.now());

  @override
  Future<void> deactivateItem(String itemId) => db.deactivateItem(itemId, at: DateTime.now());

  @override
  Future<void> soldOut(String itemId, {required bool available}) =>
      db.setItemAvailability(itemId, available: available, at: DateTime.now());

  @override
  Future<void> moveItem(String itemId, int newSortOrder) async {
    final existing = await db.findItem(itemId);
    if (existing == null) return;
    await db.upsertItem(existing.copyWith(sortOrder: newSortOrder), at: DateTime.now());
  }

  @override
  Future<int> seedIfEmpty() async {
    final existing = await db.watchItems(includeInactive: true).first;
    if (existing.isNotEmpty) return 0; // idempotent: never re-seed a live menu
    final now = DateTime.now();
    await db.transaction(() async {
      for (final group in kSeedModifierGroups) {
        await db.upsertGroup(group, at: now);
      }
      for (final category in kSeedCategories) {
        await db.upsertCategory(category, at: now);
      }
      for (final item in kSeedItems) {
        await db.upsertItem(item, at: now);
      }
      // Stock + recipes seed here rather than in a second guard, so the menu
      // and the thing that sells out cannot be seeded on different visits (I1).
      for (final s in kSeedStock) {
        await db.upsertStockItem(s, at: now);
      }
      for (final r in kSeedRecipes) {
        await db.upsertRecipe(r, at: now);
      }
      // Opening stock must exist as movements, not just as a number on the row:
      // `stock_movements` is the only history of why on-hand is what it is (I1).
      // An opening count is a movement like any other, with `receive` as its
      // kind: "on-hand is 120 buns" and "we received 120 buns" are the same fact
      // on day one, and recording only the number would leave the ledger unable
      // to explain itself (I1).
      for (final s in kSeedStock) {
        await db.insertMovement(
          StockMovementRowData(
            id: ids.newId(),
            stockItemId: s.id,
            kind: StockMoveKind.receive,
            deltaMilli: s.onHandMilli,
            resultingMilli: s.onHandMilli,
            at: now,
            actorId: 'seed',
            note: 'Opening stock',
          ),
        );
      }
    });
    return kSeedItems.length;
  }

  @override
  Future<List<MenuItem>> allItems() async => db.watchItems(includeInactive: true).first;
}
