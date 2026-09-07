// Task T3 — the drift schema gate.
// Run:  dart run build_runner build --delete-conflicting-outputs
//       flutter test test/core/app_database_test.dart
//
// This file is ALSO the real verification for T2: every assertion that writes a
// model and reads it back proves the JSON codecs and `Money` maths survive a real
// SQLite round-trip. If it fails, the bug may be in `data/models/` or `core/db/`
// — the failing test name says which.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazama_pos/core/db/app_database.dart';
import 'package:kazama_pos/core/money/money.dart';
import 'package:kazama_pos/data/models/enums.dart';
import 'package:kazama_pos/data/models/menu.dart';
import 'package:kazama_pos/data/models/order.dart';
import 'package:kazama_pos/data/models/payment.dart';

final DateTime at = DateTime.utc(2026, 9, 3, 20, 30);

MenuItem item({String id = 'i1', int price = 10000, bool available = true}) => MenuItem(
  id: id,
  categoryId: 'c1',
  name: 'Veg Burger',
  price: Money(price),
  taxPercent: 18,
  available: available,
);

OrderTicket ticket({OrderStatus status = OrderStatus.open, String? id = 'o1'}) => OrderTicket(
  id: id,
  type: OrderType.dineIn,
  status: status,
  tableOrName: 'T3',
  openedBy: 'u1',
  openedAt: at,
  updatedAt: at,
  discount: const OrderDiscount(DiscountKind.absolute, 440),
  lines: [
    TicketLine(id: 'l1', itemId: 'i1', nameSnapshot: 'Veg Burger', unitPrice: Money(10000), taxPercent: 18),
    TicketLine(id: 'l2', itemId: 'i2', nameSnapshot: 'Chicken Burger', unitPrice: Money(23456), taxPercent: 18),
    TicketLine(id: 'l3', itemId: 'i3', nameSnapshot: 'Cold Coffee', unitPrice: Money(6789), taxPercent: 18),
  ],
);

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    // Drift enables FKs itself on modern versions; stating it keeps the cascade
    // assertions below meaningful on whatever version `pub add` resolved to.
    await db.customStatement('PRAGMA foreign_keys = ON');
  });

  tearDown(() async => db.close());

  group('schema bootstrap', () {
    test('creates all 14 tables and seeds app_meta', () async {
      await db.customSelect('SELECT name FROM sqlite_master WHERE type = ?', variables: [
        Variable.withString('table'),
      ]).get().then((rows) {
        final names = rows.map((r) => r.read<String>('name')).toSet();
        for (final t in [
          'menu_categories',
          'modifier_groups',
          'modifier_options',
          'menu_items',
          'app_meta',
          'orders',
          'order_lines',
          'order_events',
          'sync_outbox',
          'payments',
          'credit_entries',
          'users',
          'shifts',
          'receipts',
        ]) {
          expect(names, contains(t), reason: 'missing table $t');
        }
      });

      final meta = await db.select(db.appMeta).get();
      expect(meta.map((m) => m.metaKey), contains(MetaKeys.schemaVersion));
      expect(
        meta.firstWhere((m) => m.metaKey == MetaKeys.printerPaperColumns).metaValue,
        '32',
        reason: '58mm default until the printer question is answered',
      );
    });

    test('indexes exist for the two hot paths (due list, KDS)', () async {
      final rows = await db.customSelect('SELECT name FROM sqlite_master WHERE type = ?', variables: [
        Variable.withString('index'),
      ]).get();
      final names = rows.map((r) => r.read<String>('name')).toSet();
      expect(names, contains('idx_orders_status_updated'));
      expect(names, contains('idx_lines_order'));
      expect(names, contains('idx_outbox_status_queued'));
    });
  });

  group('menu DAO', () {
    test('upsert preserves the sold-out flag but takes the new price', () async {
      await db.upsertCategory(
        MenuCategory(id: 'c1', name: 'Burgers', sortOrder: 1),
        at: at,
      );
      await db.upsertItem(item(price: 10000, available: true), at: at);
      await db.setItemAvailability('i1', available: false, at: at);
      await db.upsertItem(item(price: 12000, available: true), at: at); // re-seed/restore

      final items = await db.watchItems().first;
      expect(items.single.price.paise, 12000, reason: 'price must update');
      expect(items.single.available, isFalse, reason: 'sold-out must survive a re-upsert (M6/I3)');
    });

    test('deactivating hides an item from the counter but keeps it for history', () async {
      await db.upsertCategory(MenuCategory(id: 'c1', name: 'Burgers'), at: at);
      await db.upsertItem(item(), at: at);
      await db.deactivateItem('i1', at: at);

      expect(await db.watchItems().first, isEmpty);
      final all = await db.watchItems(includeInactive: true).first;
      expect(all.single.active, isFalse);
    });

    test('watchItems re-emits when the menu changes (no polling)', () async {
      await db.upsertCategory(MenuCategory(id: 'c1', name: 'Burgers'), at: at);
      expect(await db.findItem('i1'), isNull, reason: 'not seeded yet');
      final stream = db.watchItems();
      expect((await stream.first), isEmpty);
      await db.upsertItem(item(), at: at);
      expect((await stream.first).length, 1, reason: 'stream re-emitted with no polling');
    });

    test('modifier groups round-trip with option price deltas', () async {
      const group = ModifierGroup(
        id: 'mg1',
        name: 'Size',
        minSelect: 1,
        maxSelect: 1,
        required: true,
        options: [
          ModifierOption(id: 'm1', groupId: 'mg1', name: 'Small', priceDelta: Money(0)),
          ModifierOption(id: 'm2', groupId: 'mg1', name: 'Large', priceDelta: Money(2500)),
        ],
      );
      await db.upsertGroup(group, at: at);
      final back = await db.groupsFor(const {'mg1'});
      expect(back.single.name, 'Size');
      expect(back.single.required, isTrue);
      expect(back.single.options.length, 2);
      expect(back.single.options[1].priceDelta.paise, 2500);
      expect(back.single.isValidSelectionCount(2), isFalse);
    });
  });

  group('ticket persistence (the T2 codec gate)', () {
    test('a whole aggregate survives write -> read', () async {
      await db.replaceTicket(ticket());
      final back = await db.ticketById('o1');
      expect(back, isNotNull);
      expect(back!.status, OrderStatus.open);
      expect(back.type, OrderType.dineIn);
      expect(back.tableOrName, 'T3');
      expect(back.lines.length, 3);
      expect(back.discount.kind, DiscountKind.absolute);
      expect(back.discount.value, 440);
      expect(back.openedAt, at);
      expect(back.paid.paise, 0);
      // Totals recompute identically from the stored snapshot, which is the only
      // guarantee that matters: the bill a reprint shows == the bill charged.
      expect(back.totals.total.paise, 45000);
      expect(ticket().totals.total.paise, back.totals.total.paise);
    });

    test('line order and cancelled quantities are preserved', () async {
      final t = ticket().cancelledLine('l2');
      await db.replaceTicket(t);
      final back = (await db.ticketById('o1'))!;
      expect(back.lines.map((l) => l.id).toList(), ['l1', 'l2', 'l3']);
      expect(back.lines[1].cancelledQuantity, 1);
      expect(back.lines[1].status, LineStatus.cancelled);
      expect(back.totals.total.paise, 38000);
    });

    test('modifiers round-trip as a snapshot, not as ids', () async {
      final t = ticket().withLine(
        TicketLine(
          id: 'l9',
          itemId: 'i1',
          nameSnapshot: 'Veg Burger',
          unitPrice: Money(12000),
          taxPercent: 18,
          modifiers: const [
            ModifierOption(id: 'm2', groupId: 'mg1', name: 'Large', priceDelta: Money(2500)),
          ],
          note: 'no onion',
        ),
      );
      await db.replaceTicket(t);
      final line = (await db.ticketById('o1'))!.lines.last;
      expect(line.modifiers.single.name, 'Large');
      expect(line.modifiers.single.priceDelta.paise, 2500);
      expect(line.note, 'no onion');
    });

    test('fired/ready timestamps persist', () async {
      final t = ticket().fired(at: at).lineReady('l1');
      await db.replaceTicket(t);
      final back = (await db.ticketById('o1'))!;
      expect(back.firedAt, at);
      expect(back.status, OrderStatus.inKitchen);
      expect(back.lines.first.status, LineStatus.ready);
    });

    test('a deleted ticket cascades to its lines, and only to them', () async {
      await db.replaceTicket(ticket());
      await db.into(db.orderLines).insert(
        OrderLinesCompanion.insert(
          id: 'lX',
          orderId: 'o1',
          nameSnapshot: 'Extra',
          unitPricePaise: 100,
          updatedAt: at,
        ),
      );
      expect((await db.select(db.orderLines).get()).length, 4);
      await db.delete(db.orders).go();
      expect(await db.select(db.orderLines).get(), isEmpty, reason: 'FK cascade (D7)');
    });
  });

  group('streams that drive the UI', () {
    test('the due list shows an unpaid ticket and drops it once settled', () async {
      final open = db.watchOpenTickets();
      expect(await open.first, isEmpty);

      await db.replaceTicket(ticket());
      expect((await open.first).single.id, 'o1');

      await db.insertPayment(
        Payment(
          id: 'p1',
          orderId: 'o1',
          mode: PaymentMode.cash,
          amount: Money(45000),
          tendered: Money(50000),
          change: Money(5000),
          recordedBy: 'u1',
          at: at,
        ),
      );
      await db.replaceTicket((await db.ticketById('o1'))!.withPaymentApplied(Money(45000), at: at));
      expect(await open.first, isEmpty, reason: 'a settled ticket must leave the due list');
    });

    test('the KDS feed picks up a fired ticket without a manual refresh', () async {
      final kitchen = db.watchKitchenTickets();
      await db.replaceTicket(ticket());
      expect(await kitchen.first, isEmpty, reason: 'not fired yet');

      await db.replaceTicket(ticket().fired(at: at));
      final feed = await kitchen.first;
      expect(feed.single.id, 'o1');
      expect(feed.single.lines.every((l) => l.status == LineStatus.fired), isTrue);
    });

    test('bill numbers are monotonic across a fresh database', () async {
      expect(await db.nextBillNumber(), 1);
      expect(await db.nextBillNumber(), 2);
      expect(await db.nextBillNumber(), 3);
    });

    test('a payment refreshes the paid cache in the same transaction', () async {
      await db.replaceTicket(ticket());
      await db.insertPayment(
        Payment(id: 'p1', orderId: 'o1', mode: PaymentMode.upi, amount: Money(15000), recordedBy: 'u1', at: at),
      );
      final back = (await db.ticketById('o1'))!;
      expect(back.paid.paise, 15000);
      expect(back.due.paise, 30000);
      assertPaidConsistency(back, [
        Payment(id: 'p1', orderId: 'o1', mode: PaymentMode.upi, amount: Money(15000), recordedBy: 'u1', at: at),
      ]);
    });

    test('a malformed payment never reaches the ledger', () async {
      await db.replaceTicket(ticket());
      // `await`ed, because insertPayment is async: the throw arrives on the
      // Future, and `expect(() => async(), ...)` would pass vacuously.
      await expectLater(
        db.insertPayment(
          Payment(id: 'p2', orderId: 'o1', mode: PaymentMode.cash, amount: Money(0), recordedBy: 'u1', at: at),
        ),
        throwsArgumentError,
      );
      expect((await db.ticketById('o1'))!.paid.paise, 0);
    });

    test('audit events append and never overwrite', () async {
      await db.replaceTicket(ticket());
      await db.appendEvent(orderId: 'o1', eventType: 'fired', actorId: 'u1', at: at);
      await db.appendEvent(
        orderId: 'o1',
        eventType: 'payment',
        actorId: 'u1',
        payload: const {'amountPaise': 15000},
        at: at.add(const Duration(minutes: 5)),
      );
      final events = await db.select(db.orderEvents).get();
      expect(events.length, 2);
      expect(events.map((e) => e.eventType), ['fired', 'payment']);
      expect(events[1].payloadJson, contains('15000'));
    });
  });
}
