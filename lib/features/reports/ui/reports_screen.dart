/// The owner screen (Task R1-R4): one day's numbers, the shift under them, the
/// bestsellers and the hour shape of the day.
///
/// Everything on this page is a Dart-side aggregation the repository already
/// computes — no SQL here, and no chart package (R6). The hour strip is a Row of
/// Containers for exactly that reason: 24 bars do not need a dependency, and a
/// POS must not fail to build because a charting library changed its API.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/money/money.dart';
import '../../../core/providers.dart';

import '../../../data/models/report.dart';

/// How many days back the picker will go. Deliberately a small constant rather
/// than "all history": a month of `day()` calls is a month of full-table reads on
/// a phone that a shop owner will not wait for, and nobody reconciles a counter
/// more than a few weeks late from a POS screen (they'd ask for the CSV).
const int kReportWindowDays = 30;

/// Midnight of `d` — one shared helper, because a report that uses a different
/// "start of day" than the shift list is a report that disagrees with itself.
DateTime dayStart(DateTime d) => DateTime(d.year, d.month, d.day);

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  DateTime _day = dayStart(DateTime.now());

  void _shift(int days) => setState(() => _day = dayStart(_day.add(Duration(days: days))));

  @override
  Widget build(BuildContext context) {
    final today = dayStart(DateTime.now());
    final oldest = today.subtract(const Duration(days: kReportWindowDays - 1));
    if (_day.isBefore(oldest)) _day = oldest;
    final theme = Theme.of(context);
    final isToday = _day == today;
    final totals = FutureBuilder<DailyTotals>(
      future: ref.read(paymentRepositoryProvider).day(_day),
      builder: (context, snap) {
        final t = snap.data;
        if (t == null) return const LinearProgressIndicator();
        return _TotalsCard(totals: t, isToday: isToday);
      },
    );
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => setState(() {}),
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            // Day stepper instead of a date picker: the answer to "how was
            // yesterday?" must be two taps, and a calendar is a finger-trap.
            Row(
              children: [
                IconButton(onPressed: () => _shift(-1), icon: const Icon(Icons.chevron_left)),
                Expanded(
                  child: Text(
                    isToday ? 'Today · ${_date(_day)}' : _date(_day),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: _day == today ? null : () => _shift(1),
                  icon: const Icon(Icons.chevron_right),
                ),
                IconButton(
                  tooltip: 'Copy this day as CSV (paste into WhatsApp/Sheets)',
                  onPressed: _copyCsv,
                  icon: const Icon(Icons.copy_all_outlined),
                ),
              ],
            ),
            totals,
            const SizedBox(height: 10),
            if (isToday) const _ShiftStrip(),
            const SizedBox(height: 10),
            // `to` is one day after `from`: `ordersBetween` is [from, to), and a
            // single-day report asking for (Tue, Tue) would silently exclude
            // everything billed after midnight on Tuesday.
            _BestsellersCard(from: _day, to: _day.add(const Duration(days: 1))),
            const SizedBox(height: 10),
            _HoursCard(day: _day),
            const SizedBox(height: 18),
          ],
        ),
      ),
    );
  }

  Future<void> _copyCsv() async {
    final csv = await ref
        .read(paymentRepositoryProvider)
        .buildCsv(from: _day.subtract(const Duration(days: 6)), to: _day);
    await Clipboard.setData(ClipboardData(text: csv));
    if (!mounted) return;
    showSnack(context, '7 days of totals copied (${csv.split('\n').length - 1} rows). Paste into Sheets or WhatsApp.');
  }

  String _date(DateTime d) => '${d.toString().substring(0, 10)}';
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.totals, required this.isToday});

  final DailyTotals totals;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = totals;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Billed ${rupeesText(t.charged)}', style: theme.textTheme.headlineSmall)),
                Text('${t.bills} bill${t.bills == 1 ? '' : 's'}', style: theme.textTheme.bodyMedium),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${t.covers} covers · avg ${rupeesText(t.averageBill)}'
              '${t.voidedBills == 0 ? '' : ' · ${t.voidedBills} voided'}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _KV(label: 'Menu value (gross)', value: rupeesText(t.gross)),
            _KV(label: 'Discounts', value: t.discount.isPositive ? '-${rupeesText(t.discount)}' : '—'),
            _KV(label: 'Net sales (excl. GST)', value: rupeesText(t.netSales)),
            _KV(label: 'GST', value: rupeesText(t.tax)),
            if (t.rounding.paise != 0) _KV(label: 'Rounding line', value: t.rounding.toString()),
            const Divider(height: 20),
            _KV(label: 'Collected', value: rupeesText(t.charged), big: true),
            for (final e in t.byMode.entries)
              if (e.value.isPositive) _KV(label: '   ${e.key.label}', value: rupeesText(e.value)),
            if (t.due.isPositive)
              _KV(label: 'Still due (pay later)', value: rupeesText(t.due), danger: true),
            if (isToday)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Live: unpaid bills count here as due, not as sales.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Today's shifts, from the same provider the staff page uses, so the two can
/// never disagree about what a drawer should hold (R2/S4 are one number).
class _ShiftStrip extends ConsumerWidget {
  const _ShiftStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<ShiftSummary>>(  // ShiftSummary comes in via core/providers.dart
      future: ref.read(staffRepositoryProvider).shiftSummaries(from: dayStart(DateTime.now())),
      builder: (context, snap) {
        final rows = snap.data ?? const <ShiftSummary>[];
        final theme = Theme.of(context);
        if (rows.isEmpty) return const SizedBox.shrink();
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Shifts today', style: theme.textTheme.titleMedium),
                for (final s in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(child: Text(s.userName, style: theme.textTheme.bodyMedium)),
                        Text(rupeesText(s.expectedCash), style: theme.textTheme.bodySmall),
                        const SizedBox(width: 8),
                        Text(
                          s.isClosed
                              ? (s.variance == null
                                  ? '—'
                                  : '${s.variance!.paise == 0 ? 'matched' : '${s.variance!.paise > 0 ? '+' : '−'}${rupeesText(Money(s.variance!.paise.abs()))}'}')
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

class _BestsellersCard extends ConsumerWidget {
  const _BestsellersCard({required this.from, required this.to});

  final DateTime from;
  final DateTime to;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<BestsellerRow>>(
      future: ref.read(paymentRepositoryProvider).bestsellers(from: from, to: to, limit: 10),
      builder: (context, snap) {
        final rows = snap.data ?? const <BestsellerRow>[];
        final theme = Theme.of(context);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Top items', style: theme.textTheme.titleMedium),
                if (rows.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('No sales in this window.')),
                for (final r in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        Expanded(child: Text(r.name, style: theme.textTheme.bodyMedium)),
                        Text('${r.quantity} sold', style: theme.textTheme.bodySmall),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 84,
                          child: Text(rupeesText(r.revenue), textAlign: TextAlign.right, style: theme.textTheme.bodyMedium),
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

class _HoursCard extends ConsumerWidget {
  const _HoursCard({required this.day});

  final DateTime day;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<HourBucket>>(
      future: ref.read(paymentRepositoryProvider).hourBuckets(day),
      builder: (context, snap) {
        final rows = snap.data ?? const <HourBucket>[];
        final theme = Theme.of(context);
        final maxPaise = rows.isEmpty ? 1 : rows.map((r) => r.revenue.paise).reduce((a, b) => a > b ? a : b);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('By hour', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                SizedBox(
                  height: 72,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var h = 6; h < 24; h++)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 1),
                            child: _Bar(
                              // Height is a fraction of the busiest hour, so the
                              // shape of the day reads without an axis.
                              fraction: rows.where((r) => r.hour == h).isEmpty
                                  ? 0
                                  : rows.firstWhere((r) => r.hour == h).revenue.paise / maxPaise,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '6am → 11pm (midnight to 6am is empty by design) · tallest hour ${rupeesText(Money(maxPaise))}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FractionallySizedBox(
      heightFactor: fraction.clamp(0.02, 1.0),
      alignment: Alignment.bottomCenter,
      child: Container(
        decoration: BoxDecoration(
          color: fraction <= 0.02 ? theme.colorScheme.surfaceContainerHighest : theme.colorScheme.primary,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
        ),
      ),
    );
  }
}

class _KV extends StatelessWidget {
  const _KV({required this.label, required this.value, this.big = false, this.danger = false});

  final String label;
  final String value;
  final bool big;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          Expanded(child: Text(label, style: big ? theme.textTheme.bodyLarge : theme.textTheme.bodyMedium)),
          Text(
            value,
            style: (big ? theme.textTheme.titleMedium : theme.textTheme.bodyMedium)?.copyWith(
              fontWeight: big ? FontWeight.w700 : FontWeight.w500,
              color: danger ? theme.colorScheme.error : null,
            ),
          ),
        ],
      ),
    );
  }
}
