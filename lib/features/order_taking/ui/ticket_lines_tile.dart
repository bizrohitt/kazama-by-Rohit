/// One line on a ticket: quantity, note, partial cancel (Task O5/O6).
///
/// The row is a *presentation* of `TicketLine` plus the three actions the model
/// already allows. Note what it cannot do: edit a price, rename a dish, or
/// remove the row. Prices are snapshotted at add time (O2) so a menu change
/// cannot rewrite a bill in progress, and a line is CANCELLED rather than
/// deleted because "the customer returned 1 of 3" is information a shop needs
/// (O6) — `liveQuantity` keeps it visible instead of pretending it never happened.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/providers.dart';
import '../../../data/models/order.dart';
import '../../../data/models/order_line.dart';

class TicketLineTile extends ConsumerWidget {
  const TicketLineTile({
    super.key,
    required this.ticketId,
    required this.line,
    required this.locked,
  });

  final String ticketId;
  final TicketLine line;
  final bool locked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cancelled = line.cancelledQuantity;
    final theme = Theme.of(context);
    final done = ref.read(currentSessionProvider).userId ?? 'system';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
        child: Row(
          children: [
            _QtyStepper(
              value: line.quantity,
              enabled: !locked,
              onChanged: (v) => ref.read(orderRepositoryProvider).setQuantity(ticketId: ticketId, lineId: line.id, quantity: v),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.nameSnapshot,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      // Struck through, but STILL SHOWN: a cancelled dish is part
                      // of what the customer was told, and an invisible line is
                      // a line a manager cannot audit (O6).
                      decoration: line.isFullyCancelled ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  if (line.modifiers.isNotEmpty)
                    Text(
                      line.modifiers.map((m) => m.name).join(', '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        decoration: line.isFullyCancelled ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  if (line.note != null && line.note!.isNotEmpty)
                    Text('Note: ${line.note}', style: theme.textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic)),
                  if (cancelled > 0 && !line.isFullyCancelled)
                    Text('$cancelled of ${line.quantity} cancelled', style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  rupeesText(line.lineTotal),
                  style: theme.textTheme.titleMedium?.copyWith(
                    decoration: line.isFullyCancelled ? TextDecoration.lineThrough : null,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Note for the kitchen',
                      onPressed: locked ? null : () => _editNote(context, ref),
                      icon: Icon(line.note == null ? Icons.note_add_outlined : Icons.note_outlined, size: 20),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: cancelled > 0 ? 'Restore this line' : 'Cancel line',
                      onPressed: locked
                          ? null
                          : () => cancelled > 0
                              ? ref.read(orderRepositoryProvider).uncancelLine(
                                  ticketId: ticketId, lineId: line.id, actorId: done)
                              : ref.read(orderRepositoryProvider).cancelLine(
                                  ticketId: ticketId, lineId: line.id, actorId: done),
                      icon: Icon(cancelled > 0 ? Icons.undo : Icons.remove_circle_outline, size: 20),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editNote(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: line.note ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Kitchen note - ${line.nameSnapshot}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 2,
          maxLength: 120,
          decoration: const InputDecoration(hintText: 'e.g. no onion, extra spicy'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, ''), child: const Text('Clear')),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text), child: const Text('Save')),
        ],
      ),
    );
    if (value == null) return;
    await ref.read(orderRepositoryProvider).setLineNote(ticketId: ticketId, lineId: line.id, note: value);
  }
}

/// The +/- control. Deliberately NOT a `DropdownButton`: at a counter, tapping a
/// number twice to reach 3 costs a second per line, and a stepper cannot produce
/// an invalid quantity because the repo refuses it anyway (min 1).
class _QtyStepper extends StatelessWidget {
  const _QtyStepper({required this.value, required this.enabled, required this.onChanged});

  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: enabled ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add_circle_outline, size: 22),
        ),
        Text('$value', style: Theme.of(context).textTheme.titleMedium),
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: enabled && value > 1 ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove_circle_outline, size: 22),
        ),
      ],
    );
  }
}

/// Bill summary + the order-taking screen's only two "send it" actions.
class TicketFooter extends ConsumerWidget {
  const TicketFooter({super.key, required this.ticket});

  final OrderTicket ticket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ticket.totals;
    final hasPending = ticket.lines.any((l) => l.status.isFireable && !l.isFullyCancelled);
    return Material(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${ticket.lineCount} line(s)   ·   ${rupeesText(t.lineBase)} base   ·   '
                    '${rupeesText(t.discount)} off   ·   ${rupeesText(t.tax)} tax',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Text('TOTAL ${rupeesText(t.total)}', style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    // Fire sends the PENDING lines to the kitchen and (via the
                    // hook in providers.dart) deducts stock once per ticket (I2).
                    onPressed: !hasPending
                        ? null
                        : () async {
                            try {
                              await ref.read(orderRepositoryProvider).fire(
                                ticketId: ticket.id,
                                actorId: ref.read(currentSessionProvider).userId ?? 'system',
                              );
                              if (context.mounted) showSnack(context, 'Sent to kitchen');
                            } catch (e) {
                              if (context.mounted) showSnack(context, '$e', error: true);
                            }
                          },
                    icon: const Icon(Icons.local_fire_department_outlined),
                    label: Text(hasPending ? 'Fire to kitchen' : 'Nothing pending'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    // Held, not settled: the Q4 flow means a dine-in ticket can
                    // sit here for an hour, and the only way back to it is the
                    // held list on the left.
                    onPressed: () {
                      ref.read(activeTicketIdProvider.notifier).state = null;
                      showSnack(context, 'Bill held - find it in the list');
                    },
                    icon: const Icon(Icons.pause_outlined),
                    label: const Text('Hold bill'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
