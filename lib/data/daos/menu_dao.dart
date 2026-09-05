/// Menu DAO — rows in, domain models out (Task T3).
///
/// Deliberately dumb (no availability rules, no price maths): those live in
/// `features/menu/domain` (M4) and `core/money`. The only judgement calls here
/// are *how* things are persisted — idempotent upserts so a seed or a restore
/// can run twice, and soft deletes so history survives a delisted item (M1).
part of '../../core/db/app_database.dart';

class MenuDao extends KazamaDao {
  Future<void> upsertCategory(MenuCategory c, {required DateTime at}) {
    return into(menuCategories).insertOnConflictUpdate(
      MenuCategoriesCompanion.insert(
        id: c.id,
        name: c.name,
        sortOrder: Value(c.sortOrder),
        isActive: Value(c.active),
        modifierGroupIds: Value(jsonEncode(c.modifierGroupIds)),
        updatedAt: Value(at),
      ),
    );
  }

  Future<void> upsertGroup(ModifierGroup g, {required DateTime at}) async {
    await into(modifierGroups).insertOnConflictUpdate(
      ModifierGroupsCompanion.insert(
        id: g.id,
        name: g.name,
        isRequired: Value(g.required),
        minSelect: Value(g.minSelect),
        maxSelect: Value(g.maxSelect),
        sortOrder: Value(0),
        updatedAt: at,
      ),
    );
    // Options are replaced wholesale: an editor saves the whole group at once
    // (M5), so diffing individual option rows would buy nothing and could
    // leave orphans when an option is removed in the UI.
    await (delete(modifierOptions)..where((t) => t.groupId.equalsValue(g.id))).go();
    for (var i = 0; i < g.options.length; i++) {
      final o = g.options[i];
      await into(modifierOptions).insert(
        ModifierOptionsCompanion.insert(
          id: o.id,
          groupId: g.id,
          name: o.name,
          priceDeltaPaise: Value(o.priceDelta.paise),
          sortOrder: Value(i),
          isActive: Value(o.active),
        ),
      );
    }
  }

  /// Upsert that PRESERVES the sold-out flag (M6). `insertOnConflictUpdate`
  /// would write every field and silently put a sold-out item back on sale the
  /// next time the seed or a backup restore runs, so the one owned-elsewhere
  /// column is read out of the existing row first. Both reads and writes happen
  /// inside one transaction, so no interleaving can lose the flag.
  Future<void> upsertItem(MenuItem item, {required DateTime at}) async {
    final existing = await (select(menuItems)..where((t) => t.id.equalsValue(item.id)))
        .getSingleOrNull();
    await into(menuItems).insert(
      MenuItemsCompanion.insert(
        id: item.id,
        categoryId: item.categoryId,
        name: item.name,
        pricePaise: item.price.paise,
        taxPercent: Value(item.taxPercent),
        kitchenLabel: Value(item.kitchenLabel),
        prepSeconds: Value(item.prepSeconds),
        isPrintable: Value(item.printable),
        barcode: Value(item.barcode),
        stockItemId: Value(item.stockItemId),
        modifierGroupIds: Value(jsonEncode(item.modifierGroupIds)),
        isActive: Value(item.active),
        isAvailable: Value(existing?.isAvailable ?? item.available),
        sortOrder: Value(item.sortOrder),
        updatedAt: at,
      ),
    );
  }

  /// One-shot read for editors and tests. Prefer `watchItems()` in the UI: a
  /// `Future` list is how a screen ends up showing a stale menu after a stock
  /// change, and the whole reason for drift here was the stream (SKILLS.md §C3).
  Future<MenuItem?> findItem(String itemId) async {
    final row = await (select(menuItems)..where((t) => t.id.equalsValue(itemId))).getSingleOrNull();
    return row == null ? null : _itemFromRow(row);
  }

  /// Soft delete (M1): the row stays so old bills still resolve their item.
  Future<void> deactivateItem(String itemId, {required DateTime at}) =>
      (update(menuItems)..where((t) => t.id.equalsValue(itemId))).write(
        MenuItemsCompanion(isActive: const Value(false), updatedAt: Value(at)),
      );

  Future<void> setItemAvailability(String itemId, {required bool available, required DateTime at}) =>
      (update(menuItems)..where((t) => t.id.equalsValue(itemId))).write(
        MenuItemsCompanion(isAvailable: Value(available), updatedAt: Value(at)),
      );

  // ----------------------------------------------------------------- reads --

  Stream<List<MenuCategory>> watchCategories() =>
      select(menuCategories).watch().map(
        (rows) => [
          for (final r in rows)
            MenuCategory(
              id: r.id,
              name: r.name,
              sortOrder: r.sortOrder,
              active: r.isActive,
              modifierGroupIds: _stringList(r.modifierGroupIds),
            ),
        ]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)),
      );

  /// Only orderable items by default (M3, O3 both want exactly this filter);
  /// the menu editor passes `includeInactive: true`.
  Stream<List<MenuItem>> watchItems({String? categoryId, bool includeInactive = false}) {
    final q = select(menuItems);
    if (categoryId != null) q.where((t) => t.categoryId.equalsValue(categoryId));
    if (!includeInactive) q.where((t) => t.isActive.equals(true));
    return q.watch().map((rows) => [for (final r in rows) _itemFromRow(r)]);
  }

  Future<List<ModifierGroup>> groupsFor(Set<String> groupIds) async {
    if (groupIds.isEmpty) return const [];
    final rows = await (select(modifierGroups)..where((t) => t.id.isIn(groupIds))).get();
    final out = <ModifierGroup>[];
    for (final r in rows) {
      final options = await (select(modifierOptions)
            ..where((t) => t.groupId.equalsValue(r.id))
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .get();
      out.add(
        ModifierGroup(
          id: r.id,
          name: r.name,
          required: r.isRequired,
          minSelect: r.minSelect,
          maxSelect: r.maxSelect,
          options: [
            for (final o in options)
              ModifierOption(
                id: o.id,
                groupId: o.groupId,
                name: o.name,
                priceDelta: Money(o.priceDeltaPaise),
                sortOrder: o.sortOrder,
                active: o.isActive,
              ),
          ],
        ),
      );
    }
    // Order by the caller's id list so a category's group sequence is preserved.
    out.sort((a, b) => groupIds.toList().indexOf(a.id).compareTo(groupIds.toList().indexOf(b.id)));
    return out;
  }

  static MenuItem _itemFromRow(MenuItemRow r) => MenuItem(
    id: r.id,
    categoryId: r.categoryId,
    name: r.name,
    price: Money(r.pricePaise),
    taxPercent: r.taxPercent,
    kitchenLabel: r.kitchenLabel,
    prepSeconds: r.prepSeconds,
    printable: r.isPrintable,
    barcode: r.barcode,
    stockItemId: r.stockItemId,
    modifierGroupIds: _stringList(r.modifierGroupIds),
    active: r.isActive,
    available: r.isAvailable,
    sortOrder: r.sortOrder,
  );

  static List<String> _stringList(String json) => [
    for (final e in (jsonDecode(json) as List<Object?>)) e! as String,
  ];
}
