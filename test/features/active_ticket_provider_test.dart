/// The "bill stays on screen after it is paid" rule (Y1 + the provider fallback).
///
/// This is a provider test, not a widget test, on purpose: the defect it guards is
/// invisible in a screenshot (a one-frame swap to the due list) but fatal in
/// behaviour — a cashier who sees the screen change under their finger mid-payment
/// taps the wrong row. Driving the provider directly keeps the assertion on the
/// *data* the three counter screens read.
///
/// Run: flutter test test/features/active_ticket_provider_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazama_pos/core/db/app_database.dart';
import 'package:kazama_pos/core/money/money.dart';
import 'package:kazama_pos/core/providers.dart';
import 'package:kazama_pos/data/models/enums.dart';
import 'package:kazama_pos/data/models/menu.dart';
import 'package:kazama_pos/data/repositories/contract/order_repository.dart';

MenuItem _item() => MenuItem(
      id: 'i1',
      categoryId: 'c1',
      name: 'Veg Burger',
      price: Money(10000),
      taxPercent: 18,
      available: true,
    );

void main() {
  late AppDatabase db;
  late ProviderContainer c;

  setUp(() async {
    db = AppDatabase.memory();
    // A category is required: `menu_items.category_id` has a FK, and the point of
    // this test is the provider, not the schema — but a red FK would silently make
    // every expectation below vacuous.
    await db.customStatement(
      "INSERT INTO menu_categories (id, name, sort_order, active, updated_at, modifier_group_ids) "
      "VALUES ('c1','Burgers',0,1,0,'[]')",
    );
    c = ProviderContainer(overrides: [appDatabaseProvider.overrideWithValue(db)]);
    final repo = c.read(orderRepositoryProvider);
    final ticket = await repo.startTicket(type: OrderType.dineIn, openedBy: 'u1', tableOrName: 'T1');
    await repo.addMenuItem(ticketId: ticket.id, item: _item(), quantity: 1);
    c.read(activeTicketIdProvider.notifier).state = ticket.id;
  });

  tearDown(() async {
    c.dispose();
    await db.close();
  });

  test('an open ticket resolves from the watched list, no extra read', () async {
    final t = (await c.read(activeTicketProvider.future))!;
    expect(t.status, OrderStatus.open);
    expect(t.due.paise, greaterThan(0));
  });

  test('paying it in full KEEPS it resolvable (settled), so the screen can show "Paid"', () async {
    final repo = c.read(orderRepositoryProvider);
    final before = (await c.read(activeTicketProvider.future))!;
    await repo.recordPayment(
      ticketId: before.id,
      mode: PaymentMode.cash,
      amount: before.due,
      tendered: before.due,
      actorId: 'u1',
    );

    // The ticket is gone from the OPEN list — that is exactly the old bug.
    final open = await c.read(openTicketsProvider.future);
    expect(open.map((t) => t.id), isNot(contains(before.id)));

    // ...and the provider's fallback read still returns it, paid.
    final after = (await c.read(activeTicketProvider.future))!;
    expect(after.id, before.id);
    expect(after.status, OrderStatus.paid);
    expect(after.due.isZero, isTrue);
  });

  test('clearing the selection resolves to null (the screen may then move on)', () async {
    final before = (await c.read(activeTicketProvider.future))!;
    final repo = c.read(orderRepositoryProvider);
    await repo.recordPayment(
      ticketId: before.id,
      mode: PaymentMode.cash,
      amount: before.due,
      tendered: before.due,
      actorId: 'u1',
    );
    c.read(activeTicketIdProvider.notifier).state = null;
    expect(await c.read(activeTicketProvider.future), isNull);
  });

  test('a stale selection (ticket deleted underneath) reads null rather than hanging', () async {
    c.read(activeTicketIdProvider.notifier).state = 'nope';
    expect(await c.read(activeTicketProvider.future), isNull);
  });
}
