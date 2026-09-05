/// The sync seam (Task T5). Deliberately an abstract interface with exactly one
/// v1 implementation (`NoopSyncGateway`), because v1 has no server: the point of
/// this file is that the *engine* — drain order, idempotency, retry, stuck rows
/// — is real and tested now, so the day a Supabase endpoint exists the change is
/// one new class and one provider line, not a retrofit into the sale path.
///
/// What the engine is allowed to assume about a gateway, and nothing more:
///  * a batch is *at-least-once*: the same `idempotencyKey` may be presented
///    again after an ambiguous failure, and a correct gateway answers "ok" for
///    the row it already stored rather than double-applying it;
///  * `acks` is the only proof of delivery. Anything not in `acks` stays in the
///    outbox untouched;
///  * a thrown error means "nothing happened" and costs one retry of the whole
///    batch — never a delete.
library;

import '../data/models/mutation.dart';

/// What one drain cycle sent, and what came back.
class SyncBatch {
  const SyncBatch({required this.mutations, required this.deviceId});

  final List<Mutation> mutations;
  final String deviceId;

  int get length => mutations.length;

  /// The wire body. Public so a real gateway and the fake gateway in tests build
  /// their request from the *same* structure — a bug that only exists because a
  /// test sent a prettier payload than the app does is the worst kind.
  Map<String, Object?> toJson() => {
    'deviceId': deviceId,
    'mutations': [for (final m in mutations) m.toJson()],
  };
}

class SyncAck {
  const SyncAck(this.idempotencyKey, {this.serverId, this.error});

  final String idempotencyKey;

  /// Optional: a gateway that assigns its own ids (a Supabase primary key) hands
  /// them back here. The engine writes nothing with it in v1; it exists so the
  /// mapping does not need a second round trip later.
  final String? serverId;

  /// A per-row rejection. `null` means accepted. A batch of 50 where one row is
  /// bad must not retry 49 good rows, so failures are reported per key.
  final String? error;

  bool get isAccepted => error == null;
}

abstract interface class SyncGateway {
  /// Human-readable name for the settings screen's sync status line.
  String get label;

  /// False for the noop gateway: the engine uses this to skip periodic work
  /// entirely rather than to run a timer that achieves nothing on a phone.
  bool get isRemote;

  Future<List<SyncAck>> push(SyncBatch batch);
}

/// v1's gateway: reports every row as accepted, so the outbox drains (rows are
/// deleted, which is what "drained" means here — see the note on
/// `Mutation.copyWith`). This is not a stub to be embarrassed about: it is the
/// component that proves the journal never leaks rows when nobody is listening.
class NoopSyncGateway implements SyncGateway {
  const NoopSyncGateway();

  @override
  String get label => 'local-only (no server configured)';

  @override
  bool get isRemote => false;

  @override
  Future<List<SyncAck>> push(SyncBatch batch) async => [
    for (final m in batch.mutations) SyncAck(m.idempotencyKey),
  ];
}

/// Failure text as stored in `sync_outbox.last_error`. Truncated on purpose: a
/// whole HTTP stack trace per row, times a 500-row backlog, times every retry,
/// is how a sync table becomes the largest table in the backup.
String syncErrorText(Object error) {
  final t = error is SyncRejectException ? error.message : '$error';
  final flat = t.replaceAll('\n', ' ').trim();
  return flat.length <= 240 ? flat : '${flat.substring(0, 237)}...';
}

/// Thrown by a gateway for a batch-level rejection (bad token, wrong schema
/// version, unsupported batch) where no row should be considered applied.
class SyncRejectException implements Exception {
  const SyncRejectException(this.message);

  final String message;

  @override
  String toString() => 'SyncRejectException: $message';
}
