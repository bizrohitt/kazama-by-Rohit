/// Menu repository contract (Task M1). Features import THIS, never the impl.
library;

import '../../models/menu.dart';

abstract interface class MenuRepository {
  Stream<List<MenuCategory>> watchCategories();

  /// Only orderable items by default; the menu editor asks for everything.
  Stream<List<MenuItem>> watchMenu({bool includeInactive = false});

  Stream<List<MenuItem>> watchItemsByCategory(String categoryId);

  Future<List<ModifierGroup>> loadGroupsFor(Set<String> groupIds);

  /// One save = one transaction across category + groups + items, so a half
  /// written menu can never be served to the counter.
  Future<void> saveItem(MenuItem item);

  Future<void> saveCategory(MenuCategory category);

  Future<void> saveGroup(ModifierGroup group);

  Future<void> deactivateItem(String itemId);

  Future<void> soldOut(String itemId, {required bool available});

  Future<void> moveItem(String itemId, int newSortOrder);

  /// Idempotent: seeds only when the menu is empty, so it can run on every boot.
  /// Returns the number of items written (0 when already seeded).
  Future<int> seedIfEmpty();

  /// Export helper for the backup screen (T4) and reports.
  Future<List<MenuItem>> allItems();
}
