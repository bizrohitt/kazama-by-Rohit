/// Outbox access for the sync engine (Task T2's rows, T5's engine).
///
/// Kept in the `app_database.dart` library like the other secondary DAOs, so it
/// can select over `syncOutbox` with no drift import of its own.
///
/// What this DAO deliberately does NOT know:
///  * **no timestamps written by SQL** — SQLite's `strftime('%s','now')` is UTC
///    while every other timestamp in this app is a Dart `DateTime.now()`, which
///    on a shop phone at UTC+5:30 is a five-and-a-half-hour lie about "when may
///    I retry". Backoff therefore lives in the engine's clock, not in a column.
///  * **no acked rows** — a drained mutation is deleted (`deleteByIds`), so
///    `status` only ever needs the three values `Mutation` defines, and "how
///    much is still unsent" is a count of one tiny table rather than a filter
///    over history.
part of '../../core/db/app_database.dart';

class OutboxDao extends KazamaDao {
  /// Append a mutation inside the caller's transaction. `onConflict:
  /// doNothing` on the UNIQUE `idempotency_key` is the whole deduplication
  /// story: replaying a half-failed local write cannot create a second mutation
  /// for one action, and no SELECT-then-INSERT race is possible because the
  /// constraint does the checking.
  Future<void> enqueueMutation(Mutation m) {
    return into(syncOutbox).insert(
      SyncOutboxCompanion.insert(
        id: m.id,
        entity: m.entity,
        entityId: m.entityId,
        op: m.op.wire,
        payloadJson: m.encodePayload(),
        idempotencyKey: m.idempotencyKey,
        deviceId: Value(m.deviceId),
        attempts: Value(m.attempts),
        status: Value(m.status.wire),
        queuedAt: m.queuedAt,
      ),
      onConflict: const DoNothing(),
    );
  }

  Future<List<Mutation>> pending({int limit = 50}) => (select(syncOutbox)
        ..where((t) => t.status.equals(SyncStatus.pending.wire))
        ..orderBy([(t) => t.queuedAt.asc()])
        ..limit(limit))
      .get()
      .then((rows) => rows.map(_toMutation).toList());

  /// Rows that exhausted their retries and are now visible as a badge. They are
  /// NOT retried by the loop (that is what "stuck" means) but are still pushed
  /// when a human presses Sync.
  Future<List<Mutation>> stuck() => (select(syncOutbox)
        ..where((t) => t.status.equals(SyncStatus.stuck.wire))
        ..orderBy([(t) => t.queuedAt.asc()]))
      .get()
      .then((rows) => rows.map(_toMutation).toList());

  Future<int> countPending() => _countWhere(syncOutbox.status.equals(SyncStatus.pending.wire));

  Future<int> countStuck() => _countWhere(syncOutbox.status.equals(SyncStatus.stuck.wire));


  Future<void> markInFlight(List<String> ids) {
    if (ids.isEmpty) return Future.value();
    return (update(syncOutbox)..where((t) => t.id.isIn(ids))).write(
      SyncOutboxCompanion(status: Value(SyncStatus.inFlight.wire)),
    );
  }

  /// A drained row is deleted, not flagged. The full history of what happened to
  /// a bill lives in `order_events` and in the snapshot; the outbox is a queue.
  Future<void> deleteByIds(List<String> ids) {
    if (ids.isEmpty) return Future.value();
    return (delete(syncOutbox)..where((t) => t.id.isIn(ids))).go();
  }

  /// Record a rejected batch: one statement to promote the rows that have run
  /// out of retries, one to count-and-requeue the rest. Two UPDATEs rather than
  /// a read-modify-write because `attempts + 1` and the `>=` test must see the
  /// *stored* value — a mutation enqueued while the batch was in flight would
  /// otherwise be able to lose a count. Raw SQL is deliberately not used: every
  /// other query in this app is the typed builder (SKILLS.md §C1).
  Future<void> applyFailure({required List<String> ids, required String error, required int maxAttempts}) async {
    if (ids.isEmpty) return;
    final attempts = syncOutbox.attempts;
    await (update(syncOutbox)..where((t) => t.id.isIn(ids))).write(
      SyncOutboxCompanion(
        status: const Value('stuck'), // SyncStatus.stuck.wire
        attempts: attempts + 1,
        lastError: Value(error),
      ),
      where: (t) => attempts + 1 >= maxAttempts,
    );
    await (update(syncOutbox)..where((t) => t.id.isIn(ids))).write(
      SyncOutboxCompanion(
        status: Value(SyncStatus.pending.wire),
        attempts: attempts + 1,
        lastError: Value(error),
      ),
      where: (t) => attempts + 1 < maxAttempts,
    );
  }

  /// Manual "try those again": a stuck row is a bug report, and the shopkeeper's
  /// fix is to give it one more life after the network came back.
  Future<void> requeueStuck() => (update(syncOutbox)..where((t) => t.status.equals(SyncStatus.stuck.wire))).write(
        const SyncOutboxCompanion(status: Value('pending'), attempts: Value(0), lastError: Value(null)),
      );

  /// A crash between `markInFlight` and the ack used to strand rows in
  /// `in_flight` forever — invisible to `pending()`, so the backlog sat there
  /// uncounted. `start()` releases them.
  Future<void> releaseInFlight() => (update(syncOutbox)..where((t) => t.status.equals(SyncStatus.inFlight.wire))).write(
        const SyncOutboxCompanion(status: Value('pending')),
      );

  Future<int> _countWhere(Expression<bool> where) async {
    final q = selectOnly(syncOutbox)..addColumns([syncOutbox.id.count()])..where(where);
    return (await q.getSingle()).read(syncOutbox.id.count()) ?? 0;
  }

  Mutation _toMutation(SyncOutbox row) => Mutation(
        id: row.id,
        entity: row.entity,
        entityId: row.entityId,
        op: MutationOp.fromWire(row.op),
        payload: Mutation.decodePayload(row.payloadJson),
        idempotencyKey: row.idempotencyKey,
        queuedAt: row.queuedAt,
        attempts: row.attempts,
        status: SyncStatus.fromWire(row.status),
        deviceId: row.deviceId,
        lastError: row.lastError,
      );
}
