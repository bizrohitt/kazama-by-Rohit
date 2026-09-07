/// Billing / payment screen (Task Y1-Y4) — the "come to the counter to pay"
/// half of the Q4 split. It writes PAYMENTS and nothing else: no lines, no
/// menu, no prices. The line list here is read-only on purpose; a cashier who
/// can change a bill while taking money for it is how a till ends up with a
/// paid bill whose total moved afterwards.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/number_pad.dart';
import '../../../core/money/money.dart';
import '../../../core/providers.dart';
import '../../../data/models/enums.dart';
import '../../../data/models/order.dart';
import '../../../data/models/payment.dart';
import '../../../features/printing/queue/printing_service.dart';

class BillingScreen extends ConsumerStatefulWidget {
  const BillingScreen({super.key});

  @override
  ConsumerState<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends ConsumerState<BillingScreen> {
  /// The panel's failures land here, on the parent, so that a failed tender is
  /// cleared by the next successful one automatically: the panel rebuilds with a
  /// fresh `widget.lastError == null` instead of keeping a red line on screen
  /// after the customer has already paid.
  String? _lastError;

  @override
  Widget build(BuildContext context) {
    // `previousValue` is what makes "the bill stays on screen after it is paid"
    // work: the provider re-reads a settled ticket, and while that read is in
    // flight the old tree must NOT be replaced by the due list (a one-frame flash
    // of a different screen mid-payment is how a cashier taps the wrong bill).
    final async = ref.watch(activeTicketProvider);
    // Loading is NOT null: `hasValue == false` while a refresh is in flight means
    // "keep showing what was there", and only a *completed* read of null means
    // "this bill is gone from the till" (deleted, or never existed).
    final ticket = async.hasValue ? async.value : async.previousValue;
    if (ticket == null) {
      return const _DueList();
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 5,
          child: _TicketSummary(ticket: ticket, onError: (m) => setState(() => _lastError = m)),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 4,
          child: _PayPanel(
            ticket: ticket,
            lastError: _lastError,
            onError: (m) => setState(() => _lastError = m),
          ),
        ),
      ],
    );
  }
}

/// Read-only view of what is being paid for, plus the reprint affordance.
class _TicketSummary extends ConsumerWidget {
  const _TicketSummary({required this.ticket, required this.onError});

  final OrderTicket ticket;
  final ValueChanged<String> onError;

  Future<void> _reprintKot(BuildContext context, WidgetRef ref) async {
    try {
      final out = await ref.read(printingProvider).printTicket(
        ticketId: ticket.id,
        kind: ReceiptKind.kitchen,
      );
      if (context.mounted) {
        onError(out.delivered
            ? 'Kitchen slip reprinted'
            : 'Printer did not answer: ${out.error ?? 'queued for retry'}');
      }
    } catch (e) {
      if (context.mounted) onError('$e');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ticket.totals;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${ticket.type.label}'
                  '${ticket.tableOrName == null ? '' : '  ·  ${ticket.tableOrName}'}'
                  '${ticket.billNumber == null ? '' : '  ·  Bill ${ticket.billNumber}'}',
                  style: theme.textTheme.titleLarge,
                ),
              ),
              // The kitchen reprint lives here rather than on the KDS because the
              // person who notices a missing slip is the cashier, not the cook, and
              // the two reasons differ: "printer jammed" vs "I never saw it".
              if (ticket.firedAt != null)
                TextButton(
                  onPressed: () => _reprintKot(context, ref),
                  child: const Text('Reprint KOT'),
                ),
              TextButton(
                onPressed: () => settleActiveTicket(ref),
                child: const Text('Pick another'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final l in ticket.lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Text('${l.quantity}×', style: theme.textTheme.bodyLarge),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          l.isFullyCancelled
                              ? '${l.nameSnapshot} (CANCELLED)'
                              : [
                                  l.nameSnapshot,
                                  for (final m in l.modifiers) m.name,
                                  if (l.note != null && l.note!.isNotEmpty) '* ${l.note}',
                                ].join('  ·  '),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            decoration: l.isFullyCancelled ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                      Text(
                        rupeesText(l.lineTotal),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          decoration: l.isFullyCancelled ? TextDecoration.lineThrough : null,
                        ),
                      ),
                    ],
                  ),
                ),
              const Divider(height: 20),
              _KV('Base', rupeesText(t.lineBase)),
              if (t.discount.isPositive) _KV('Discount', '-${rupeesText(t.discount)}'),
              _KV('GST (incl.)', rupeesText(t.tax)),
              if (!t.rounding.isZero) _KV('Rounding', rupeesText(Money(t.rounding.paise.abs()))),
              _KV('TOTAL', rupeesText(t.total), big: true),
              _KV('Paid', rupeesText(ticket.paid)),
              _KV('DUE', rupeesText(ticket.due), big: true, error: ticket.due.isPositive),
              const SizedBox(height: 8),
              FutureBuilder<List<Payment>>(
                future: ref.read(paymentRepositoryProvider).paymentsFor(ticket.id),
                builder: (context, snap) {
                  final rows = snap.data ?? const <Payment>[];
                  if (rows.isEmpty) return const SizedBox.shrink();
                  return Column(
                    children: [
                      const Divider(height: 16),
                      for (final p in rows)
                        Row(
                          children: [
                            Text(p.mode.label, style: theme.textTheme.bodySmall),
                            const Spacer(),
                            Text(rupeesText(p.amount), style: theme.textTheme.bodySmall),
                            if (p.change != null && p.change!.isPositive)
                              Text('  change ${rupeesText(p.change!)}', style: theme.textTheme.bodySmall),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: 'Reprint this slip',
                              icon: const Icon(Icons.print_outlined, size: 18),
                              onPressed: () async {
                                try {
                                  final out = await ref.read(printingProvider).printTicket(
                                    ticketId: ticket.id,
                                    kind: ReceiptKind.copy,
                                  );
                                  if (context.mounted) {
                                    onError(out.delivered ? 'Reprint sent' : 'Printer did not answer: ${out.error}');
                                  }
                                } catch (e) {
                                  if (context.mounted) onError('$e');
                                }
                              },
                            ),
                          ],
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _KV extends StatelessWidget {
  const _KV(this.k, this.v, {this.big = false, this.error = false});

  final String k;
  final String v;
  final bool big;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = big ? theme.textTheme.titleLarge! : theme.textTheme.bodyMedium!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Text(k, style: base.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const Spacer(),
          Text(v, style: base.copyWith(fontWeight: FontWeight.w700, color: error ? theme.colorScheme.error : null)),
        ],
      ),
    );
  }
}

/// The tender pad: mode, amount, then one write through the repository.
class _PayPanel extends ConsumerStatefulWidget {
  const _PayPanel({required this.ticket, required this.lastError, required this.onError});

  final OrderTicket ticket;
  final String? lastError;
  final ValueChanged<String?> onError;

  @override
  ConsumerState<_PayPanel> createState() => _PayPanelState();
}

class _PayPanelState extends ConsumerState<_PayPanel> {
  PaymentMode _mode = PaymentMode.cash;
  late DigitBuffer _amount = DigitBuffer(maxLength: 9, allowDecimal: true, onChange: () => setState(() {}));
  bool _busy = false;

  /// Rupees typed as `100` or `100.50`; the buffer is decimal-only so paise
  /// cannot be typed by hand, and `Money.rupees` rounds half-up on conversion.
  Money get _typed => _amount.isEmpty ? Money.zero : Money.rupees(num.tryParse(_amount.text) ?? 0);

  bool get _isCash => _mode == PaymentMode.cash;

  /// For cash the typed figure is what was HANDED OVER (tender), and the bill is
  /// what is applied — that is the shape of a real counter: "of the ₹500 note you
  /// took, ₹330 paid the bill". For UPI/card the typed figure is the applied
  /// amount, because there is no tender concept to reconcile (Y1).
  Money get _applied {
    if (!_isCash) return _typed;
    if (_typed.isZero) return widget.ticket.due;
    final due = widget.ticket.due;
    return _typed.paise >= due.paise ? due : _typed;
  }

  Money get _change => _isCash && _typed > _applied ? _typed - _applied : Money.zero;


  Future<void> _pay() async {
    setState(() {
      _busy = true;
      widget.onError(null);
    });
    String? error;
    try {
      final done = await ref.read(orderRepositoryProvider).recordPayment(
        ticketId: widget.ticket.id,
        mode: _mode,
        amount: _applied,
        tendered: _isCash ? _typed : null,
        reference: _mode == PaymentMode.cash ? null : _refText.text.trim().isEmpty ? null : _refText.text.trim(),
        actorId: ref.read(currentSessionProvider).userId ?? 'system',
        creditParty: _mode == PaymentMode.credit ? _partyText.text.trim() : null,
        creditPhone: _mode == PaymentMode.credit ? _partyPhone.text.trim() : null,
      );
      _amount.clear();
      _refText.clear();
      // Printing is fire-and-forget by design (P2): a printer that does not
      // answer must not roll back money that was taken, so the outcome is
      // reported, never awaited into the payment path.
      unawaitedPrint(context, ref, done);
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    widget.onError(error);
    // Hand the cashier a clean slate when the typed cash covers the remaining
    // due. `widget.ticket` is the PRE-payment read (the stream updates a frame
    // later), so the comparison is done against what we just submitted.
    if (error == null && _applied.paise >= widget.ticket.due.paise) {
      settleActiveTicket(ref);
    }
  }

  final TextEditingController _refText = TextEditingController();
  final TextEditingController _partyText = TextEditingController();
  final TextEditingController _partyPhone = TextEditingController();

  Future<void> unawaitedPrint(BuildContext context, WidgetRef ref, OrderTicket ticket) async {
    try {
      final out = await ref.read(printingProvider).printTicket(
        ticketId: ticket.id,
        kind: ticket.due.isPositive ? ReceiptKind.due : ReceiptKind.sale,
      );
      if (!context.mounted) return;
      if (out.failed) {
        showSnack(context, 'Paid, but the printer did not answer: ${out.error}. The slip is queued on the Settings screen.', error: true);
      } else {
        showSnack(context, 'Printed. Change ${rupeesText(_change)}');
      }
    } catch (e) {
      if (context.mounted) showSnack(context, 'Paid. Print failed: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final due = widget.ticket.due;
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                for (final m in PaymentMode.values)
                  ChoiceChip(
                    label: Text(m.label),
                    selected: _mode == m,
                    onSelected: (_) => setState(() => _mode = m),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            _isCash ? 'Cash received' : (_mode == PaymentMode.credit ? 'Amount on credit' : 'Amount'),
            style: theme.textTheme.bodySmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
          child: Text(
            _amount.isEmpty ? due.toCompactString() : _amount.text,
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (_mode == PaymentMode.credit)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _partyText,
              decoration: const InputDecoration(labelText: 'Name for the due list', isDense: true),
            ),
          ),
        if (_mode == PaymentMode.credit)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
            child: TextField(
              controller: _partyPhone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone (optional)', isDense: true),
            ),
          ),
        if (_mode == PaymentMode.upi || _mode == PaymentMode.card)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: TextField(
              controller: _refText,
              decoration: const InputDecoration(labelText: 'Reference (RRN / UPI id)', isDense: true),
            ),
          ),
        if (_isCash)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      _amount.clear();
                      _amount.append('${due.paise ~/ 100}');
                    },
                    child: const Text('Exact due'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () {
                      _amount.clear();
                      _amount.append(roundUpTo(due).toString());
                    },
                    child: const Text('Round up'),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text('Applied ${rupeesText(_applied)}'),
              const Spacer(),
              Text('Change ${rupeesText(_change)}', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: NumberPad(
              onDigit: (d) => _amount.append('$d'),
              onBackspace: _amount.backspace,
              onClear: _amount.clear,
              onDecimal: () => _amount.append('.'),
              extraKeys: [
                Row(
                  children: [
                    for (final note in const [10, 20, 50, 100, 200, 500])
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 44),
                              padding: EdgeInsets.zero,
                            ),
                            onPressed: () {
                              _amount.clear();
                              _amount.append('$note');
                            },
                            child: Text('$note', style: const TextStyle(fontSize: 14)),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: due.isPositive && !_busy
                      ? _pay
                      : null,
                  icon: _busy
                      ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.payments_outlined),
                  label: Text(due.isPositive ? 'Take ${rupeesText(_applied.isZero ? due : _applied)}' : 'Settled'),
                ),
              ),
            ],
          ),
        ),
        if (widget.lastError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(widget.lastError!, style: TextStyle(color: theme.colorScheme.error), textAlign: TextAlign.center),
          ),
      ],
    );
  }
}

/// Smallest round note value that covers the due, in rupees (Y2's "Round up"):
/// Pure, public for `test/features/billing_rounding_test.dart`, and pure on
/// purpose: a cashier-facing money decision must be assertable without a widget.
///
/// 330.00 due -> 500, 45 -> 50. Indian notes are 10/20/50/100/200/500/2000, so
/// anything under 10 is exact and the "round up" button should not invent a
/// ₹1 note that no counter has.
int roundUpTo(Money due) {
  final r = (due.paise / 100).ceil();
  const notes = [10, 20, 50, 100, 200, 500, 1000, 2000];
  for (final n in notes) {
    if (r <= n) return n;
  }
  return ((r / 500).ceil()) * 500;
}

/// The "who still owes us?" list, which is also the entry point to a bill the
/// kitchen has already served (O4/Y3). Tapping one makes it the active bill.
class _DueList extends ConsumerWidget {
  const _DueList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tickets = ref.watch(openTicketsProvider);
    final theme = Theme.of(context);
    return tickets.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('$e')),
      data: (rows) {
        final due = rows.where((t) => t.appearsInDueList).toList();
        if (due.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Nothing to pay', style: theme.textTheme.titleLarge),
                const SizedBox(height: 6),
                const Text('Every open bill is settled. New bills appear here.'),
              ],
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(12),
          itemCount: due.length,
          itemBuilder: (_, i) {
            final t = due[i];
            return Card(
              child: ListTile(
                leading: CircleAvatar(child: Text('${t.lineCount}')),
                title: Text(t.tableOrName ?? (t.billNumber == null ? 'Unnumbered bill' : 'Bill ${t.billNumber}')),
                subtitle: Text(
                  '${t.type.label}  ·  ${t.status.label}  ·  paid ${rupeesText(t.paid)}',
                  style: theme.textTheme.bodySmall,
                ),
                trailing: Text(rupeesText(t.due), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                onTap: () => ref.read(activeTicketIdProvider.notifier).state = t.id,
              ),
            );
          },
        );
      },
    );
  }
}
