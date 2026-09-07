// Task T2 — flutter_test mirror of tools/check_models.dart.
// Run after the scaffold exists:  flutter test test/data/models_test.dart
//
// `deepEquals` is exercised through the round-trips below; these models import
// only core/money and each other, which is the point (SKILLS.md §A2/D1).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazama_pos/core/money/money.dart';
import 'package:kazama_pos/core/money/money_delta.dart';
import 'package:kazama_pos/data/models/enums.dart';
import 'package:kazama_pos/data/models/menu.dart';
import 'package:kazama_pos/data/models/mutation.dart';
import 'package:kazama_pos/data/models/order.dart';
import 'package:kazama_pos/data/models/payment.dart';
import 'package:kazama_pos/data/models/report.dart';
import 'package:kazama_pos/data/models/staff.dart';

final DateTime at = DateTime.utc(2026, 9, 3, 20, 30);
final DateTime later = DateTime.utc(2026, 9, 3, 21);

TicketLine line(String id, int unitPaise, int taxPercent, {int qty = 1}) => TicketLine(
  id: id,
  itemId: 'i_$id',
  nameSnapshot: 'Veg Burger',
  unitPrice: Money(unitPaise),
  taxPercent: taxPercent,
  quantity: qty,
);

OrderTicket ticket({OrderDiscount discount = OrderDiscount.none, String? table = 'T3'}) => OrderTicket(
  id: 'o1',
  type: OrderType.dineIn,
  status: OrderStatus.open,
  tableOrName: table,
  openedBy: 'u1',
  openedAt: at,
  updatedAt: at,
  discount: discount,
  lines: [line('l1', 10000, 18), line('l2', 23456, 18), line('l3', 6789, 18)],
);

void main() {
  group('MenuItem / ModifierGroup', () {
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
    );

    test('upcharges are per unit sold', () {
      expect(veg.unitPriceWith([cheese]).paise, 12000);
      expect(veg.unitPriceWith(const []).paise, 10000);
    });

    test('kitchen label and menu name are separate', () {
      expect(veg.kitchenDisplay, 'VEG BURGER');
      expect(veg.displayName, 'Veg Burger');
    });

    test('sold-out and deactivated both block ordering', () {
      expect(veg.copyWith(available: false).canBeOrdered, isFalse);
      expect(veg.copyWith(active: false).canBeOrdered, isFalse);
      expect(veg.canBeOrdered, isTrue);
    });

    test('selection counts are validated against the group rules', () {
      const size = ModifierGroup(id: 'mg2', name: 'Size', minSelect: 1, maxSelect: 1, required: true);
      expect(size.isValidSelectionCount(1), isTrue);
      expect(size.isValidSelectionCount(0), isFalse);
      expect(size.isValidSelectionCount(2), isFalse);
    });
  });

  group('TicketLine', () {
    test('tax/base split matches the hand-computed fixture', () {
      final l = line('l1', 10000, 18);
      expect(l.lineTotal.paise, 10000);
      expect(l.tax.paise, 1525);
      expect(l.base.paise, 8475);
    });

    test('quantity scales total and tax together', () {
      final l = line('l1', 10000, 18, qty: 3);
      expect(l.lineTotal.paise, 30000);
      expect(l.tax.paise, 4575);
    });

    test('partial cancellation bills only the live quantity', () {
      final l = TicketLine(
        id: 'l2',
        itemId: 'i2',
        nameSnapshot: 'Fries',
        unitPrice: Money(1000),
        taxPercent: 5,
        quantity: 3,
        cancelledQuantity: 2,
      );
      expect(l.liveQuantity, 1);
      expect(l.lineTotal.paise, 1000);
      expect(l.isFullyCancelled, isFalse);
    });
  });

  group('BillTotals', () {
    test('discount + per-line tax + rounding reproduce the worked bill', () {
      final t = ticket(discount: const OrderDiscount(DiscountKind.absolute, 440)).totals;
      expect(t.lineBase.paise, 34107);
      expect(t.discount.paise, 440);
      expect(t.tax.paise, 5879);
      expect(t.total.paise, 45000);
      expect(t.netBeforeTax.paise + t.tax.paise, t.total.paise);
      expect(t.rounding.paise, 0);
    });

    test('a total that must round DOWN gets a negative ROUNDING line', () {
      final t = ticket();
      final odd = OrderTicket(
        id: 'o2',
        type: OrderType.takeaway,
        status: OrderStatus.open,
        openedBy: 'u1',
        openedAt: at,
        lines: [line('l9', 1001, 0)],
      );
      expect(t.lines.length, 3); // sanity
      expect(odd.totals.total.paise, 1000);
      expect(odd.totals.rounding.paise, -1);
      expect(odd.totals.rounding.toString(), '-₹0.01');
    });

    test('gross reported to owners ignores the discount', () {
      final t = ticket(discount: const OrderDiscount(DiscountKind.absolute, 440)).totals;
      expect(t.grossBeforeDiscount.paise, 34107);
    });
  });

  group('OrderDiscount', () {
    test('percent and absolute, capped at the bill', () {
      expect(const OrderDiscount(DiscountKind.percent, 10).amountFor(Money(40000)).paise, 4000);
      expect(const OrderDiscount(DiscountKind.absolute, 500).amountFor(Money(300)).paise, 300);
      expect(OrderDiscount.none.amountFor(Money(5000)).paise, 0);
    });
  });

  group('status predicates', () {
    test('KDS and due-list membership', () {
      expect(OrderStatus.open.appearsOnKds, isFalse);
      expect(OrderStatus.inKitchen.appearsOnKds, isTrue);
      expect(OrderStatus.ready.appearsOnKds, isTrue);
      expect(OrderStatus.served.appearsInDueList, isTrue);
      expect(OrderStatus.served.isSettled, isFalse);
      expect(OrderStatus.paid.isSettled, isTrue);
      expect(OrderStatus.voided.isSettled, isTrue);
    });

    test('the two sections cannot bleed into each other', () {
      expect(OrderStatus.open.allowsAddingItems, isTrue);
      expect(OrderStatus.ready.allowsAddingItems, isFalse);
      expect(OrderType.dineIn.isPayAfterEating, isTrue);
      expect(OrderType.takeaway.isPayUpfront, isTrue);
      final served = OrderTicket(
        id: 'o9',
        type: OrderType.dineIn,
        status: OrderStatus.served,
        openedBy: 'u1',
        openedAt: at,
      );
      expect(() => served.withLine(line('l9', 100, 5)), throwsStateError);
    });

    test('an unknown status name is fatal, an unknown order type falls back', () {
      expect(() => OrderStatus.fromName('nope'), throwsFormatException);
      expect(OrderType.fromName('banquet'), OrderType.takeaway);
    });
  });

  group('Payment', () {
    Payment pay(String id, int amount, PaymentMode mode, {int? tendered, int? change}) => Payment(
      id: id,
      orderId: 'o1',
      mode: mode,
      amount: Money(amount),
      tendered: tendered == null ? null : Money(tendered),
      change: change == null ? null : Money(change),
      recordedBy: 'u1',
      at: later,
    );

    test('valid split rows pass shape validation', () {
      pay('p1', 5000, PaymentMode.cash, tendered: 6000, change: 1000).validateShape();
      pay('p2', 4000, PaymentMode.upi).validateShape();
    });

    test('garbage rows are rejected', () {
      expect(() => pay('p3', 0, PaymentMode.cash).validateShape(), throwsArgumentError);
      expect(() => pay('p4', 5000, PaymentMode.cash, tendered: 4000).validateShape(),
          throwsArgumentError);
      expect(() => pay('p5', 100, PaymentMode.upi, tendered: 100).validateShape(),
          throwsArgumentError);
    });

    test('summary keeps modes separate and preserves order', () {
      final s = PaymentSummary.of([
        pay('p1', 5000, PaymentMode.cash, tendered: 6000, change: 1000),
        pay('p2', 4000, PaymentMode.upi),
      ]);
      expect(s.total.paise, 9000);
      expect(s.byMode[PaymentMode.cash]!.paise, 5000);
      expect(s.modesUsed, [PaymentMode.cash, PaymentMode.upi]);
      expect(s.changeGiven.paise, 1000);
    });

    test('drawer and due semantics come from the mode', () {
      expect(PaymentMode.cash.affectsCashDrawer, isTrue);
      expect(PaymentMode.upi.affectsCashDrawer, isFalse);
      expect(PaymentMode.credit.createsADue, isTrue);
      expect(PaymentMode.upi.wantsReference, isTrue);
    });
  });

  group('OrderTicket settlement', () {
    test('settle clears the due and stamps closedAt', () {
      final t = ticket().withPaymentApplied(Money(45000), at: later);
      expect(t.status, OrderStatus.paid);
      expect(t.due.paise, 0);
      expect(t.closedAt, later);
      expect(t.appearsInDueList, isFalse);
    });

    test('partial payment leaves a due and keeps the ticket visible', () {
      final t = ticket().withPaymentApplied(Money(15000), at: later);
      expect(t.status, OrderStatus.partiallyPaid);
      expect(t.due.paise, 30000);
      expect(t.appearsInDueList, isTrue);
      expect(t.summaryLabel, 'T3 · 3 items · ₹450.00');
    });

    test('overpaying throws instead of clamping', () {
      expect(() => ticket().withPaymentApplied(Money(50000), at: later), throwsArgumentError);
    });

    test('a stale paid cache is caught before it reaches a report', () {
      final part = ticket().withPaymentApplied(Money(15000), at: later);
      final lying = Payment(
        id: 'pX', orderId: 'o1', mode: PaymentMode.upi, amount: Money(4000),
        recordedBy: 'u1', at: later,
      );
      expect(() => assertPaidConsistency(part, [lying]), throwsStateError);
      final honest = Payment(
        id: 'pY', orderId: 'o1', mode: PaymentMode.cash, amount: Money(15000),
        recordedBy: 'u1', at: later,
      );
      assertPaidConsistency(part, [honest]);
    });
  });

  group('OrderTicket kitchen flow', () {
    test('fire marks pending lines and stamps firedAt once', () {
      final fired = ticket().fired(at: at);
      expect(fired.status, OrderStatus.inKitchen);
      expect(fired.lines.every((l) => l.status == LineStatus.fired), isTrue);
      expect(fired.firedAt, at);
      expect(() => fired.fired(at: later), throwsStateError);
    });

    test('ticket becomes READY only when every live line is ready', () {
      final fired = ticket().fired(at: at);
      expect(fired.lineReady('l1').maybeReady(at: later).status, OrderStatus.inKitchen);
      final all = fired.lineReady('l1').lineReady('l2').lineReady('l3').maybeReady(at: later);
      expect(all.status, OrderStatus.ready);
      expect(all.served(at: later).lines.every((l) => l.status == LineStatus.served), isTrue);
      expect(all.served(at: later).status, OrderStatus.served);
    });

    test('cancelling one line removes exactly that money', () {
      final t = ticket().cancelledLine('l1');
      expect(t.lines.firstWhere((l) => l.id == 'l1').liveQuantity, 0);
      expect(t.totals.total.paise, 38000);
      expect(t.lineCount, 2);
      expect(t.itemCount, 2);
    });

    test('void rules: needs a reason, refuses a paid ticket', () {
      expect(() => ticket().voided(reason: '   ', at: later), throwsArgumentError);
      expect(ticket().voided(reason: 'wrong order', at: later).status, OrderStatus.voided);
      final paid = ticket().withPaymentApplied(Money(45000), at: later);
      expect(() => paid.voided(reason: 'guest left', at: later), throwsStateError);
    });
  });

  group('MoneyDelta', () {
    test('signed maths and underflow guard', () {
      expect(const MoneyDelta(100).applyTo(Money(100)).paise, 200);
      expect(const MoneyDelta(-1).applyTo(Money(100)).paise, 99);
      expect(() => const MoneyDelta(-101).applyTo(Money(100)), throwsArgumentError);
      expect(MoneyDelta.sum(const [MoneyDelta(10), MoneyDelta(-4)]).paise, 6);
    });

    test('display always carries the sign, zero is neutral', () {
      expect('${const MoneyDelta(100)}', '+₹1.00');
      expect('${const MoneyDelta(-1)}', '-₹0.01');
      expect('${MoneyDelta.zero}', '₹0.00');
    });

    test('Money extension exposes the signed rounding', () {
      expect(Money(1001).roundingSignedPaise, -1);
      expect(Money(1001).roundingDelta.paise, 99);
      expect(Money(1049).roundingDelta.paise, -49);
    });
  });

  group('StaffUser / Shift / ReceiptRecord', () {
    final zaid = StaffUser(
      id: 'u1', name: 'Zaid', role: UserRole.cashier, pinHash: 'x' * 64, createdAt: at,
    );

    test('role gates are explicit', () {
      expect(zaid.canBill && !zaid.canEditMenu, isTrue);
      expect(zaid.canVoid, isFalse);
      expect(zaid.canViewKds, isFalse);
      expect(UserRole.kitchen.canViewKds && !UserRole.kitchen.canBill, isTrue);
      expect(UserRole.manager.canEditMenu && UserRole.manager.canSeeReports, isTrue);
    });

    test('lockout is time based', () {
      expect(zaid.isLocked, isFalse);
      expect(zaid.copyWith(lockedUntil: later.add(const Duration(minutes: 1))).isLocked, isTrue);
    });

    test('shift variance is signed and counts cash only', () {
      final shift = Shift(
        id: 's1', userId: 'u1', openingFloat: Money.rupees(500), openedAt: at,
      );
      final cash = Payment(
        id: 'p1', orderId: 'o1', mode: PaymentMode.cash, amount: Money(5000),
        recordedBy: 'u1', at: later,
      );
      final upi = Payment(
        id: 'p2', orderId: 'o1', mode: PaymentMode.upi, amount: Money(4000),
        recordedBy: 'u1', at: later,
      );
      expect(shift.expectedCash([cash, upi]).paise, 55000);
      expect(shift.variance([cash, upi], Money.rupees(546)).paise, -400);
      expect(shift.variance([cash, upi], Money.rupees(552)).paise, 200);
      expect(shift.isOpen, isTrue);
    });
  });

  group('Mutation (outbox row)', () {
    test('stuck after maxAttempts, never retried forever', () {
      var m = Mutation(
        id: 'm1', entity: 'order', entityId: 'o1', op: MutationOp.insert,
        payload: const {'id': 'o1'}, idempotencyKey: 'k1', queuedAt: at,
      );
      expect(m.shouldRetry, isTrue);
      for (var i = 0; i < Mutation.maxAttempts; i++) {
        m = m.markFailed('timeout');
      }
      expect(m.attempts, 10);
      expect(m.status, SyncStatus.stuck);
      expect(m.shouldRetry, isFalse);
    });

    test('payload survives the TEXT column', () {
      final m = Mutation(
        id: 'm1', entity: 'order', entityId: 'o1', op: MutationOp.insert,
        payload: const {'id': 'o1', 'totalPaise': 45000}, idempotencyKey: 'k1', queuedAt: at,
      );
      expect(Mutation.decodePayload(m.encodePayload())['totalPaise'], 45000);
      expect(() => MutationOp.fromWire('UPSERT'), throwsFormatException);
    });
  });

  group('report read-models', () {
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

    test('average bill is integer maths', () {
      expect(totals.averageBill.paise, 24000);
      expect(totals.charged.paise, 108000);
      expect(totals.hasDue, isTrue);
    });

    test('a due older than 30 days is flagged as aging', () {
      expect(
        DueParty(
          party: 'Sharma ji', outstanding: Money.rupees(450), ticketCount: 3,
          oldestAt: DateTime.utc(2020),
        ).isAging,
        isTrue,
      );
    });
  });

  group('JSON codecs round-trip', () {
    void rt<T>(String label, T model, T Function(Map<String, Object?>) fromJson, Map<String, Object?> Function(T) toJson) {
      final raw = jsonEncode(toJson(model));
      final back = fromJson(jsonDecode(raw) as Map<String, Object?>);
      expect(jsonEncode(toJson(back)), raw, reason: '$label: second encode differs (missing field in fromJson?)');
      expect(back, model, reason: '$label: value equality broke (missing field in == or toJson?)');
    }

    final cheese = ModifierOption(
      id: 'mo1', groupId: 'mg1', name: 'Extra cheese', priceDelta: Money.rupees(20),
    );

    test('14 models survive encode -> decode -> encode', () {
      rt('ModifierOption', cheese, ModifierOption.fromJson, (m) => m.toJson());
      rt('ModifierGroup',
          ModifierGroup(id: 'mg2', name: 'Size', minSelect: 1, maxSelect: 1, required: true, options: [cheese]),
          ModifierGroup.fromJson, (m) => m.toJson());
      rt('MenuCategory',
          MenuCategory(id: 'c1', name: 'Burgers', sortOrder: 2, modifierGroupIds: const ['mg1']),
          MenuCategory.fromJson, (m) => m.toJson());
      rt('MenuItem',
          MenuItem(id: 'i1', categoryId: 'c1', name: 'Veg Burger', price: Money(10000), taxPercent: 18,
              barcode: '8901234567890'),
          MenuItem.fromJson, (m) => m.toJson());
      rt('TicketLine',
          line('l1', 10000, 18).copyWith(modifiers: [cheese], note: 'no onion', noteSet: true),
          TicketLine.fromJson, (m) => m.toJson());
      rt('OrderDiscount', const OrderDiscount(DiscountKind.percent, 10), OrderDiscount.fromJson, (m) => m.toJson());
      rt('OrderTicket', ticket(table: 'T3'), OrderTicket.fromJson, (m) => m.toJson());
      rt('Payment',
          Payment(id: 'p1', orderId: 'o1', mode: PaymentMode.cash, amount: Money(5000),
              tendered: Money(6000), change: Money(1000), reference: 'GPay 88213', recordedBy: 'u1', at: later),
          Payment.fromJson, (m) => m.toJson());
      rt('CreditEntry',
          CreditEntry(id: 'ce1', party: 'Sharma ji', amount: Money.rupees(450), kind: CreditKind.due,
              phone: '9876543210', linkedOrderId: 'o1', at: at),
          CreditEntry.fromJson, (m) => m.toJson());
      rt('StaffUser',
          StaffUser(id: 'u1', name: 'Zaid', role: UserRole.cashier, pinHash: 'x' * 64, createdAt: at),
          StaffUser.fromJson, (m) => m.toJson());
      rt('Shift', Shift(id: 's1', userId: 'u1', openingFloat: Money.rupees(500), openedAt: at),
          Shift.fromJson, (m) => m.toJson());
      rt('Mutation',
          Mutation(id: 'm1', entity: 'order', entityId: 'o1', op: MutationOp.insert,
              payload: const {'id': 'o1'}, idempotencyKey: 'k1', queuedAt: at),
          Mutation.fromJson, (m) => m.toJson());
      rt('DailyTotals',
          DailyTotals(day: DateTime.utc(2026, 9, 3), bills: 4, covers: 12, gross: Money.rupees(1000),
              discount: Money.rupees(40), tax: Money.rupees(120), rounding: const MoneyDelta(-3),
              netSales: Money.rupees(960), due: Money.rupees(300)),
          DailyTotals.fromJson, (m) => m.toJson());
      rt('DueParty',
          DueParty(party: 'Sharma ji', outstanding: Money.rupees(450), ticketCount: 3, oldestAt: at),
          DueParty.fromJson, (m) => m.toJson());
    });
  });
}
