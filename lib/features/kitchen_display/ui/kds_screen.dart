/// Kitchen display (Task K1-K4).
///
/// One rule shapes this whole screen: the kitchen is told what to COOK, never
/// what it costs. So the KDS reads tickets through the same repository but the
/// price column is absent by construction — not hidden with CSS. A screen that
/// renders a price and "hides" it is a screen where the price comes back in the
/// next release; a screen that never had the number cannot.
///
/// Timers are computed from `firedAt` at build time rather than from a ticking
/// provider, so nothing here needs a `Timer` (and a 9pm "why is it stuck at 3
/// minutes" is answered by the same elapsed figure the header shows).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../data/models/enums.dart';
import '../../../data/models/order.dart';
import '../../../data/models/order_line.dart';

final StreamProvider<List<OrderTicket>> kitchenTicketsProvider =
    StreamProvider<List<OrderTicket>>((ref) => ref.watch(orderRepositoryProvider).watchKitchenTickets());

/// Minutes a dish has been waiting. `kitchen` (the role that watches this) has no
/// money rights, so this file is allowed to be the only place the wait time is
/// derived — a report with a different formula would argue with the cook.
int waitedMinutes(OrderTicket t, {DateTime? now}) {
  final from = t.firedAt ?? t.openedAt;
  return (now ?? DateTime.now()).difference(from).inMinutes;
}

const int kLateAfterMinutes = 12;

class KdsScreen extends ConsumerWidget {
  const KdsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tickets = ref.watch(kitchenTicketsProvider);
    final me = ref.watch(currentSessionProvider);
    final canCook = me.roleName == 'Kitchen' || me.roleName == 'Manager' || me.roleName == null;
    return Scaffold(
      body: tickets.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (rows) {
          final pending = rows.where((t) => t.lines.any((l) => !l.isFullyCancelled && l.status != LineStatus.served)).toList();
          if (pending.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle_outline, size: 42),
                  const SizedBox(height: 8),
                  Text('Kitchen is clear', style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              for (final t in pending) _KdsTicketCard(ticket: t, canAct: canCook),
            ],
          );
        },
      ),
    );
  }
}

class _KdsTicketCard extends ConsumerWidget {
  const _KdsTicketCard({required this.ticket, required this.canCook});

  final OrderTicket ticket;
  final bool canCook;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mins = waitedMinutes(ticket);
    final late = mins >= kLateAfterMinutes;
    final lines = [for (final l in ticket.lines) if (!l.isFullyCancelled && l.status != LineStatus.served) l];
    final allReady = lines.every((l) => l.status == LineStatus.ready);
    return Card(
      // A tinted container, not an opacity hack: `withOpacity` is deprecated in
      // 3.27 and `withValues` is missing in 3.24, and a UI that fails to compile
      // over a colour tweak is the worst possible trade (R5).
      color: late ? theme.colorScheme.errorContainer : null,
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  ticket.tableOrName ?? (ticket.billNumber == null ? ticket.id : 'Bill ${ticket.billNumber}'),
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(width: 10),
                Text(ticket.type.label, style: theme.textTheme.bodySmall),
                const Spacer(),
                // The wait is the only clock a cook needs, so it is big and it
                // turns red — labelled `LATE`, never red-only (colour-blind and
                // sunlight-readable: U3).
                Text(
                  late ? '$mins min  LATE' : '$mins min',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: late ? theme.colorScheme.error : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 36, child: Text('${l.liveQuantity}×', style: theme.textTheme.titleMedium)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // The KITCHEN label, not the menu name: "VEG BURGER 2×"
                          // on a ticket stub is faster to read than a styled dish
                          // name, and it is snapshotted so a rename cannot
                          // confuse a cook mid-service (O2/K1).
                          Text(
                            l.status == LineStatus.ready
                                ? '${l.kitchenLabel ?? l.nameSnapshot}  (ready)'
                                : (l.kitchenLabel ?? l.nameSnapshot),
                            style: theme.textTheme.titleMedium,
                          ),
                          for (final m in l.modifiers) Text('+ ${m.name}', style: theme.textTheme.bodyMedium),
                          if (l.note != null && l.note!.isNotEmpty)
                            Text(l.note!, style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: l.status == LineStatus.ready ? 'Served' : 'Mark ready',
                      onPressed: !canCook
                          ? null
                          : () => _tick(context, ref, l),
                      icon: Icon(
                        l.status == LineStatus.ready ? Icons serve_outlined : Icons.check_circle_outline,
                        color: l.status == LineStatus.ready ? theme.colorScheme.primary : null,
                      ),
                    ),
                  ],
                ),
              ),
            const Divider(height: 16),
            Row(
              children: [
                Text(
                  ticket.status == OrderStatus.ready ? 'Ready to pick up' : 'Cooking',
                  style: theme.textTheme.bodySmall,
                ),
                const Spacer(),
                if (allReady)
                  FilledButton.icon(
                    onPressed: canCook
                        ? () async {
                            try {
                              await ref.read(orderRepositoryProvider).markTicketReady(ticketId: ticket.id);
                              if (context.mounted) showSnack(context, '${ticket.tableOrName ?? 'Bill'} marked ready');
                            } catch (e) {
                              if (context.mounted) showSnack(context, '$e', error: true);
                            }
                          }
                        : null,
                    icon: const Icon(Icons.bolt),
                    label: const Text('Ready all'),
                  )
                else
                  Text('${lines.where((l) => l.status == LineStatus.ready).length}/${lines.length} ready',
                      style: theme.textTheme.bodySmall),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _tick(BuildContext context, WidgetRef ref, TicketLine l) async {
    try {
      if (l.status == LineStatus.ready) {
        await ref.read(orderRepositoryProvider).serve(
              ticketId: ticket.id,
              actorId: ref.read(currentSessionProvider).userId ?? 'kitchen',
            );
      } else {
        await ref.read(orderRepositoryProvider).markLineReady(ticketId: ticket.id, lineId: l.id);
      }
    } catch (e) {
      if (context.mounted) showSnack(context, '$e', error: true);
    }
  }
}
