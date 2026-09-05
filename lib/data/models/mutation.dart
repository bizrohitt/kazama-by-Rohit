/// Outbox mutation row (Task T2 — the *shape*; the engine is T5).
///
/// Every business write is journalled here inside the same transaction as the
/// write itself (SKILLS.md §C1). v1 ships a `NoopSyncGateway`, so these rows
/// accumulate, drain, and delete — the machinery is exercised and tested even
/// though there is no server yet, which is the whole point of building the seam now.
library;

import 'dart:convert';

import 'enums.dart';

final class Mutation {
  const Mutation({
    required this.id,
    required this.entity,
    required this.entityId,
    required this.op,
    required this.payload,
    required this.idempotencyKey,
    required this.queuedAt,
    this.attempts = 0,
    this.status = SyncStatus.pending,
    this.deviceId = 'primary',
    this.lastError,
  });

  final String id;

  /// Logical table name: `order`, `payment`, `menuItem`, `stockMovement`.
  final String entity;
  final String entityId;
  final MutationOp op;

  /// The full post-write row as a JSON map, so a replay on the server needs no
  /// join and no second read (which would race with the next edit).
  final Map<String, Object?> payload;

  /// Client-generated uuid. A re-send of the same key must be a no-op server-side,
  /// which is the only reason an offline retry can never double-post a sale.
  final String idempotencyKey;
  final DateTime queuedAt;

  /// Rows that fail 10 times go `stuck` and surface a badge instead of retrying
  /// forever; the data is still on-device, so a stuck row is a bug report, not a lost sale.
  final int attempts;
  final SyncStatus status;

  /// Local bill numbers are unique per device (SKILLS.md §C2); a second till in
  /// v2 makes `(deviceId, billNumber)` the real key.
  final String deviceId;
  final String? lastError;

  static const int maxAttempts = 10;

  bool get isPending => status == SyncStatus.pending;
  bool get shouldRetry => isPending && attempts < maxAttempts;

  Mutation markFailed(String error) => copyWith(
    attempts: attempts + 1,
    status: attempts + 1 >= maxAttempts ? SyncStatus.stuck : SyncStatus.pending,
    lastError: error,
  );

  Mutation markInFlight() => copyWith(status: SyncStatus.inFlight);
  /// A drained row is *deleted*, not flagged done — that keeps the table small
  /// and makes "pending" the only state that needs an index (T5).
  Mutation copyWith({
    int? attempts,
    SyncStatus? status,
    String? lastError,
  }) => Mutation(
    id: id,
    entity: entity,
    entityId: entityId,
    op: op,
    payload: payload,
    idempotencyKey: idempotencyKey,
    queuedAt: queuedAt,
    attempts: attempts ?? this.attempts,
    status: status ?? this.status,
    deviceId: deviceId,
    lastError: lastError ?? this.lastError,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'entity': entity,
    'entityId': entityId,
    'op': op.wire,
    'payload': payload,
    'idempotencyKey': idempotencyKey,
    'queuedAt': queuedAt.toIso8601String(),
    'attempts': attempts,
    'status': status.wire,
    'deviceId': deviceId,
    'lastError': lastError,
  };

  factory Mutation.fromJson(Map<String, Object?> j) => Mutation(
    id: j['id']! as String,
    entity: j['entity']! as String,
    entityId: j['entityId']! as String,
    op: MutationOp.fromWire(j['op'] as String?),
    payload: (j['payload'] as Map<String, Object?>?) ?? const <String, Object?>{},
    idempotencyKey: j['idempotencyKey']! as String,
    queuedAt: DateTime.parse(j['queuedAt']! as String),
    attempts: (j['attempts'] as int?) ?? 0,
    status: SyncStatus.fromWire(j['status'] as String?),
    deviceId: (j['deviceId'] as String?) ?? 'primary',
    lastError: j['lastError'] as String?,
  );

  /// The exact string a `TEXT` column holds. Kept here so T3's drift DAO and
  /// T5's engine cannot disagree about encoding.
  String encodePayload() => jsonEncode(payload);
  static Map<String, Object?> decodePayload(String raw) =>
      jsonDecode(raw) as Map<String, Object?>;

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is Mutation &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.entity == entity &&
      other.entityId == entityId &&
      other.op == op &&
      deepEquals(other.payload, payload) &&
      other.idempotencyKey == idempotencyKey &&
      other.queuedAt == queuedAt &&
      other.attempts == attempts &&
      other.status == status &&
      other.deviceId == deviceId &&
      other.lastError == lastError;

  @override
  int get hashCode => Object.hashAll([
      id.hashCode,
      entity.hashCode,
      entityId.hashCode,
      op.hashCode,
      deepHash(payload),
      idempotencyKey.hashCode,
      queuedAt.hashCode,
      attempts.hashCode,
      status.hashCode,
      deviceId.hashCode,
      lastError.hashCode,
    ]);
}
