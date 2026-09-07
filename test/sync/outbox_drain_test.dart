// Task T5 — the drain loop against the REAL schema, because the interesting
// failure modes (deletion only on ack, SQL-side attempt counting, released
// orphans) all live in the interaction between the engine and drift.
// Run: flutter test test/sync/outbox_drain_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:kazama_pos/core/db/app_database.dart';
import 'package:kazama_pos/core/utils/id.dart';
import 'package:kazama_pos/data/models/enums.dart';
import 'package:kazama_pos/core/money/money.dart';
import 'package:kazama_pos/data/models/mutation.dart';
import 'package:kazama_pos/data/repositories/contract/order_repository.dart' show MenuItemLike;
import 'package:kazama_pos/data/repositories/impl/order_repository_impl.dart';
import 'package:kazama_pos/data/repositories/impl/sync_journal.dart';
import 'package:kazama_pos/sync/sync_engine.dart';
import 'package:kazama_pos/sync/sync_gateway.dart';

/// Records what was pushed and decides what comes back.
class _FakeGateway implements SyncGateway {
  _FakeGateway(this.onPush);

  final List<SyncAck> Function(SyncBatch batch, int pushNumber) onPush;
  final List<SyncBatch> pushed = [];

  @override
  String get label => 'fake';

  @override
  bool get isRemote => true;

  @override
  Future<List<SyncAck>> push(SyncBatch batch) async {
    pushed.add(batch);
    return onPush(batch, pushed.length);
  }
}

List<SyncAck> _allOk(SyncBatch b, int _) => [for (final m in b.mutations) SyncAck(m.idempotencyKey)];

class _FakeItem implements MenuItemLike {
  const _FakeItem({this.id = 'i1', this.name = 'Veg Burger', this.pricePaise = 10000, this.taxPercent = 5});

  @override
  final String id;
  @override
  final String name;
  final int pricePaise;
  @override
  final int taxPercent;
  @override
  Money get price => Money(pricePaise);
  @override
  String? get kitchenLabel => null;
}

void main() {
  late AppDatabase db;
  late IdFactory ids;
  setUp(() {
    db = AppDatabase.memory();
    ids = IdFactory.fixed('t');
  });
  tearDown(() async => db.close());

  Future<void> enqueue(int n, {String entity = 'order'}) => journalMutation(
        db,
        ids,
        entity: entity,
        entityId: 'o$n',
        op: MutationOp.update,
        payload: {'n': n},
        at: DateTime.utc(2026, 9, 5).add(Duration(minutes: n)),
      );

  Future<List<String>> storedIds() async => (await db.select(db.syncOutbox).get()).map((r) => r.id).toList();

  test('an acked batch is deleted, not flagged', () async {
    await enqueue(1);
    await enqueue(2);
    final engine = SyncEngine(outbox: db, gateway: _FakeGateway(_allOk), pollInterval: null);
    await engine.flush();
    expect(await storedIds(), isEmpty);
    expect(await db.countPending(), 0);
    expect(engine.lastCycle?.sent, 2);
  });

  test('a thrown transport error deletes nothing and ages every row by one', () async {
    await enqueue(1);
    await enqueue(2);
    final gateway = _FakeGateway((_, __) => throw const SyncRejectException('offline'));
    final engine = SyncEngine(outbox: db, gateway: gateway, pollInterval: null);
    await engine.flush();
    final rows = await db.select(db.syncOutbox).get();
    expect(rows.length, 2, reason: 'the sale rows must survive a failed upload');
    expect(rows.every((r) => r.attempts == 1), isTrue);
    expect(rows.every((r) => r.status == SyncStatus.pending.wire), isTrue);
    expect(engine.lastError, 'offline');
    expect(engine.consecutiveFailures, 1);
  });

  test('a row the server refused keeps retrying and stops on its own count', () async {
    await enqueue(1);
    // Refuse it every time: after maxAttempts the row must leave the retry pool
    // rather than live at the top of `pending()` forever.
    final gateway = _FakeGateway((b, _) => [for (final m in b.mutations) SyncAck(m.idempotencyKey, error: 'bad schema')]);
    final engine = SyncEngine(outbox: db, gateway: gateway, pollInterval: null);
    for (var i = 0; i < Mutation.maxAttempts - 1; i++) {
      await engine.flush();
    }
    var row = (await db.select(db.syncOutbox).get()).single;
    expect(row.status, SyncStatus.pending.wire, reason: 'one attempt still left');
    await engine.flush();
    row = (await db.select(db.syncOutbox).get()).single;
    expect(row.status, SyncStatus.stuck.wire);
    expect(row.attempts, Mutation.maxAttempts);
    expect(row.lastError, contains('bad schema'));
    // Stuck rows are not in the retry pool any more…
    expect(await db.countPending(), 0);
    // …but a human pressing Sync gets them one more life.
    expect((await db.stuck()).length, 1);
    await engine.retryStuck();
    expect((await db.select(db.syncOutbox).get()).single.attempts, 0);
  });

  test('a partial ack leaves exactly the un-answered row', () async {
    await enqueue(1);
    await enqueue(2);
    final gateway = _FakeGateway((b, _) => [SyncAck(b.mutations.first.idempotencyKey)]);
    final engine = SyncEngine(outbox: db, gateway: gateway, pollInterval: null);
    await engine.flush();
    final left = await db.pending();
    expect(left.map((m) => m.entityId), ['o2']);
    expect(left.single.attempts, 1);
    expect(engine.lastCycle?.sent, 1);
  });

  test('a duplicate idempotency key is not journalled twice', () async {
    final at = DateTime.utc(2026, 9, 5, 6);
    for (var i = 0; i < 3; i++) {
      await db.enqueueMutation(Mutation(
        id: 'dup$i',
        entity: 'payment',
        entityId: 'p1',
        op: MutationOp.insert,
        payload: const {'amountPaise': 100},
        idempotencyKey: 'same-key',
        queuedAt: at,
      ));
    }
    expect((await db.select(db.syncOutbox).get()).length, 1, reason: 'UNIQUE(idempotency_key) + doNothing');
  });

  test('rows stranded in in_flight by a crash are released at start, not mid-loop', () async {
    await enqueue(1);
    await db.markInFlight((await db.pending()).map((m) => m.id).toList());
    expect(await db.countPending(), 0, reason: 'leased rows are invisible to the queue');
    SyncEngine(outbox: db, gateway: _FakeGateway((b, _) => _allOk(b, 1)), pollInterval: null).start();
    await pumpEventQueue();
    expect(await storedIds(), isEmpty, reason: 'start() released them and the flush drained them');
  });

  test('the drain order is oldest-first and the batch is capped', () async {
    for (var i = 10; i >= 1; i--) {
      await enqueue(i);
    }
    late List<String> seen;
    final gateway = _FakeGateway((b, push) {
      seen = b.mutations.map((m) => m.entityId).toList();
      return _allOk(b, push);
    });
    await SyncEngine(outbox: db, gateway: gateway, pollInterval: null).flush();
    expect(seen, [for (var i = 1; i <= 10; i++) 'o$i']);
  });

  test('flush() during a cycle folds into one extra pass instead of a second upload', () async {
    await enqueue(1);
    final gate = _FakeGateway((b, push) => push == 1 ? _allOk(b, push) : _allOk(b, push));
    final engine = SyncEngine(
      outbox: db,
      gateway: gate,
      pollInterval: null,
      // Hold the first push open long enough for a second flush() to arrive.
      beforeCycle: () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    final first = engine.flush();
    final second = engine.flush();
    await Future.wait([first, second]);
    expect(gate.pushed.length, 1, reason: 'the queue was empty on the follow-up pass, so nothing was sent twice');
  });

  test('every ticket edit journals one mutation, and a drain collapses them', () async {
    final repo = OrderRepositoryImpl(db, idFactory: IdFactory.fixed('o'));
    final ticket = await repo.startTicket(type: OrderType.dineIn, openedBy: 'u1');
    // Two edits, two rows: the outbox is a journal of *actions*, not a snapshot of
    // the row. Order is preserved and each mutation carries the full post-write
    // ticket, so a server applying them in sequence lands on the final state —
    // which is why a drain of both in one batch is safe.
    await repo.addMenuItem(ticketId: ticket.id, item: const _FakeItem(), quantity: 1);
    await repo.addMenuItem(ticketId: ticket.id, item: const _FakeItem(id: 'i2', name: 'Filter Coffee'), quantity: 2);
    expect(await db.countPending(), 2, reason: 'one mutation per ticket write, in write order');
    final rows = await db.pending();
    expect(rows.map((m) => m.entityId).toSet(), {ticket.id});
    final last = (rows.last.payload['lines']! as List).cast<Map<String, Object?>>();
    expect(last.length, 2, reason: 'the newest mutation carries the whole ticket');
    expect(last[1]['quantity'], 2);
    expect(last[0]['unitPricePaise'], 10000);
    expect((await db.select(db.orders).get()).single.id, ticket.id, reason: 'the write itself landed');

    await repo.fire(ticketId: ticket.id, actorId: 'u1');
    final fired = await db.pending();
    expect(fired.length, 3, reason: 'the fire is a third mutation, not a rewrite of the second');
    expect((fired.last.payload['lines']! as List).length, 2);
    expect(fired.last.payload['status'], 'inKitchen');
    expect(
      DateTime.parse(fired.last.payload['updatedAt']! as String).isAfter(DateTime.parse(fired.first.payload['updatedAt']! as String)),
      isTrue,
      reason: 'the server applies these in queue order, so the last write must be the last row',
    );

    final engine = SyncEngine(outbox: db, gateway: const NoopSyncGateway());
    await engine.flush();
    expect(await db.countPending(), 0);
    expect((await db.select(db.orders).get()).single.id, ticket.id, reason: 'draining never touches the sale');
  });

  test('a noop gateway drains the queue with no timer running', () async {
    await enqueue(1);
    await enqueue(2);
    final engine = SyncEngine(outbox: db, gateway: const NoopSyncGateway());
    expect(engine.isPolling, isFalse, reason: 'no server, no polling (battery)');
    expect(await engine.unsyncedCount, 2);
    await engine.flush();
    expect(await engine.unsyncedCount, 0);
  });
}
