/// Menu read/write models (Task T2). Pure Dart — drift tables come in T3 and map
/// onto these; no feature may read a drift row directly (R1).
library;

import '../../core/money/money.dart';
import 'enums.dart';

final class ModifierOption {
  const ModifierOption({
    required this.id,
    required this.groupId,
    required this.name,
    required this.priceDelta,
    this.sortOrder = 0,
    this.active = true,
  });

  final String id;
  final String groupId;
  final String name;

  /// Added per *unit of the parent line*, and it inherits the parent item's
  /// tax class — an extra cheese does not become a different GST slab.
  final Money priceDelta;
  final int sortOrder;
  final bool active;

  /// `active` alone follows copyWith convention (null = keep). Pass
  /// `activeOverride` when you genuinely need to SET it to false — a plain
  /// `active: false` is indistinguishable from "unset" in a nullable param, and
  /// silently keeping `true` there is exactly the bug that hides a delisted item.
  ModifierOption copyWith({
    String? name,
    Money? priceDelta,
    int? sortOrder,
    bool? activeOverride,
  }) => ModifierOption(
    id: id,
    groupId: groupId,
    name: name ?? this.name,
    priceDelta: priceDelta ?? this.priceDelta,
    sortOrder: sortOrder ?? this.sortOrder,
    active: activeOverride ?? active,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'groupId': groupId,
    'name': name,
    'priceDeltaPaise': priceDelta.toJson(),
    'sortOrder': sortOrder,
    'active': active,
  };

  factory ModifierOption.fromJson(Map<String, Object?> j) => ModifierOption(
    id: j['id']! as String,
    groupId: j['groupId']! as String,
    name: j['name']! as String,
    priceDelta: Money.fromJson(j['priceDeltaPaise']),
    sortOrder: (j['sortOrder'] as int?) ?? 0,
    active: (j['active'] as bool?) ?? true,
  );

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is ModifierOption &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.groupId == groupId &&
      other.name == name &&
      other.priceDelta == priceDelta &&
      other.sortOrder == sortOrder &&
      other.active == active;

  @override
  int get hashCode => Object.hashAll([
      id.hashCode,
      groupId.hashCode,
      name.hashCode,
      priceDelta.hashCode,
      sortOrder.hashCode,
      active.hashCode,
    ]);
}

/// A pick-list attached to a category (not an item) — "cheese +₹20" must be
/// offered on burgers *and* fries without duplicating the option rows.
final class ModifierGroup {
  const ModifierGroup({
    required this.id,
    required this.name,
    this.minSelect = 0,
    this.maxSelect = 1,
    this.required = false,
    this.options = const <ModifierOption>[],
  });

  final String id;
  final String name;
  final int minSelect;
  final int maxSelect;
  final bool required;
  final List<ModifierOption> options;

  bool get isSingleChoice => maxSelect <= 1;

  /// Validated on save (M5) and again when a ticket line is built (O3): a group
  /// that says "required, exactly 2" cannot be skipped at the counter.
  bool isValidSelectionCount(int count) =>
      (!required || count >= minSelect) &&
      count >= minSelect &&
      (maxSelect <= 0 || count <= maxSelect);

  ModifierGroup copyWith({
    String? name,
    int? minSelect,
    int? maxSelect,
    bool? required,
    List<ModifierOption>? options,
  }) => ModifierGroup(
    id: id,
    name: name ?? this.name,
    minSelect: minSelect ?? this.minSelect,
    maxSelect: maxSelect ?? this.maxSelect,
    required: required ?? this.required,
    options: options ?? this.options,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'minSelect': minSelect,
    'maxSelect': maxSelect,
    'required': required,
    'options': options.map((o) => o.toJson()).toList(),
  };

  factory ModifierGroup.fromJson(Map<String, Object?> j) => ModifierGroup(
    id: j['id']! as String,
    name: j['name']! as String,
    minSelect: (j['minSelect'] as int?) ?? 0,
    maxSelect: (j['maxSelect'] as int?) ?? 1,
    required: (j['required'] as bool?) ?? false,
    options: [
      for (final raw in (j['options'] as List<Object?>? ?? const <Object?>[]))
        ModifierOption.fromJson(raw! as Map<String, Object?>),
    ],
  );

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is ModifierGroup &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.name == name &&
      other.minSelect == minSelect &&
      other.maxSelect == maxSelect &&
      other.required == required &&
      deepEquals(other.options, options);

  @override
  int get hashCode => Object.hashAll([
      id.hashCode,
      name.hashCode,
      minSelect.hashCode,
      maxSelect.hashCode,
      required.hashCode,
      deepHash(options),
    ]);
}

final class MenuItem {
  const MenuItem({
    required this.id,
    required this.categoryId,
    required this.name,
    required this.price,
    this.taxPercent = 5,
    this.kitchenLabel,
    this.prepSeconds = 180,
    this.printable = true,
    this.barcode,
    this.stockItemId,
    this.modifierGroupIds = const <String>[],
    this.active = true,
    this.available = true,
    this.sortOrder = 0,
  });

  final String id;
  final String categoryId;
  final String name;

  /// Base, tax-**inclusive** price (the way an Indian fast-food menu is written).
  /// `taxPercent` is used only to split it for the receipt/report.
  final Money price;
  final int taxPercent;

  /// What the kitchen sees, which is often shorter than the menu name
  /// ("Veg Burger Special" on the menu, "VEG BURGER" on the ticket).
  final String? kitchenLabel;
  final int prepSeconds;
  final bool printable;

  /// Present from day 1 even though scanning is out of v1 (Q6 assumption) —
  /// a column is free now and a migration later.
  final String? barcode;

  /// FK into inventory (phase I). Null = item not stock-tracked (e.g. a combo).
  final String? stockItemId;
  final List<String> modifierGroupIds;
  final bool active;

  /// Sold-out toggle (M6). Separate from `active`: deactivating hides an item
  /// from the menu, sold-out keeps it visible but greyed and un-addable.
  final bool available;
  final int sortOrder;

  /// Menu name for the counter tiles.
  String get displayName => name;
  /// What the KDS prints — falls back to the menu name when unset (K3).
  String get kitchenDisplay =>
      (kitchenLabel?.isNotEmpty ?? false) ? kitchenLabel! : name;
  bool get canBeOrdered => active && available;

  /// Price after selected modifier upcharges, per unit.
  Money unitPriceWith(List<ModifierOption> selected) =>
      selected.isEmpty ? price : price + Money.sum(selected.map((o) => o.priceDelta));

  MenuItem copyWith({
    String? categoryId,
    String? name,
    Money? price,
    int? taxPercent,
    String? kitchenLabel,
    int? prepSeconds,
    bool? printable,
    String? barcode,
    String? stockItemId,
    List<String>? modifierGroupIds,
    bool? active,
    bool? available,
    int? sortOrder,
  }) => MenuItem(
    id: id,
    categoryId: categoryId ?? this.categoryId,
    name: name ?? this.name,
    price: price ?? this.price,
    taxPercent: taxPercent ?? this.taxPercent,
    kitchenLabel: kitchenLabel ?? this.kitchenLabel,
    prepSeconds: prepSeconds ?? this.prepSeconds,
    printable: printable ?? this.printable,
    barcode: barcode ?? this.barcode,
    stockItemId: stockItemId ?? this.stockItemId,
    modifierGroupIds: modifierGroupIds ?? this.modifierGroupIds,
    active: active ?? this.active,
    available: available ?? this.available,
    sortOrder: sortOrder ?? this.sortOrder,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'categoryId': categoryId,
    'name': name,
    'pricePaise': price.toJson(),
    'taxPercent': taxPercent,
    'kitchenLabel': kitchenLabel,
    'prepSeconds': prepSeconds,
    'printable': printable,
    'barcode': barcode,
    'stockItemId': stockItemId,
    'modifierGroupIds': modifierGroupIds,
    'active': active,
    'available': available,
    'sortOrder': sortOrder,
  };

  factory MenuItem.fromJson(Map<String, Object?> j) => MenuItem(
    id: j['id']! as String,
    categoryId: j['categoryId']! as String,
    name: j['name']! as String,
    price: Money.fromJson(j['pricePaise']),
    taxPercent: (j['taxPercent'] as int?) ?? 5,
    kitchenLabel: j['kitchenLabel'] as String?,
    prepSeconds: (j['prepSeconds'] as int?) ?? 180,
    printable: (j['printable'] as bool?) ?? true,
    barcode: j['barcode'] as String?,
    stockItemId: j['stockItemId'] as String?,
    modifierGroupIds: [
      for (final raw in (j['modifierGroupIds'] as List<Object?>? ?? const <Object?>[]))
        raw! as String,
    ],
    active: (j['active'] as bool?) ?? true,
    available: (j['available'] as bool?) ?? true,
    sortOrder: (j['sortOrder'] as int?) ?? 0,
  );

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is MenuItem &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.categoryId == categoryId &&
      other.name == name &&
      other.price == price &&
      other.taxPercent == taxPercent &&
      other.kitchenLabel == kitchenLabel &&
      other.prepSeconds == prepSeconds &&
      other.printable == printable &&
      other.barcode == barcode &&
      other.stockItemId == stockItemId &&
      deepEquals(other.modifierGroupIds, modifierGroupIds) &&
      other.active == active &&
      other.available == available &&
      other.sortOrder == sortOrder;

  @override
  int get hashCode => Object.hashAll([
      id.hashCode,
      categoryId.hashCode,
      name.hashCode,
      price.hashCode,
      taxPercent.hashCode,
      kitchenLabel.hashCode,
      prepSeconds.hashCode,
      printable.hashCode,
      barcode.hashCode,
      stockItemId.hashCode,
      deepHash(modifierGroupIds),
      active.hashCode,
      available.hashCode,
      sortOrder.hashCode,
    ]);
}

final class MenuCategory {
  const MenuCategory({
    required this.id,
    required this.name,
    this.sortOrder = 0,
    this.active = true,
    this.modifierGroupIds = const <String>[],
  });

  final String id;
  final String name;
  final int sortOrder;
  final bool active;
  final List<String> modifierGroupIds;

  MenuCategory copyWith({
    String? name,
    int? sortOrder,
    bool? active,
    List<String>? modifierGroupIds,
  }) => MenuCategory(
    id: id,
    name: name ?? this.name,
    sortOrder: sortOrder ?? this.sortOrder,
    active: active ?? this.active,
    modifierGroupIds: modifierGroupIds ?? this.modifierGroupIds,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'sortOrder': sortOrder,
    'active': active,
    'modifierGroupIds': modifierGroupIds,
  };

  factory MenuCategory.fromJson(Map<String, Object?> j) => MenuCategory(
    id: j['id']! as String,
    name: j['name']! as String,
    sortOrder: (j['sortOrder'] as int?) ?? 0,
    active: (j['active'] as bool?) ?? true,
    modifierGroupIds: [
      for (final raw in (j['modifierGroupIds'] as List<Object?>? ?? const <Object?>[]))
        raw! as String,
    ],
  );

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is MenuCategory &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.name == name &&
      other.sortOrder == sortOrder &&
      other.active == active &&
      deepEquals(other.modifierGroupIds, modifierGroupIds);

  @override
  int get hashCode => Object.hashAll([
      id.hashCode,
      name.hashCode,
      sortOrder.hashCode,
      active.hashCode,
      deepHash(modifierGroupIds),
    ]);
}
