/// The *minimum surface* a line-building call needs (Task O2).
///
/// Why these live in `data/models` rather than next to `OrderRepository`'s other
/// declarations: the concrete `MenuItem`/`ModifierOption` must implement them, and
/// a model importing a repository contract would make `data/models` depend on
/// `data/repositories` — a cycle. Here both sides point the same way: the model
/// implements, the contract requires, and neither knows the other exists.
///
/// The interfaces are deliberately tiny. They are the reason the order path can be
/// unit-tested with a hand-written fake item (no category, no stock link, no
/// modifier groups) instead of a seeded menu — which is what makes a fast-food line
/// testable in one file.
library;

import '../../core/money/money.dart';

/// What `addMenuItem` reads off a menu item, and nothing else.
abstract interface class MenuItemLike {
  String get id;
  String get name;

  /// Base, tax-**inclusive** unit price as sold.
  Money get price;
  int get taxPercent;
  String? get kitchenLabel;
}

/// What a line snapshot needs from a modifier — the label and its price delta, not
/// the group's min/max rules (those are a UI concern at pick time).
abstract interface class ModifierOptionLike {
  String get id;
  String get groupId;
  String get name;
  Money get priceDelta;
}
