/// KOT / kitchen slip (Task K4 + P1). The invariant is a negative one: a slip
/// that reaches the pass carries NO money, and the only reliable test for that is
/// to search the rendered text for every figure the bill contains.
/// Run: flutter test test/features/printing/kitchen_slip_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:kazama_pos/core/money/money.dart';
import 'package:kazama_pos/data/models/enums.dart';
import 'package:kazama_pos/data/models/menu.dart';
import 'package:kazama_pos/data/models/order.dart';
import 'package:kazama_pos/data/models/order_line.dart';
import 'package:kazama_pos/features/printing/domain/receipt_model.dart';
import 'package:kazama_pos/features/printing/domain/receipt_text_renderer.dart';

final at = DateTime.utc(2026, 9, 5, 20, 5);

OrderTicket ticket() => OrderTicket(
      id: 'o1',
      billNumber: 77,
      type: OrderType.dineIn,
      status: OrderStatus.inKitchen,
      tableOrName: 'T3',
      openedBy: 'u1',
      openedAt: at,
      firedAt: at,
      paid: Money(15000),
      due: Money(18000),
      discount: const OrderDiscount(DiscountKind.absolute, 440),
      lines: const [
        TicketLine(
          id: 'l1',
          itemId: 'i1',
          nameSnapshot: 'Veg Burger',
          unitPrice: Money(10000),
          taxPercent: 18,
          quantity: 2,
          kitchenLabel: 'VEG BURGER',
          note: 'no onion',
          modifiers: [
            ModifierOption(id: 'm1', groupId: 'g1', name: 'Large', priceDelta: Money(2500)),
            ModifierOption(id: 'm2', groupId: 'g1', name: 'Extra cheese', priceDelta: Money(0)),
          ],
        ),
        TicketLine(
          id: 'l2',
          itemId: 'i2',
          nameSnapshot: 'Chicken Burger',
          unitPrice: Money(23456),
          taxPercent: 18,
          quantity: 3,
          cancelledQuantity: 1,
        ),
      ],
    );

String renderKot({int reprintOf = 0}) => const ReceiptTextRenderer().render(
      ReceiptModel.forKitchenTicket(ticket: ticket(), shopName: 'Kazama', widthColumns: 32, reprintOf: reprintOf),
    );

void main() {
  test('the kitchen slip contains no money at all', () {
    final slip = renderKot();
    // Every figure the *bill* prints, by exact string, must be absent. This is
    // stronger than checking for 'TOTAL': a renderer change that leaks one amount
    // still fails here.
    for (final leak in ['100.00', '234.56', '330.00', '150.00', '180.00', '25.00', '4.40', '0.38', 'GST', 'TOTAL', 'DUE', 'SUBTOTAL', 'Change', '₹']) {
      expect(slip, isNot(contains(leak)), reason: '"$leak" reached the kitchen slip:\n$slip');
    }
  });

  test('but it carries everything the cook needs', () {
    final slip = renderKot();
    expect(slip, contains('2 x Veg Burger'));
    expect(slip, contains('3 x Chicken Burger'));
    expect(slip, contains('no onion'), reason: 'a note is a food-safety issue, not a preference');
    expect(slip, contains('Large'), reason: 'modifiers change what is cooked');
    expect(slip, contains('Extra cheese'));
    expect(slip, contains('1 cancelled'), reason: 'a part-cancelled line must not be cooked twice');
    expect(slip, contains('77'), reason: 'the bill number is how a plate finds its table');
    expect(slip, contains('T3'));
  });

  test('a KOT says KITCHEN, and a reprint of one says both', () {
    expect(renderKot(), contains('KITCHEN'));
    expect(renderKot(reprintOf: 2), contains('KITCHEN'));
    expect(renderKot(reprintOf: 2), contains('DUPLICATE COPY 2'));
  });

  test('the bill version of the same ticket does print money (the flag is not global)', () {
    final bill = const ReceiptTextRenderer().render(
      ReceiptModel.forTicket(
        ticket: ticket(),
        payments: [Payment(id: 'p1', orderId: 'o1', mode: PaymentMode.cash, amount: Money(15000), tendered: Money(20000), change: Money(5000), recordedBy: 'u1', at: at)],
        shopName: 'Kazama',
        address: null,
        gstin: null,
        phone: null,
        widthColumns: 32,
      ),
    );
    expect(bill, contains('TOTAL'));
    expect(bill, contains('GST'));
    expect(bill, contains('150.00'));
    expect(bill, contains('KITCHEN'), reason: 'and the bill must NOT be marked as a kitchen slip');
  });

  test('the kind enum round-trips so a stored KOT row is readable after restart', () {
    expect(ReceiptKind.fromName('kitchen'), ReceiptKind.kitchen);
    expect(ReceiptKind.kitchen.label, 'Kitchen');
    // An unknown/legacy name must still resolve (the receipts table is append-only
    // across schema versions), never throw while rendering a list.
    expect(ReceiptKind.fromName('nonsense'), ReceiptKind.sale);
  });
}
