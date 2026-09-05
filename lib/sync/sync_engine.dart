/// The drain loop (Task T5).
///
/// One job: move rows from `sync_outbox` to the gateway and delete the ones that
/// came back acked. Everything else in the app is written as if there were no
/// network, and this file must never make that assumption visible.
///
/// The four properties the tests pin:
///  1. **A row is deleted only on an explicit ack.** A thrown error, a partial
///     ack list or a `SyncAck.error` all leave the row alone. A sale can be lost
///     only if its mutation disappears, so this is the one line in this file that
///     is not allowed to be clever.
///  2. **One cycle at a time.** `flush()` may be called from a timer, from the
///     resume path and from a button at the same moment; overlapping cycles would
///     double-send and then both "succeed". Re-entrance is folded into a single
///     follow-up pass (`_again`) rather than dropped, so a burst of edits during a
///     slow upload still gets sent.
///  3. **Retry is bounded and spaced.** Attempts increment on each rejected batch
///     until `Mutation.maxAttempts` turns a row `stuck`; the loop's own spacing is
///     [backoffSchedule], capped at its last entry so a dead network costs one
///     request per long interval instead of a burst that also flattens the battery.
///  4. **`in_flight` is only released at boot**, never inside the loop — see the
///     comment on [start].
library;

import 'dart:async';

import '../data/daos/outbox_dao.dart';
import '../data/models/mutation.dart';
import 'sync_gateway.dart';

/// Pure function, public for its own test: attempt N waits `schedule[N-1]`, and
/// anything past the end waits the last entry forever.
Duration backoffFor(int attempts, List<Duration> schedule) {
  if (schedule.isEmpty) return Duration.zero;
  final i = attempts <= 0 ? 0 : attempts - 1;
  return schedule[i >= schedule.length ? schedule.length - 1 : i];
}

/// A cycle's result, shaped for the one line of UI it feeds.
class SyncCycle {
  const SyncCycle({this.sent = 0, this.rejected = 0, this.failed = 0, this.backlog = 0, this.error});

  /// Rows the gateway acked, and which are therefore now deleted.
  final int sent;

  /// Rows the gateway answered "no" to (still retryable).
  final int rejected;

  /// Whole-batch failure, i.e. rows left for the next cycle.
  final int failed;

  final int backlog;

  /// Last error text, for the badge's tooltip. Never a stack trace.
  final String? error;

  bool get clean => sent > 0 && rejected == 0 && failed == 0;

  @override
  String toString() => 'SyncCycle(sent: $sent, rejected: $rejected, failed: $failed, backlog: $backlog)';
}

class SyncEngine {
  SyncEngine({
    required this.outbox,
    required this.gateway,
    this.deviceId = 'primary',
    List<Duration>? backoff,
    Duration? pollInterval,
    Future<void> Function()? beforeCycle,
    void Function(SyncCycle)? onCycle,
  })  : backoffSchedule = backoff ?? const [
          Duration(seconds: 2),
          Duration(seconds: 10),
          Duration(seconds: 60),
          Duration(minutes: 5),
          Duration(minutes: 30),
          Duration(hours: 2),
        ],
        // With no remote gateway there is nothing to poll: the noop gateway's
        // purpose is to drain on demand, not to wake the phone every five minutes
        // to delete rows that never went anywhere.
        pollInterval = pollInterval ?? (gateway.isRemote ? const Duration(minutes: 5) : null),
        beforeCycle = beforeCycle,
        onCycle = onCycle;

  final OutboxDao outbox;
  final SyncGateway gateway;

  /// v1 has one till, so one device id. A constructor field rather than a lookup:
  /// a server's key is `(deviceId, billNumber)`, and a value re-read mid-batch is
  /// how two batches end up claiming to be different devices.
  final String deviceId;

  final List<Duration> backoffSchedule;
  final Duration? pollInterval;

  /// Test seam: a fake can advance a virtual clock here instead of the loop really
  /// sleeping 30 minutes during `flutter test`.
  final Future<void> Function()? beforeCycle;
  final void Function(SyncCycle)? onCycle;

  bool _running = false;
  bool _again = false;
  Timer? _timer;
  int _consecutiveFailures = 0;
  String? _lastError;
  SyncCycle? _lastCycle;

  /// The last completed cycle, for the settings screen's one-line status. Not a
  /// stream: a sync status row that animates is a distraction at a counter, and
  /// the screen showing it is opened deliberately, once a day.
  SyncCycle? get lastCycle => _lastCycle;

  int get consecutiveFailures => _consecutiveFailures;
  String? get lastError => _lastError;
  bool get isPolling => _timer != null;

  /// Rows still waiting to go out — the badge's number.
  Future<int> get unsyncedCount => outbox.countPending();

  /// How long to wait after `attempts` failures. Exposed for the settings screen
  /// ("retrying in 5 min") and asserted directly by a test.
  Duration nextDelay(int attempts) => backoffFor(attempts, backoffSchedule);

  /// Called once when the app starts, not per cycle. The release of stranded
  /// `in_flight` rows belongs here: doing it at the top of every cycle would
  /// un-lease the rows a *slow* in-progress upload is still holding, which is a
  /// double-send waiting to happen the first time the network is slow.
  void start() {
    unawaited(outbox.releaseInFlight());
    final interval = pollInterval;
    if (interval == null) return;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(flush()));
    unawaited(flush());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Called from the app's resume path and from the settings screen's Sync button.
  /// Idempotent: a call while a cycle is running only promises a follow-up pass.
  Future<void> flush() async {
    if (_running) {
      _again = true;
      return;
    }
    await _cycle();
  }

  /// One more life for the rows that gave up. Only a human should press this: the
  /// loop's silence about stuck rows is the point of `stuck`.
  Future<void> retryStuck() async {
    await outbox.requeueStuck();
    await flush();
  }

  Future<void> _cycle() async {
    _running = true;
    var sent = 0, rejected = 0, failed = 0;
    try {
      final batch = await outbox.pending(limit: 50);
      if (batch.isEmpty) {
        _consecutiveFailures = 0;
        return;
      }
      await outbox.markInFlight([for (final m in batch) m.id]);
      try {
        await beforeCycle?.call();
        final acks = await gateway.push(SyncBatch(mutations: batch, deviceId: deviceId));
        final byKey = {for (final a in acks) a.idempotencyKey: a};
        final ok = <String>[];
        // Every row that did not come back *accepted* — refused explicitly, or
        // simply not answered at all — goes through the one failure path. Two
        // paths would mean two places to lose a count, and an unanswered row that
        // never ages is a row that never shows up as stuck.
        final notOk = <String>[];
        String? firstError;
        for (final m in batch) {
          final ack = byKey[m.idempotencyKey];
          if (ack != null && ack.isAccepted) {
            ok.add(m.id);
          } else {
            notOk.add(m.id);
            firstError ??= ack?.error ?? 'server did not acknowledge this row';
            if (ack != null) rejected++;
          }
        }
        sent = ok.length;
        // The delete and the requeue are one step in the caller's eyes, but two
        // statements: an ack must never be lost because a sibling row was
        // rejected by the server.
        await outbox.deleteByIds(ok);
        if (notOk.isNotEmpty) {
          await outbox.applyFailure(
            ids: notOk,
            error: syncErrorText(firstError!),
            maxAttempts: Mutation.maxAttempts,
          );
        }
        _consecutiveFailures = sent > 0 ? 0 : _consecutiveFailures + 1;
        if (sent > 0) _lastError = null;
      } catch (e) {
        // A throw means "the request never landed": every row in the batch is
        // still unsent, so all of them age by one attempt and none are deleted.
        failed = batch.length;
        _lastError = syncErrorText(e);
        _consecutiveFailures++;
        await outbox.applyFailure(
          ids: [for (final m in batch) m.id],
          error: _lastError!,
          maxAttempts: Mutation.maxAttempts,
        );
      }
    } finally {
      _running = false;
      final backlog = await _safeCount();
      final cycle = SyncCycle(sent: sent, rejected: rejected, failed: failed, backlog: backlog, error: _lastError);
      _lastCycle = cycle;
      onCycle?.call(cycle);
      if (_again) {
        _again = false;
        unawaited(_cycle());
      }
    }
  }

  Future<int> _safeCount() async {
    try {
      return await outbox.countPending();
    } catch (_) {
      return -1; // the badge shows nothing rather than throwing over a counter
    }
  }
}
