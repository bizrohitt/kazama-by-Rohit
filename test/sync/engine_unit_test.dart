// Task T5 — the parts of the drain loop that are pure functions, plus the wire
// contract both a real and a fake gateway must satisfy.
// Run: flutter test test/sync/engine_unit_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:kazama_pos/data/models/mutation.dart';
import 'package:kazama_pos/sync/sync_engine.dart';
import 'package:kazama_pos/sync/sync_gateway.dart';

Mutation m(int n) => Mutation(
      id: 'id$n',
      entity: 'order',
      entityId: 'o$n',
      op: MutationOp.update,
      payload: {'n': n},
      idempotencyKey: 'k$n',
      queuedAt: DateTime.utc(2026, 9, 5, 12).add(Duration(minutes: n)),
    );

void main() {
  group('backoffFor', () {
    const schedule = [Duration(seconds: 2), Duration(seconds: 10), Duration(minutes: 5)];

    test('attempt N waits the Nth entry', () {
      expect(backoffFor(1, schedule), const Duration(seconds: 2));
      expect(backoffFor(2, schedule), const Duration(seconds: 10));
      expect(backoffFor(3, schedule), const Duration(minutes: 5));
    });

    test('the schedule caps rather than growing unbounded', () {
      // The property that matters on a phone: a day-long outage must not produce
      // a 40-day wait or a 1-second burst, just the last interval forever.
      expect(backoffFor(4, schedule), const Duration(minutes: 5));
      expect(backoffFor(1000, schedule), const Duration(minutes: 5));
    });

    test('attempt zero and negative do not index off the front', () {
      expect(backoffFor(0, schedule), const Duration(seconds: 2));
      expect(backoffFor(-3, schedule), const Duration(seconds: 2));
    });

    test('an empty schedule means no waiting, not a crash', () {
      expect(backoffFor(1, const []), Duration.zero);
    });
  });

  group('syncErrorText', () {
    test('flattens newlines so one cell of the badge stays readable', () {
      expect(syncErrorText(StateError('line1\nline2')), 'line1 line2');
    });

    test('truncates long errors — a stack trace per row would outgrow the DB', () {
      final long = 'x' * 5000;
      final out = syncErrorText(Exception(long));
      expect(out.length, lessThanOrEqualTo(241));
      expect(out, endsWith('...'));
    });

    test('a SyncRejectException keeps its own message, not the class name', () {
      expect(syncErrorText(const SyncRejectException('token expired')), 'token expired');
    });
  });

  group('SyncBatch/SyncAck contract', () {
    test('a batch carries the device id and every row verbatim', () {
      final batch = SyncBatch(mutations: [m(1), m(2)], deviceId: 'tillo');
      final json = batch.toJson();
      expect(json['deviceId'], 'tillo');
      final rows = (json['mutations']! as List).cast<Map<String, Object?>>();
      expect(rows.map((r) => r['idempotencyKey']), ['k1', 'k2']);
      expect(rows.first['op'], 'UPDATE'); // the wire vocabulary, not the enum name
    });

    test('an ack with an error is not an ack', () {
      expect(const SyncAck('k1').isAccepted, isTrue);
      expect(const SyncAck('k1', error: 'nope').isAccepted, isFalse);
    });

    test('the noop gateway accepts exactly what it was given', () async {
      const gateway = NoopSyncGateway();
      expect(gateway.isRemote, isFalse);
      final acks = await gateway.push(SyncBatch(mutations: [m(1), m(2), m(3)], deviceId: 'd'));
      expect(acks.map((a) => a.idempotencyKey), ['k1', 'k2', 'k3']);
      expect(acks.every((a) => a.isAccepted), isTrue);
    });
  });

  group('Mutation ageing', () {
    test('the last attempt is the one that turns a row stuck', () {
      var mut = m(1);
      for (var i = 1; i < Mutation.maxAttempts; i++) {
        mut = mut.markFailed('e$i');
        expect(mut.status, SyncStatus.pending, reason: 'attempt $i must stay retryable');
      }
      mut = mut.markFailed('boom');
      expect(mut.status, SyncStatus.stuck);
      expect(mut.shouldRetry, isFalse);
    });
  });
}
