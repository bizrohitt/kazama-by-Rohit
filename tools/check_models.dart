// Task T2 verification — run with ZERO packages, ZERO pub get:
//
//   dart run tools/check_models.dart
//
// Expected: every line PASS, then the summary, exit code 0.
// These are the guarantees every later module silently relies on: T3 (drift)
// maps onto these codecs, O1-O6 mutate OrderTicket, Y1-Y6 use Payment/BillTotals,
// R1-R4 read report.dart. A wrong model here is a wrong database forever.
//
// All expected values were hand-computed. Worked bill: 3 lines @18% GST
// (inclusive), flat discount 440p.
//   ₹100.00 -> tax 1525p  base 8475p
//   ₹234.56 -> tax 3578p  base 19878p
//   ₹67.89  -> tax 1035p  base 5754p
//   base 34107p  discount 440p  per-line tax 5879p  total 45000p (₹450.00)
import 'dart:convert';

import '../lib/core/money/money.dart';
import '../lib/core/money/money_delta.dart';
import '../lib/data/models/enums.dart';
import '../lib/data/models/menu.dart';
import '../lib/data/models/mutation.dart';
import '../lib/data/models/order.dart';
import '../lib/data/models/payment.dart';
import '../lib/data/models/report.dart';
import '../lib/data/models/staff.dart';

int _passed = 0;
int _roundTrips = 0;
final List<String> _failures = <String>[];

final DateTime at = DateTime.utc(2026, 9, 3, 20, 30);
final DateTime later = DateTime.utc(2026, 9, 3, 21, 0);

void main() {
  suite('T2.1 — menu models');
  final cheese = ModifierOption(
    id: 'mo1',
    groupId: 'mg1',
    name: 'Extra cheese',
    priceDelta: Money.rupees(20),
  );
  final veg = MenuItem(
    id: 'i1',
    categoryId: 'c1',
    name: 'Veg Burger',
    price: Money(10000),
    taxPercent: 18,
    kitchenLabel: 'VEG BURGER',
    modifierGroupIds: const ['mg1'],
  );
  eq('1a menu price stays exact paise', veg.price.paise, 10000);
  eq('1b upcharge applies per unit sold', veg.unitPriceWith([cheese]).paise, 12000);
  eq('1c no upcharges keeps the base price', veg.unitPriceWith(const []).paise, 10000);
  eq('1d KDS shows the kitchen label', veg.kitchenDisplay, 'VEG BURGER');
  eq('1e counter shows the menu name', veg.displayName, 'Veg Burger');
  eq('1f sold-out item cannot be ordered', veg.copyWith(available: false).canBeOrdered, false);
  eq('1g deactivated item cannot be ordered', veg.copyWith(active: false).canBeOrdered, false);
  final size = ModifierGroup(
    id: 'mg2',
    name: 'Size',
    minSelect: 1,
    maxSelect: 1,
    required: true,
  );
  eq('1h single-choice group rejects two picks', size.isValidSelectionCount(2), false);
  eq('1i required group accepts one pick', size.isValidSelectionCount(1), true);
  eq('1j required group rejects none', size.isValidSelectionCount(0), false);

  suite('T2.2 — ticket lines: snapshot, tax, partial cancellation');
  final l1 = _line('l1', 10000, 18);
  eq('2a line total (qty 1)', l1.lineTotal.paise, 10000);
  eq('2b line tax/base split @18%', '${l1.tax.paise}/${l1.base.paise}', '1525/8475');
  eq('2c qty 3 scales total', l1.copyWith(quantity: 3).lineTotal.paise, 30000);
  eq('2d qty 3 scales tax too', l1.copyWith(quantity: 3).tax.paise, 4575);
  eq('2e name is snapshotted, not joined', l1.nameSnapshot, 'Veg Burger');
  final fries = TicketLine(
    id: 'l2',
    itemId: 'i2',
    nameSnapshot: 'Fries',
    unitPrice: Money(1000),
    taxPercent: 5,
    quantity: 3,
    cancelledQuantity: 2,
  );
  eq('2f partial cancel keeps live qty', fries.liveQuantity, 1);
  eq('2g partial cancel bills only live qty', fries.lineTotal.paise, 1000);
  eq('2h untouched line is not cancelled', l1.isFullyCancelled, false);
  eq('2i pending line is editable', l1.status.isCancellable, true);

  suite('T2.3 — BillTotals: discount allocation, per-line tax, ROUNDING');
  final t = _ticket(discount: const OrderDiscount(DiscountKind.absolute, 440));
  final tt = t.totals;
  eq('3a lineBase before discount', tt.lineBase.paise, 34107);
  eq('3b discount honoured', tt.discount.paise, 440);
  eq('3c tax recomputed on discounted bases', tt.tax.paise, 5879);
  eq('3d total foots to a whole rupee', tt.total.paise, 45000);
  eq('3e net + tax == total exactly (receipt foots)',
      tt.netBeforeTax.paise + tt.tax.paise, tt.total.paise);
  eq('3f gross (reports) ignores the discount', tt.grossBeforeDiscount.paise, 34107);
  eq('3g rounding zero on this bill', tt.rounding.paise, 0);
  final odd = _ticket([_line('l9', 1001, 0)]);
  eq('3h rounding is SIGNED: ₹10.01 total -> ₹10.00', odd.totals.total.paise, 1000);
  eq('3i and prints as a negative delta', odd.totals.rounding.toString(), '-₹0.01');

  suite('T2.4 — discounts');
  eq('4a 10% of ₹400.00', const OrderDiscount(DiscountKind.percent, 10).amountFor(Money(40000)).paise, 4000);
  eq('4b flat ₹5 capped to the bill, never negative',
      const OrderDiscount(DiscountKind.absolute, 500).amountFor(Money(300)).paise, 300);
  eq('4c no discount', OrderDiscount.none.amountFor(Money(5000)).paise, 0);
  eq('4d none is detected as none', OrderDiscount.none.isNone, true);

  suite('T2.5 — status predicates (the two sections stay apart)');
  eq('5a OPEN is not on the KDS yet', OrderStatus.open.appearsOnKds, false);
  eq('5b IN_KITCHEN is on the KDS', OrderStatus.inKitchen.appearsOnKds, true);
  eq('5c SERVED is not settled but is in the due list',
      OrderStatus.served.appearsInDueList && !OrderStatus.served.isSettled, true);
  eq('5d PAID and VOIDED are terminal',
      OrderStatus.paid.isSettled && OrderStatus.voided.isSettled, true);
  eq('5e dine-in pays after eating', OrderType.dineIn.isPayAfterEating, true);
  eq('5f takeaway pays upfront', OrderType.takeaway.isPayUpfront, true);
  eq('5g a READY ticket no longer accepts items', OrderStatus.ready.allowsAddingItems, false);
  eq('5h adding an item to a READY ticket throws', _addAfterServedThrows(), true);
  eq('5i unknown status name is fatal, not defaulted', _unknownStatusThrows(), true);
  eq('5j unknown order type falls back to takeaway', OrderType.fromName('banquet'), OrderType.takeaway);

  suite('T2.6 — payments: split ledger, change, invariants');
  final cash500 = _pay('p1', 5000, PaymentMode.cash, tendered: 6000, change: 1000);
  final upi400 = _pay('p2', 4000, PaymentMode.upi, reference: 'GPay 88213');
  cash500.validateShape();
  upi400.validateShape();
  eq('6a valid rows pass validateShape', true, true);
  final summary = PaymentSummary.of([cash500, upi400]);
  eq('6b ledger total', summary.total.paise, 9000);
  eq('6c modes stay separate', '${summary.byMode[PaymentMode.cash]!.paise}/${summary.byMode[PaymentMode.upi]!.paise}', '5000/4000');
  eq('6d insertion order preserved for the receipt', summary.modesUsed.join(','), 'PaymentMode.cash,PaymentMode.upi');
  eq('6e change is stored, not recomputed at print time', cash500.changeOrZero.paise, 1000);
  eq('6f UPI row has no change', upi400.changeOrZero.paise, 0);
  eq('6g only cash touches the drawer',
      PaymentMode.cash.affectsCashDrawer && !PaymentMode.upi.affectsCashDrawer, true);
  eq('6h credit creates a due, UPI does not',
      PaymentMode.credit.createsADue && !PaymentMode.upi.createsADue, true);
  eq('6i UPI/CARD ask for a reference', PaymentMode.upi.wantsReference && !PaymentMode.cash.wantsReference, true);
  throws('6j zero-amount row rejected', () => _pay('p4', 0, PaymentMode.cash).validateShape());
  throws('6k tendered < amount rejected', () => _pay('p5', 5000, PaymentMode.cash, tendered: 4000).validateShape());
  throws('6l non-cash cannot carry tendered', () => _pay('p6', 100, PaymentMode.upi, tendered: 100).validateShape());
  final paid450 = _ticket().withPaymentApplied(Money(45000), at: later);
  eq('6m settling moves the ticket to PAID', paid450.status == OrderStatus.paid, true);
  eq('6n due cleared', paid450.due.paise, 0);
  eq('6o closedAt stamped on settle', paid450.closedAt == later, true);
  throws('6p overpayment throws, never clamps', () => _ticket().withPaymentApplied(Money(50000), at: later));
  final part = _ticket().withPaymentApplied(Money(15000), at: later);
  eq('6q partial payment -> PARTIALLY_PAID', part.status == OrderStatus.partiallyPaid, true);
  eq('6r remaining due', part.due.paise, 30000);
  eq('6s unpaid ticket is in the due list', _ticket().appearsInDueList, true);
  eq('6t settled ticket is not in the due list', paid450.appearsInDueList, false);
  eq('6u held-ticket row label', part.summaryLabel, 'T3 · 3 items · ₹450.00');
  throws('6v stale paid cache is caught', () => assertPaidConsistency(part, [upi400]));
  eq('6w consistent ledger passes the assert', _assertsOk(part, [_pay('p7', 15000, PaymentMode.cash, tendered: 15000)]), true);

  suite('T2.7 — fire / ready / serve / void rules');
  final fired = t.fired(at: at);
  eq('7a fire marks every pending line FIRED', fired.lines.every((l) => l.status == LineStatus.fired), true);
  eq('7b fire moves the ticket to IN_KITCHEN', fired.status == OrderStatus.inKitchen, true);
  eq('7c firedAt stamped once', fired.firedAt == at, true);
  throws('7d re-firing with nothing pending throws', () => fired.fired(at: later));
  eq('7e ticket stays IN_KITCHEN until all lines are ready',
      fired.lineReady('l1').maybeReady(at: later).status == OrderStatus.inKitchen, true);
  final allReady = fired.lineReady('l1').lineReady('l2').lineReady('l3').maybeReady(at: later);
  eq('7f last line ready flips the ticket to READY', allReady.status, OrderStatus.ready);
  eq('7g serving marks ready lines SERVED',
      allReady.served(at: later).lines.every((l) => l.status == LineStatus.served), true);
  eq('7h serving moves the ticket to SERVED', allReady.served(at: later).status, OrderStatus.served);
  final cancelled = _ticket().cancelledLine('l1');
  eq('7i voiding a line zeroes its live qty', cancelled.lines.firstWhere((l) => l.id == 'l1').liveQuantity, 0);
  eq('7j cancelled line drops out of the bill', cancelled.totals.total.paise, 38000);
  eq('7k ticket line count excludes cancelled', cancelled.lineCount, 2);
  throws('7l voiding a paid ticket throws',
      () => paid450.voided(reason: 'guest left', at: later));
  throws('7m void without a reason throws', () => _ticket().voided(reason: '   ', at: later));
  eq('7n void with a reason sets VOIDED', _ticket().voided(reason: 'wrong order', at: later).status,
      OrderStatus.voided);

  suite('T2.8 — MoneyDelta: the signed quantities Money cannot hold');
  eq('8a delta applied upward', const MoneyDelta(100).applyTo(Money(100)).paise, 200);
  eq('8b delta applied downward', const MoneyDelta(-1).applyTo(Money(100)).paise, 99);
  eq('8c underflow throws instead of clamping', _underflowThrows(), true);
  eq('8d deltas accumulate', MoneyDelta.sum(const [MoneyDelta(10), MoneyDelta(-4)]).paise, 6);
  eq('8e toString carries the sign', '${const MoneyDelta(100)} ${const MoneyDelta(-1)} ${MoneyDelta.zero}',
      '+₹1.00 -₹0.01 ₹0.00');
  eq('8f Money extension: signed rounding', Money(1001).roundingSignedPaise, -1);
  eq('8g Money extension: up to 99p', Money(1001).roundingDelta.paise, 99);
  eq('8h 1049p rounds DOWN to 1000p', Money(1049).roundingDelta.paise, -49);

  suite('T2.9 — staff, shifts, receipts');
  final zaid = StaffUser(
    id: 'u1',
    name: 'Zaid',
    role: UserRole.cashier,
    pinHash: 'x' * 64,
    createdAt: at,
  );
  eq('9a cashier can bill but not edit the menu', zaid.canBill && !zaid.canEditMenu, true);
  eq('9b cashier cannot void', zaid.canVoid, false);
  eq('9c kitchen role cannot bill but sees the KDS',
      !UserRole.kitchen.canBill && UserRole.kitchen.canViewKds, true);
  eq('9d cashier does not own the KDS tab', zaid.canViewKds, false);
  eq('9e manager can do everything',
      UserRole.manager.canBill && UserRole.manager.canEditMenu && UserRole.manager.canSeeReports && UserRole.manager.canVoid,
      true);
  eq('9f fresh user is not locked', zaid.isLocked, false);
  eq('9g lockout is time-based',
      zaid.copyWith(lockedUntil: later.add(const Duration(minutes: 1))).isLocked, true);
  final shift = Shift(
    id: 's1',
    userId: 'u1',
    openingFloat: Money.rupees(500),
    openedAt: at,
  );
  eq('9h expected cash = float + cash rows only', shift.expectedCash([cash500, upi400]).paise, 55000);
  eq('9i short count is negative', shift.variance([cash500], Money.rupees(546)).paise, -400);
  eq('9j over count is positive', shift.variance([cash500], Money.rupees(552)).paise, 200);
  eq('9k shift stays open until closedAt', shift.isOpen, true);
  const rec = ReceiptRecord(
    id: 'r1',
    orderId: 'o1',
    kind: ReceiptKind.copy,
    transport: 'fake',
    delivered: true,
    at: at,
  );
  eq('9l a reprint is flagged COPY', rec.isCopy, true);

  suite('T2.10 — outbox mutation row');
  var mut = Mutation(
    id: 'm1',
    entity: 'order',
    entityId: 'o1',
    op: MutationOp.insert,
    payload: const {'id': 'o1', 'totalPaise': 45000},
    idempotencyKey: 'k1',
    queuedAt: at,
  );
  eq('10a fresh row is pending and retryable', mut.shouldRetry, true);
  for (var i = 0; i < Mutation.maxAttempts; i++) {
    mut = mut.markFailed('timeout');
  }
  eq('10b failures are counted', mut.attempts, 10);
  eq('10c 10 failures -> stuck, retried no more',
      mut.status == SyncStatus.stuck && !mut.shouldRetry, true);
  eq('10d op uses the wire vocabulary', MutationOp.fromWire('INSERT'), MutationOp.insert);
  eq('10e payload survives the TEXT column', Mutation.decodePayload(mut.encodePayload())['id'], 'o1');
  eq('10f idempotency key is carried for re-send dedupe', mut.idempotencyKey, 'k1');
  throws('10g unknown op wire throws', () => MutationOp.fromWire('UPSERT'));

  suite('T2.11 — report read-models');
  final totals = DailyTotals(
    day: DateTime.utc(2026, 9, 3),
    bills: 4,
    covers: 12,
    gross: Money.rupees(1000),
    discount: Money.rupees(40),
    tax: Money.rupees(120),
    rounding: const MoneyDelta(-3),
    netSales: Money.rupees(960),
    due: Money.rupees(300),
  );
  eq('11a average bill uses integer maths', totals.averageBill.paise, 24000);
  eq('11b zero bills -> zero average',
      DailyTotals(day: DateTime.utc(2026, 9, 4), gross: Money.zero, netSales: Money.zero, tax: Money.zero, due: Money.zero, rounding: MoneyDelta.zero, discount: Money.zero).averageBill.paise,
      0);
  eq('11c due is surfaced for the owner', totals.hasDue, true);
  eq('11d charged = net + tax', totals.charged.paise, 108000);
  eq('11e hour bucket / bestseller rows keep their keys',
      const HourBucket(hour: 20, revenue: Money(0), bills: 3).hour, 20);
  eq('11f aging due is flagged after 30 days',
      DueParty(party: 'Sharma ji', outstanding: Money.rupees(450), ticketCount: 3, oldestAt: DateTime.utc(2020)).isAging,
      true);

  suite('T2.12 — JSON round-trip per model (the codec gate)');
  roundTrip('12a ModifierOption', cheese, ModifierOption.fromJson, (m) => m.toJson());
  roundTrip('12b ModifierGroup', size.copyWith(options: [cheese]), ModifierGroup.fromJson, (m) => m.toJson());
  roundTrip('12c MenuCategory',
      MenuCategory(id: 'c1', name: 'Burgers', sortOrder: 2, modifierGroupIds: const ['mg1']),
      MenuCategory.fromJson, (m) => m.toJson());
  roundTrip('12d MenuItem', veg.copyWith(barcode: '8901234567890'), MenuItem.fromJson, (m) => m.toJson());
  roundTrip('12e TicketLine', l1.copyWith(modifiers: [cheese], note: 'no onion', noteSet: true),
      TicketLine.fromJson, (m) => m.toJson());
  roundTrip('12f OrderDiscount', const OrderDiscount(DiscountKind.percent, 10),
      OrderDiscount.fromJson, (m) => m.toJson());
  roundTrip('12g OrderTicket', _ticket(billNo: 41, table: 'T3').withLine(l1.copyWith(id: 'l9')),
      OrderTicket.fromJson, (m) => m.toJson());
  roundTrip('12h Payment', cash500, Payment.fromJson, (m) => m.toJson());
  roundTrip('12i CreditEntry',
      CreditEntry(id: 'ce1', party: 'Sharma ji', amount: Money.rupees(450), kind: CreditKind.due,
          phone: '9876543210', linkedOrderId: 'o1', at: at),
      CreditEntry.fromJson, (m) => m.toJson());
  roundTrip('12j StaffUser', zaid.copyWith(failedAttempts: 2), StaffUser.fromJson, (m) => m.toJson());
  roundTrip('12k Shift', shift, Shift.fromJson, (m) => m.toJson());
  roundTrip('12l Mutation', mut, Mutation.fromJson, (m) => m.toJson());
  roundTrip('12m DailyTotals', totals, DailyTotals.fromJson, (m) => m.toJson());
  roundTrip('12n DueParty',
      DueParty(party: 'Sharma ji', outstanding: Money.rupees(450), ticketCount: 3, oldestAt: at),
      DueParty.fromJson, (m) => m.toJson());

  report();
}

// ------------------------------------------------------------------ fixtures --

TicketLine _line(String id, int unitPaise, int taxPercent, {int qty = 1}) => TicketLine(
  id: id,
  itemId: 'i_$id',
  nameSnapshot: 'Veg Burger',
  unitPrice: Money(unitPaise),
  taxPercent: taxPercent,
  quantity: qty,
);

OrderTicket _ticket({OrderDiscount discount = OrderDiscount.none, String? table = 'T3', int? billNo}) =>
    OrderTicket(
      id: 'o1',
      billNumber: billNo,
      type: OrderType.dineIn,
      status: OrderStatus.open,
      tableOrName: table,
      openedBy: 'u1',
      openedAt: at,
      discount: discount,
      // Pinned so the codec round-trip is byte-stable on any device timezone;
      // _copy() only stamps now() when a mutation runs, and .withLine() runs on
      // a fresh ticket here, hence updatedAt is set below via the constructor.
      updatedAt: at,
      lines: [_line('l1', 10000, 18), _line('l2', 23456, 18), _line('l3', 6789, 18)],
    );

Payment _pay(String id, int amount, PaymentMode mode, {int? tendered, int? change, String? reference}) =>
    Payment(
      id: id,
      orderId: 'o1',
      mode: mode,
      amount: Money(amount),
      tendered: tendered == null ? null : Money(tendered),
      change: change == null ? null : Money(change),
      reference: reference,
      recordedBy: 'u1',
      at: later,
    );

bool _underflowThrows() {
  try {
    const MoneyDelta(-101).applyTo(Money(100));
    return false;
  } on ArgumentError {
    return true;
  }
}

bool _addAfterServedThrows() {
  final served = OrderTicket(
    id: 'o9',
    type: OrderType.dineIn,
    status: OrderStatus.served,
    openedBy: 'u1',
    openedAt: at,
    lines: [_line('l1', 10000, 18)],
  );
  try {
    served.withLine(_line('l9', 100, 5));
    return false;
  } on StateError {
    return true;
  }
}

bool _unknownStatusThrows() {
  try {
    OrderStatus.fromName('nope');
    return false;
  } on FormatException {
    return true;
  }
}

bool _assertsOk(OrderTicket ticket, List<Payment> payments) {
  try {
    assertPaidConsistency(ticket, payments);
    return true;
  } on StateError {
    return false;
  }
}

// ------------------------------------------------------------------ harness --

void roundTrip<T>(
  String name,
  T model,
  T Function(Map<String, Object?>) fromJson,
  Map<String, Object?> Function(T) toJson,
) {
  try {
    final raw = jsonEncode(toJson(model));
    final back = fromJson(jsonDecode(raw) as Map<String, Object?>);
    final ok = jsonEncode(toJson(back)) == raw && back == model;
    if (ok) _roundTrips++;
    eq('  $name  encode -> decode -> encode is identical and value-equal', ok, true);
  } on Object catch (e) {
    eq('  $name  codec round-trip', 'threw: $e', true);
  }
}

void suite(String title) {
  print('\n$title');
  print('-' * title.length);
}

void eq(String name, Object? actual, Object? expected) {
  if (actual == expected) {
    _passed++;
    print('  PASS  $name');
  } else {
    _failures.add('$name  expected <$expected>, got <$actual>');
    print('  FAIL  $name  -> expected <$expected>, got <$actual>');
  }
}

void throws(String name, void Function() body) {
  try {
    body();
    _failures.add('$name  (nothing thrown)');
    print('  FAIL  $name  -> expected an exception, none thrown');
  } on Object {
    _passed++;
    print('  PASS  $name');
  }
}

void report() {
  print('\n${'=' * 56}');
  if (_failures.isEmpty) {
    print('$_roundTrips/14 PASS  (JSON round-trips)  +  ${_passed - _roundTrips} behaviour checks  =  $_passed total, 0 failures');
    print('Models are sound. Safe to build T3 (drift schema) on top of them.');
    print('${'=' * 56}');
    return;
  }
  print('$_passed passed, ${_failures.length} FAILED:');
  for (final f in _failures) {
    print('  ✗ $f');
  }
  print('${'=' * 56}');
  throw StateError('${_failures.length} model checks failed');
}
