/// Staff, shifts and cash-up (Task S2, S3, S4, R2).
///
/// One page for all three because they are the same daily conversation: "who was
/// on, how much did their drawer hold, and what is the difference". Splitting
/// them across screens is how a manager closes a shift without looking at the
/// variance, so the variance is the LAST thing on this page and it is labelled.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../app/widgets/number_pad.dart';
import '../../../core/money/money.dart';
import '../../../core/providers.dart';
import '../../../data/models/enums.dart';
import '../../../data/models/payment.dart';

import '../../../data/models/staff.dart';
import '../../../data/repositories/contract/staff_repository.dart';

class StaffShiftPage extends ConsumerWidget {
  const StaffShiftPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(staffUsersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Staff & shifts')),
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(staffUsersProvider.future),
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text('Who is on the till', style: Theme.of(context).textTheme.titleMedium),
            users.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('$e'),
              data: (list) => Column(
                children: [
                  for (final u in list) _UserRow(user: u),
                  if (list.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('No staff yet.')),
                ],
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () => _addUser(context, ref),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [Icon(Icons.person_add_alt), SizedBox(width: 8), Text('Add staff')],
              ),
            ),
            const SizedBox(height: 20),
            const _ShiftCard(),
            const SizedBox(height: 20),
            const _CashUpCard(),
            const SizedBox(height: 20),
            const _DueCard(),
          ],
        ),
      ),
    );
  }

  Future<void> _addUser(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final pin = DigitBuffer(maxLength: 6);
    var role = UserRole.cashier;
    String? error;
    final done = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, setInner) => AlertDialog(
          title: const Text('New staff member'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Name'), autofocus: true),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final r in UserRole.values)
                      ChoiceChip(
                        label: Text(r.label),
                        selected: role == r,
                        onSelected: (_) => setInner(() => role = r),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text('PIN: ${pin.isEmpty ? 'not set' : '●' * pin.length}', style: Theme.of(context).textTheme.bodyMedium),
                NumberPad(
                  onDigit: (d) => setInner(() => pin.append('$d')),
                  onBackspace: () => setInner(pin.backspace),
                  onClear: () => setInner(pin.clear),
                ),
                if (error != null) Text(error!, style: TextStyle(color: Theme.of(c).colorScheme.error)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                try {
                  await ref.read(staffRepositoryProvider).addUser(name: name.text.trim(), pin: pin.text, role: role);
                  if (c.mounted) Navigator.pop(c, true);
                } catch (e) {
                  setInner(() => error = '$e');
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    if (done == true && context.mounted) showSnack(context, 'Staff added');
  }
}

class _UserRow extends ConsumerWidget {
  const _UserRow({required this.user});

  final StaffUser user;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        leading: CircleAvatar(child: Text(user.name.characters.first.toUpperCase())),
        title: Text(user.name),
        subtitle: Text(
          '${user.role.label}'
          '${user.active ? '' : '  ·  disabled'}'
          '${user.isLocked ? '  ·  locked (wrong PIN too often)' : ''}'
          '${user.failedAttempts > 0 && !user.isLocked ? '  ·  ${user.failedAttempts} wrong tries' : ''}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: user.role == UserRole.manager
            ? const Icon(Icons.shield_outlined, size: 20)
            : IconButton(
                tooltip: user.active ? 'Disable' : 'Enable',
                icon: Icon(user.active ? Icons.lock_outline : Icons.lock_open_outlined),
                onPressed: () async {
                  try {
                    await ref.read(staffRepositoryProvider).setUserActive(userId: user.id, active: !user.active);
                  } catch (e) {
                    if (context.mounted) showSnack(context, '$e', error: true);
                  }
                },
              ),
      ),
    );
  }
}

class _ShiftCard extends ConsumerWidget {
  const _ShiftCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentSessionProvider);
    return FutureBuilder<Shift?>(
      future: me.userId == null ? Future.value(null) : ref.read(staffRepositoryProvider).currentShift(me.userId!),
      builder: (context, snap) {
        final shift = snap.data;
        final theme = Theme.of(context);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('My shift', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                if (shift == null)
                  const Text('No shift open. One is started automatically the next time you sign in.')
                else ...[
                  Text('Opened ${_stamp(shift.openedAt)}  ·  float ${rupeesText(shift.openingFloat)}'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _setFloat(context, ref, shift),
                          child: const Text('Set opening float'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => _closeShift(context, ref, shift),
                          child: const Text('Close & count…'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _setFloat(BuildContext context, WidgetRef ref, Shift shift) async {
    // Changing the float re-opens the shift at the same start time: the money a
    // cashier started with is a fact they may mis-type at 8am, and refusing to
    // fix it would put a permanent false variance on their day.
    final controller = TextEditingController(text: (shift.openingFloat.paise / 100).toStringAsFixed(0));
    final value = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Opening float'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Cash in the drawer at open (₹)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(c, int.tryParse(controller.text.trim()) ?? 0),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (value == null || !context.mounted) return;
    final repo = ref.read(staffRepositoryProvider);
    await repo.openShift(shift.userId, openingFloat: Money(value * 100));
    showSnack(context, 'Shift reopened with float ${rupeesText(Money(value * 100))} (the old one closed uncounted)');
  }

  Future<void> _closeShift(BuildContext context, WidgetRef ref, Shift shift) async {
    final collected = await ref.read(staffRepositoryProvider).cashCollectedDuring(shift);
    if (!context.mounted) return;
    final expected = shift.openingFloat + collected;
    final counted = await showDialog<Money>(
      context: context,
      builder: (c) => _CountDialog(expected: expected),
    );
    if (counted == null || !context.mounted) return;
    await ref.read(staffRepositoryProvider).closeShift(shiftId: shift.id, countedCash: counted);
    final variance = counted - expected;
    showSnack(
      context,
      variance.paise == 0
          ? 'Shift closed. Drawer matched exactly.'
          : 'Shift closed. ${variance.isNegative ? 'Short' : 'Over'} by ${rupeesText(Money(variance.paise.abs()))}',
      error: variance.paise != 0,
    );
  }
}

/// Counting dialog: shows EXPECTED first, then asks for what you have. That
/// order is deliberate — a field for "counted" with the target off-screen is how
/// a cashier counts to the expected number instead of the real one (S4).
class _CountDialog extends StatefulWidget {
  const _CountDialog({required this.expected});

  final Money expected;

  @override
  State<_CountDialog> createState() => _CountDialogState();
}

class _CountDialogState extends State<_CountDialog> {
  final DigitBuffer _counted = DigitBuffer(maxLength: 11, allowDecimal: true);

  @override
  Widget build(BuildContext context) {
    final typed = _counted.isEmpty ? null : Money.rupees(num.tryParse(_counted.text) ?? 0);
    final diff = typed == null ? null : typed - widget.expected;
    return AlertDialog(
      title: const Text('Cash up'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Expected in drawer: ${rupeesText(widget.expected)}', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('Count the notes and coins, then type what you have.', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 10),
            Text(_counted.isEmpty ? '—' : '₹${_counted.text}', style: Theme.of(context).textTheme.headlineSmall),
            NumberPad(
              onDigit: (d) => setState(() => _counted.append('$d')),
              onBackspace: () => setState(_counted.backspace),
              onClear: () => setState(_counted.clear),
              onDecimal: () => setState(() => _counted.append('.')),
            ),
            if (diff != null && diff.paise != 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${diff.isNegative ? 'Short' : 'Over'} by ${rupeesText(Money(diff.paise.abs()))}',
                  style: TextStyle(fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: typed == null ? null : () => Navigator.pop(context, typed), child: const Text('Close shift')),
      ],
    );
  }
}

class _CashUpCard extends ConsumerWidget {
  const _CashUpCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<ShiftSummary>>(
      future: ref.read(staffRepositoryProvider).shiftSummaries(from: DateTime.now().subtract(const Duration(days: 7))),
      builder: (context, snap) {
        final rows = snap.data ?? const <ShiftSummary>[];
        final theme = Theme.of(context);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Last 7 days of shifts', style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                if (rows.isEmpty) const Text('No shifts recorded.'),
                for (final s in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(child: Text('${s.userName} · ${_stamp(s.shift.openedAt)}', style: theme.textTheme.bodyMedium)),
                        Text(rupeesText(s.expectedCash), style: theme.textTheme.bodyMedium),
                        const SizedBox(width: 8),
                        Text(
                          s.isClosed
                              ? (s.variance == null || s.variance!.paise == 0
                                  ? 'ok'
                                  : '${s.variance!.paise > 0 ? '+' : '-'}${rupeesText(Money(s.variance!.paise.abs()))}')
                              : 'open',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: s.needsExplanation(tolerance: Money(100)) ? theme.colorScheme.error : null,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Pay-later accounts (Y4). `DueParty` is an aggregate — one row per name, with
/// the shop's total outstanding — while a settlement must reference a *credit
/// row*. So the dialog pays the oldest open rows first (FIFO, how a running
/// account is actually cleared) and shows which bills that covers.
class _DueCard extends ConsumerWidget {
  const _DueCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(openCreditProvider).maybeWhen(
      data: (d) => d,
      orElse: () => const <CreditEntry>[],
    );
    final theme = Theme.of(context);
    final byParty = <String, Money>{};
    final open = <String, List<CreditEntry>>{};
    for (final c in rows) {
      byParty[c.party] = Money((byParty[c.party]?.paise ?? 0) + c.amount.paise);
      (open[c.party] ??= []).add(c);
    }
    for (final list in open.values) {
      list.sort((a, b) => a.at.compareTo(b.at));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Pay later (credit)', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            if (byParty.isEmpty) const Text('Nobody owes the shop anything.'),
            for (final e in byParty.entries)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(e.key),
                subtitle: Text(
                  '${open[e.key]!.length} open bill(s)  ·  since ${_stamp(open[e.key]!.first.at)}'
                  '${open[e.key]!.first.at.difference(DateTime.now()).inDays.abs() > 30 ? '  ·  ageing' : ''}',
                  style: theme.textTheme.bodySmall,
                ),
                trailing: Text(rupeesText(e.value), style: theme.textTheme.titleMedium),
                onTap: () => _settle(context, ref, party: e.key, rows: open[e.key]!, total: e.value),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _settle(
    BuildContext context,
    WidgetRef ref, {
    required String party,
    required List<CreditEntry> rows,
    required Money total,
  }) async {
    final wanted = await showDialog<int>(
      context: context,
      builder: (c) => _SettleDialog(party: party, total: total, rows: rows),
    );
    if (wanted == null || wanted <= 0) return;
    var remaining = Money(wanted);
    var covered = 0;
    final repo = ref.read(paymentRepositoryProvider);
    final actor = ref.read(currentSessionProvider).userId ?? 'system';
    for (final row in rows) {
      if (!remaining.isPositive) break;
      final take = row.amount.paise <= remaining.paise ? row.amount : remaining;
      await repo.settleCredit(
        creditEntryId: row.id,
        mode: PaymentMode.cash,
        amount: take,
        actorId: actor,
        note: 'collected at counter',
      );
      remaining = Money(remaining.paise - take.paise);
      covered++;
    }
    if (!context.mounted) return;
    final got = wanted - remaining.paise;
    showSnack(
      context,
      'Collected ${rupeesText(Money(got))} from $party ($covered bill(s))'
      '${remaining.isPositive ? ' · ${rupeesText(remaining)} still due' : ''}',
    );
  }
}

class _SettleDialog extends StatefulWidget {
  const _SettleDialog({required this.party, required this.total, required this.rows});

  final String party;
  final Money total;
  final List<CreditEntry> rows;

  @override
  State<_SettleDialog> createState() => _SettleDialogState();
}

class _SettleDialogState extends State<_SettleDialog> {
  late final DigitBuffer _amount = DigitBuffer(
    // Rupees, not paise: the pad types rupees with a decimal point, and a
    // ₹1,250.00 account must not arrive as the digits "125000".
    initial: (widget.total.paise / 100).toStringAsFixed(widget.total.paise % 100 == 0 ? 0 : 2),
    maxLength: 11,
    allowDecimal: true,
  );

  @override
  Widget build(BuildContext context) {
    final paise = num.tryParse(_amount.text.isEmpty ? '0' : _amount.text);
    final value = paise == null ? null : Money.rupees(paise);
    final over = value != null && value.paise > widget.total.paise;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Collect from ${widget.party}'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Outstanding ${rupeesText(widget.total)} across ${widget.rows.length} bill(s):', style: theme.textTheme.bodySmall),
            for (final r in widget.rows.take(5))
              Text('  ${rupeesText(r.amount)}  ·  ${_stamp(r.at)}${r.linkedOrderId == null ? '' : '  ·  #${r.linkedOrderId}'}', style: theme.textTheme.bodySmall),
            if (widget.rows.length > 5) Text('  … and ${widget.rows.length - 5} more', style: theme.textTheme.bodySmall),
            const SizedBox(height: 10),
            Text(value == null ? '₹ —' : rupeesText(value), style: theme.textTheme.headlineSmall),
            NumberPad(
              onDigit: (d) => setState(() => _amount.append('$d')),
              onBackspace: () => setState(_amount.backspace),
              onClear: () => setState(_amount.clear),
              onDecimal: () => setState(() => _amount.append('.')),
              extraKeys: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() {
                      _amount.clear();
                      _amount.append((widget.total.paise / 100).toStringAsFixed(widget.total.paise % 100 == 0 ? 0 : 2));
                    }),
                    child: const Text('All'),
                  ),
                ),
              ],
            ),
            if (over)
              Text('More than the outstanding amount. A part-payment is fine — type the part.',
                  style: TextStyle(color: theme.colorScheme.error)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: value == null || !value.isPositive || over
              ? null
              : () => Navigator.pop(context, value.paise),
          child: const Text('Collect (cash)'),
        ),
      ],
    );
  }
}

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(t.day)}/${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
}
