/// One-line outbox writes for repositories that are not ticket mutators (T5).
///
/// `TicketMutator.journal` does the same job for the order/payment path, where a
/// ticket payload is already at hand; this free function exists so a *second*
/// writer (credit settlement, and later any feature that gains sync) does not
/// copy the id/idempotency-key construction. Duplicated here it would be two
/// places to get the key format wrong — and a key format that changes makes every
/// row queued before the upgrade look like a different sale to the server.
library;

import '../../../core/db/app_database.dart';
import '../../../core/utils/id.dart';
import '../../models/mutation.dart';

Future<void> journalMutation(
  AppDatabase db,
  IdFactory ids, {
  required String entity,
  required String entityId,
  required MutationOp op,
  required Map<String, Object?> payload,
  DateTime? at,
}) {
  final when = at ?? DateTime.now();
  return db.enqueueMutation(Mutation(
    id: ids.newId(),
    entity: entity,
    entityId: entityId,
    op: op,
    payload: payload,
    idempotencyKey: '$entity:$entityId:${op.name}:${when.microsecondsSinceEpoch}',
    queuedAt: when,
  ));
}
