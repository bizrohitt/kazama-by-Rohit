/// Stock list + adjust (Task I1-I3).
///
/// The list is sorted by NEED, not by name: the only question at a counter is
/// "what am I about to run out of", and an alphabetical list buries that under
/// 20 rows of `Boiled rice`. Rows below the reorder line are labelled `LOW`/`OUT`
/// in text (U3: never colour alone), and the row still shows what it is used for
/// so the person ordering knows whether "12 buns" is a crisis or a Tuesday.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/number_pad.dart';
import '../../../core/providers.dart';
import '../../../data/models/stock.dart';

final StreamProvider<List<StockLine>> stockLinesProvider =
    StreamProvider<List<StockLine>>((ref) => ref.watch(stockRepositoryProvider).watchStock());

class StockScreen extends ConsumerWidget {
  const StockScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = ref.watch(stockLinesProvider);
    final theme = Theme.of(context);
    return Scaffold(
      body: lines.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (rows) {
          final sorted = [...rows]..sort((a, b) {
            // OUT first, then LOW, then everything else by name.
            int rank(StockLine l) => l.item.isOut ? 0 : (l.item.isLow ? 1 : 2);
            final r = rank(a).compareTo(rank(b));
            return r != 0 ? r : a.item.name.compareTo(b.item.name);
          });
          final attention = sorted.where((l) => l.needsAttention).length;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    Text('Stock', style: theme.textTheme.titleLarge),
                    const Spacer(),
                    Text(
                      attention == 0 ? 'All above the reorder line' : '$attention to reorder',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: attention == 0 ? null : FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: sorted.isEmpty
                    ? const Center(child: Text('No stock items yet. They are seeded with the demo menu — check Settings > Menu.'))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        itemCount: sorted.length,
                        itemBuilder: (_, i) => _StockRow(line: sorted[i]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StockRow extends ConsumerWidget {
  const _StockRow({required this.line});

  final StockLine line;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final s = line.item;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: s.isOut ? theme.colorScheme.errorContainer : null,
          child: Text(s.isOut ? '!' : (s.isLow ? '↓' : '✓')),
        ),
        title: Text(s.name),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${line.attention}   ·   reorder at ${(s.reorderMilli / 1000).toStringAsFixed(0)} ${s.unit}',
              style: theme.textTheme.bodySmall,
            ),
            if (line.usedByItemNames.isNotEmpty)
              Text('used by: ${line.usedByItemNames.join(', ')}', style: theme.textTheme.bodySmall),
            if (line.lastMovementAt != null)
              Text('last move ${_stamp(line.lastMovementAt!)}', style: theme.textTheme.bodySmall),
          ],
        ),
        trailing: FilledButton.tonal(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => _AdjustSheet(item: s),
          ),
          child: const Text('Adjust'),
        ),
      ),
    );
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}/${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// Receive / wastage / count, in one sheet (I1).
///
/// `count` is a different verb, not a signed delta: the shopkeeper types what
/// they SEE and the app records the difference. Keeping both in one sheet (with
/// the field label changing) is what makes "wastage of 200 g" and "I counted
/// 200 g" impossible to mix up — they look identical in a single "adjustment"
/// field and produce opposite ledger rows.
class _AdjustSheet extends ConsumerStatefulWidget {
  const _AdjustSheet({required this.item});

  final StockItem item;

  @override
  ConsumerState<_AdjustSheet> createState() => _AdjustSheetState();
}

class _AdjustSheetState extends ConsumerState<_AdjustSheet> {
  StockMoveKind _kind = StockMoveKind.receive;
  final DigitBuffer _qty = DigitBuffer(maxLength: 8, allowDecimal: true, onChange: () {});
  final TextEditingController _note = TextEditingController();
  bool _busy = false;
  String? _error;

  int get _milli {
    final v = num.tryParse(_qty.text);
    if (v == null) return 0;
    // One place converts rupee-style decimal input to milli-units, and it is
    // integer maths: `250.5` g -> 250500 milli-g, never a float error.
    return (v * 1000).round();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCount = _kind == StockMoveKind.count;
    final projected = isCount ? _milli : widget.item.onHandMilli + (_kind == StockMoveKind.receive ? _milli : -_milli);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: [
                    Expanded(child: Text('Adjust ${widget.item.name}', style: theme.textTheme.titleLarge)),
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final k in StockMoveKind.values)
                      if (k != StockMoveKind.sale)
                        ChoiceChip(
                          // `sale` is not offered: sales come from firing a
                          // ticket, and a hand-typed "sale" would bypass the
                          // once-per-ticket rule entirely (I2).
                          label: Text(k.label),
                          selected: _kind == k,
                          onSelected: (_) => setState(() => _kind = k),
                        ),
                  ],
                ),
              ),
              Text(isCount ? 'I counted (in ${widget.item.unit})' : 'Amount (in ${widget.item.unit})', style: theme.textTheme.bodySmall),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Text(_qty.isEmpty ? '-' : _qty.text, style: theme.textTheme.headlineSmall),
              ),
              NumberPad(
                onDigit: (d) => _qty.append('$d'),
                onBackspace: _qty.backspace,
                onClear: _qty.clear,
                onDecimal: () => _qty.append('.'),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: TextField(
                  controller: _note,
                  decoration: const InputDecoration(labelText: 'Note (why)', isDense: true),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      'On-hand becomes ${(projected / 1000).toStringAsFixed(1)} ${widget.item.unit} '
                      '(from ${(widget.item.onHandMilli / 1000).toStringAsFixed(1)})',
                      style: theme.textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                    if (projected < 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'This would take stock below zero.',
                          style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w700),
                        ),
                      ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                      ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _busy || _milli == 0 ? null : _save,
                        child: Text(_busy ? 'Saving…' : 'Record ${_kind.label.toLowerCase()}'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(stockRepositoryProvider).adjust(
        stockItemId: widget.item.id,
        kind: _kind,
        deltaMilli: _kind == StockMoveKind.count ? 0 : (_kind == StockMoveKind.receive ? _milli : -_milli),
        absoluteMilliForCount: _milli,
        actorId: ref.read(currentSessionProvider).userId ?? 'system',
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context);
      showSnack(context, '${widget.item.name} updated');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
