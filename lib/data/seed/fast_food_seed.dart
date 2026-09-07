/// Demo menu for a North-East Indian fast-food counter (Task M2).
///
/// Realistic rupee prices so the totals, change maths and receipt widths in later
/// tests exercise the magnitudes a counter actually handles — and so a reviewer can
/// spot a wrong total by eye. Everything is `taxPercent: 5` (the common rate for an
/// eatery); where a shop would differ, the item comment says so rather than the
/// seed inventing a number.
///
/// These are `final`, not `const`: `Money` has a validating constructor (T1) so it
/// cannot be const, and refusing to weaken that invariant for a seed file is the
/// right trade.
library;

import '../../core/money/money.dart';
import '../models/menu.dart';
import '../models/stock.dart';

const String catBurgers = 'cat_burger';
const String catRolls = 'cat_roll';
const String catRice = 'cat_rice';
const String catSides = 'cat_side';
const String catDrinks = 'cat_drink';
const String catCombos = 'cat_combo';

const String grpSize = 'grp_size';
const String grpSpice = 'grp_spice';
const String grpSauce = 'grp_sauce';
const String grpSugar = 'grp_sugar';

/// Rupees -> paise, spelled out because a seed of raw `6000` is unreadable and a
/// seed of `60.0` doubles would violate the one rule the money layer rests on.
Money rs(int rupees) => Money(rupees * 100);

ModifierOption opt(String id, String groupId, String name, {int addRupees = 0, int order = 0}) =>
    ModifierOption(
      id: id,
      groupId: groupId,
      name: name,
      priceDelta: rs(addRupees),
      sortOrder: order,
    );

final List<MenuCategory> kSeedCategories = [
  MenuCategory(id: catBurgers, name: 'Burgers', sortOrder: 10, modifierGroupIds: const [grpSize]),
  MenuCategory(id: catRolls, name: 'Rolls & Wraps', sortOrder: 20, modifierGroupIds: const [grpSize, grpSpice]),
  MenuCategory(id: catRice, name: 'Rice & Noodles', sortOrder: 30, modifierGroupIds: const [grpSpice]),
  MenuCategory(id: catSides, name: 'Sides', sortOrder: 40, modifierGroupIds: const [grpSauce]),
  MenuCategory(id: catDrinks, name: 'Drinks', sortOrder: 50, modifierGroupIds: const [grpSugar]),
  MenuCategory(id: catCombos, name: 'Combo Meals', sortOrder: 60, modifierGroupIds: const [grpSize]),
];

final List<ModifierGroup> kSeedModifierGroups = [
  ModifierGroup(
    id: grpSize,
    name: 'Size',
    minSelect: 1,
    maxSelect: 1,
    required: true,
    options: [
      opt('opt_s', grpSize, 'Regular', order: 0),
      opt('opt_m', grpSize, 'Medium', addRupees: 15, order: 1),
      opt('opt_l', grpSize, 'Large', addRupees: 25, order: 2),
    ],
  ),
  ModifierGroup(
    id: grpSpice,
    name: 'Spice level',
    minSelect: 0,
    maxSelect: 1,
    options: [
      opt('opt_mild', grpSpice, 'Mild', order: 0),
      opt('opt_med', grpSpice, 'Medium', order: 1),
      opt('opt_hot', grpSpice, 'Naga hot', order: 2),
    ],
  ),
  ModifierGroup(
    id: grpSauce,
    name: 'Dip sauce',
    minSelect: 0,
    maxSelect: 2,
    options: [
      opt('opt_tom', grpSauce, 'Tomato ketchup', order: 0),
      opt('opt_may', grpSauce, 'Mayonnaise', order: 1),
      opt('opt_cheese', grpSauce, 'Cheese dip', addRupees: 10, order: 2),
    ],
  ),
  ModifierGroup(
    id: grpSugar,
    name: 'Sugar',
    minSelect: 1,
    maxSelect: 1,
    required: true,
    options: [
      opt('opt_no', grpSugar, 'No sugar', order: 0),
      opt('opt_half', grpSugar, 'Half', order: 1),
      opt('opt_full', grpSugar, 'Full', order: 2),
    ],
  ),
];

/// `stockItemId` is filled only for things a shop genuinely runs out of, so the
/// sold-out hook (M6 <-> I3) has a real driver instead of a synthetic one.
final List<MenuItem> kSeedItems = [
  MenuItem(
    id: 'itm_veg_burger',
    categoryId: catBurgers,
    name: 'Veg Burger',
    price: rs(60),
    kitchenLabel: 'VEG BURGER',
    prepSeconds: 240,
    barcode: '8901000000017',
    stockItemId: 'stk_bun',
    modifierGroupIds: const [grpSize],
    sortOrder: 1,
  ),
  MenuItem(
    id: 'itm_chicken_burger',
    categoryId: catBurgers,
    name: 'Chicken Burger',
    price: rs(80),
    kitchenLabel: 'CHK BURGER',
    prepSeconds: 300,
    stockItemId: 'stk_bun',
    modifierGroupIds: const [grpSize],
    sortOrder: 2,
  ),
  MenuItem(
    id: 'itm_double_patty',
    categoryId: catBurgers,
    name: 'Double Patty Burger',
    price: rs(120),
    kitchenLabel: 'DBL PATTY',
    prepSeconds: 360,
    stockItemId: 'stk_patty',
    modifierGroupIds: const [grpSize],
    sortOrder: 3,
  ),
  MenuItem(
    id: 'itm_chicken_roll',
    categoryId: catRolls,
    name: 'Chicken Roll',
    price: rs(70),
    kitchenLabel: 'CHK ROLL',
    prepSeconds: 210,
    stockItemId: 'stk_paratha',
    modifierGroupIds: const [grpSpice],
    sortOrder: 1,
  ),
  MenuItem(
    id: 'itm_egg_roll',
    categoryId: catRolls,
    name: 'Egg Roll',
    price: rs(50),
    kitchenLabel: 'EGG ROLL',
    prepSeconds: 180,
    modifierGroupIds: const [grpSpice],
    sortOrder: 2,
  ),
  MenuItem(
    id: 'itm_veg_roll',
    categoryId: catRolls,
    name: 'Veg Roll',
    price: rs(45),
    kitchenLabel: 'VEG ROLL',
    prepSeconds: 180,
    sortOrder: 3,
  ),
  MenuItem(
    id: 'itm_fried_rice',
    categoryId: catRice,
    name: 'Veg Fried Rice',
    price: rs(90),
    kitchenLabel: 'VEG FRIED RICE',
    prepSeconds: 420,
    stockItemId: 'stk_rice',
    modifierGroupIds: const [grpSpice],
    sortOrder: 1,
  ),
  MenuItem(
    id: 'itm_chicken_fried_rice',
    categoryId: catRice,
    name: 'Chicken Fried Rice',
    price: rs(110),
    kitchenLabel: 'CHK FRIED RICE',
    prepSeconds: 450,
    stockItemId: 'stk_rice',
    modifierGroupIds: const [grpSpice],
    sortOrder: 2,
  ),
  MenuItem(
    id: 'itm_egg_noodles',
    categoryId: catRice,
    name: 'Egg Hakka Noodles',
    price: rs(85),
    kitchenLabel: 'EGG NOODLES',
    prepSeconds: 400,
    modifierGroupIds: const [grpSpice],
    sortOrder: 3,
  ),
  MenuItem(
    id: 'itm_chicken_noodles',
    categoryId: catRice,
    name: 'Chicken Hakka Noodles',
    price: rs(100),
    kitchenLabel: 'CHK NOODLES',
    prepSeconds: 420,
    modifierGroupIds: const [grpSpice],
    sortOrder: 4,
  ),
  MenuItem(
    id: 'itm_momo',
    categoryId: catRice,
    name: 'Steamed Momo (8 pc)',
    price: rs(70),
    kitchenLabel: 'MOMO 8PC',
    prepSeconds: 600,
    sortOrder: 5,
  ),
  MenuItem(
    id: 'itm_french_fries',
    categoryId: catSides,
    name: 'French Fries',
    price: rs(40),
    kitchenLabel: 'FRIES',
    prepSeconds: 180,
    stockItemId: 'stk_potato',
    modifierGroupIds: const [grpSauce],
    sortOrder: 1,
  ),
  MenuItem(
    id: 'itm_chicken_strip',
    categoryId: catSides,
    name: 'Chicken Strips (4 pc)',
    price: rs(120),
    kitchenLabel: 'STRIPS 4',
    prepSeconds: 360,
    stockItemId: 'stk_strips',
    modifierGroupIds: const [grpSauce],
    sortOrder: 2,
  ),
  MenuItem(
    id: 'itm_pasta',
    categoryId: catSides,
    name: 'White Sauce Pasta',
    price: rs(95),
    kitchenLabel: 'PASTA',
    prepSeconds: 420,
    sortOrder: 3,
  ),
  MenuItem(
    id: 'itm_cold_coffee',
    categoryId: catDrinks,
    name: 'Cold Coffee',
    price: rs(60),
    kitchenLabel: 'COLD COFFEE',
    prepSeconds: 120,
    modifierGroupIds: const [grpSugar],
    sortOrder: 1,
  ),
  MenuItem(
    id: 'itm_lemon_tea',
    categoryId: catDrinks,
    name: 'Lemon Tea',
    price: rs(25),
    kitchenLabel: 'LEMON TEA',
    prepSeconds: 180,
    sortOrder: 2,
  ),
  MenuItem(
    id: 'itm_mineral_water',
    categoryId: catDrinks,
    name: 'Mineral Water 1L',
    price: rs(20),
    kitchenLabel: 'WATER 1L',
    prepSeconds: 5,
    sortOrder: 3,
  ),
  MenuItem(
    id: 'itm_soft_drink',
    categoryId: catDrinks,
    name: 'Soft Drink 250ml',
    price: rs(40),
    kitchenLabel: 'SOFT DRINK',
    prepSeconds: 10,
    sortOrder: 4,
  ),
  MenuItem(
    id: 'itm_combo_a',
    categoryId: catCombos,
    name: 'Combo A (Burger + Fries + Drink)',
    price: rs(130),
    kitchenLabel: 'COMBO A',
    prepSeconds: 360,
    sortOrder: 1,
  ),
  MenuItem(
    id: 'itm_family_box',
    categoryId: catCombos,
    name: 'Family Box (2 Burger + 2 Roll + Fries)',
    price: rs(280),
    kitchenLabel: 'FAMILY BOX',
    prepSeconds: 600,
    sortOrder: 2,
  ),
];

/// Opening stock so the counter can sell on day one (I1). Milli-units: 1000 = 1.
final List<StockItem> kSeedStock = [
  StockItem(id: 'stk_bun', name: 'Burger bun', onHandMilli: 120000, reorderMilli: 40000),
  StockItem(id: 'stk_patty', name: 'Veg patty', onHandMilli: 80000, reorderMilli: 30000),
  StockItem(id: 'stk_strips', name: 'Chicken strips', onHandMilli: 60000, reorderMilli: 20000),
  StockItem(id: 'stk_paratha', name: 'Paratha / roll sheet', onHandMilli: 90000, reorderMilli: 30000),
  StockItem(id: 'stk_rice', name: 'Boiled rice', unit: 'g', onHandMilli: 15000000, reorderMilli: 4000000),
  StockItem(id: 'stk_potato', name: 'Potato (fries)', unit: 'g', onHandMilli: 9000000, reorderMilli: 3000000),
];

/// Per-unit consumption, so a sale decrements the right amounts (I2).
final List<RecipeLine> kSeedRecipes = [
  RecipeLine(id: 'rcp1', itemId: 'itm_veg_burger', stockItemId: 'stk_bun', stockName: 'Burger bun', perUnitMilli: 1000),
  RecipeLine(id: 'rcp2', itemId: 'itm_veg_burger', stockItemId: 'stk_patty', stockName: 'Veg patty', perUnitMilli: 1000),
  RecipeLine(id: 'rcp3', itemId: 'itm_chicken_burger', stockItemId: 'stk_bun', stockName: 'Burger bun', perUnitMilli: 1000),
  RecipeLine(id: 'rcp4', itemId: 'itm_double_patty', stockItemId: 'stk_patty', stockName: 'Veg patty', perUnitMilli: 2000),
  RecipeLine(id: 'rcp5', itemId: 'itm_chicken_roll', stockItemId: 'stk_paratha', stockName: 'Paratha / roll sheet', perUnitMilli: 1000),
  RecipeLine(id: 'rcp6', itemId: 'itm_french_fries', stockItemId: 'stk_potato', stockName: 'Potato (fries)', perUnitMilli: 150000),
  RecipeLine(id: 'rcp7', itemId: 'itm_fried_rice', stockItemId: 'stk_rice', stockName: 'Boiled rice', perUnitMilli: 250000),
];

/// A quick-add shortcut row for the counter: the four things sold most, so a rush
/// does not need category hunting. Not a menu concept — a UI convenience (O3).
const List<String> kQuickItemIds = [
  'itm_veg_burger',
  'itm_chicken_roll',
  'itm_french_fries',
  'itm_cold_coffee',
];
