/// Payment, credit and report-read repository (Task Y1-Y4 + R1-R4).
///
/// Report numbers are aggregated in Dart over rows the DAO already exposes. That
/// is a deliberate trade: a hand-written drift `CustomSelect` (GROUP BY with
/// CASE/COALESCE) is unverifiable in this offline environment, and a day at this
/// counter is a few hundred rows. A wrong ₹ figure on a report costs more than an
/// extra millisecond.
library;

import '../../../core/db/app_database.dart';
import '../../../core/money/money.dart';
import '../../../core/money/money_delta.dart';
import '../../../core/utils/id.dart';
import '../../models/enums.dart';
import '../../models/order.dart';
import '../../models/payment.dart';
import '../../models/report.dart';
import '../impl/sync_journal.dart';
import '../contract/payment_repository.dart';

class PaymentRepositoryImpl implements PaymentRepository {
  PaymentRepositoryImpl(this.db, {IdFactory? idFactory}) : ids = idFactory ?? IdFactory();

  final AppDatabase db;
  final IdFactory ids;

  @override
  Future<List<Payment>> paymentsFor(String ticketId) => db.paymentsFor(ticketId);

  // ----------------------------------------------------------------- credit --

  @override
  Stream<List<CreditEntry>> watchOpenCredit() =>
      db.watchCredit().map((rows) => [for (final r in rows) if (r.isOutstanding) r]);

  @override
  Future<void> addCredit({
    required String party,
    required Money amount,
    String? phone,
    String? note,
    String? linkedOrderId,
    required String actorId,
  }) {
    if (!amount.isPositive) throw ArgumentError('a due entry must be positive: ${amount.paise}p');
    if (party.trim().isEmpty) throw ArgumentError('a due entry needs a party name');
    return db.insertDue(
      id: ids.newId(),
      party: party.trim(),
      amountPaise: amount.paise,
      phone: _clean(phone),
      note: _clean(note),
      linkedOrderId: linkedOrderId,
      actorId: actorId,
    );
  }

  @override
  Future<void> settleCredit({
    required String creditEntryId,
    required PaymentMode mode,
    required Money amount,
    required String actorId,
    String? note,
  }) async {
    final due = await db.creditById(creditEntryId);
    if (due == null) throw StateError('credit row $creditEntryId not found');
    if (!due.isOutstanding) throw StateError('credit row $creditEntryId is already settled');
    if (amount > due.amount) {
      // Refused rather than auto-clamped: a cashier typing 500 against a 450 due
      // must be told, not silently left with ₹50 of loose cash in the drawer and
      // no record of why (Y4).
      throw ArgumentError('settlement ${amount.paise}p exceeds the outstanding ${due.amount.paise}p');
    }
    if (mode == PaymentMode.credit) {
      throw ArgumentError('settling a due with another due is a loop, not a payment');
    }
    final at = DateTime.now();
    final settlementId = ids.newId();
    await db.transaction(() async {
      await db.insertSettlement(
        id: settlementId,
        party: due.party,
        amountPaise: amount.paise,
        settlesEntryId: creditEntryId,
        note: _clean(note),
        actorId: actorId,
        at: at,
      );
      // A settlement is money a customer handed over days later; losing it would
      // corrupt the ledger on the server, so it is journalled like a payment.
      await journalMutation(
        db,
        ids,
        entity: 'creditSettlement',
        entityId: settlementId,
        op: MutationOp.insert,
        payload: {
          'id': settlementId,
          'party': due.party,
          'settlesEntryId': creditEntryId,
          'amountPaise': amount.paise,
          'mode': mode.name,
          'actorId': actorId,
          'at': at.toIso8601String(),
        },
        at: at,
      );
    });
  }

  @override
  Future<List<DueParty>> dueParties() async {
    final rows = await db.select(db.creditEntries).get();
    final byParty = <String, _PartyBucket>{};
    for (final r in rows) {
      // `Money` cannot hold a negative, so the running balance is plain paise and
      // becomes a Money only at the end (the one place this class touches ints).
      final b = byParty.putIfAbsent(r.party, () => _PartyBucket(r.phone));
      b.paise += r.kind == 'due' ? r.amountPaise : -r.amountPaise;
      if (r.kind == 'due' && r.settledAt == null) b.openTickets += 1;
      if (r.kind == 'due' && (b.oldest == null || r.at.isBefore(b.oldest!))) b.oldest = r.at;
    }
    final out = <DueParty>[];
    byParty.forEach((party, b) {
      if (b.paise <= 0) return; // settled or over-paid: nothing to collect
      out.add(
        DueParty(
          party: party,
          phone: b.phone,
          outstanding: Money(b.paise),
          ticketCount: b.openTickets,
          oldestAt: b.oldest,
        ),
      );
    });
    // Biggest debtor first: the list is a collection queue, not a directory.
    out.sort((a, b) => b.outstanding.paise.compareTo(a.outstanding.paise));
    return out;
  }

  // ----------------------------------------------------------------- report --

  @override
  Future<DailyTotals> day(DateTime day) async {
    final from = DateTime(day.year, day.month, day.day);
    final rows = await dailyRange(from: from, to: from.add(const Duration(days: 1)));
    if (rows.isNotEmpty) return rows.first;
    // Hand-built zero day: `DailyTotals` has no `empty` ctor, and inventing one
    // just for this call would hide that a no-sales day still needs a row.
    return DailyTotals(
      day: from,
      bills: 0,
      covers: 0,
      gross: Money.zero,
      discount: Money.zero,
      tax: Money.zero,
      rounding: MoneyDelta.zero,
      netSales: Money.zero,
      due: Money.zero,
    );
  }

  @override
  Future<List<DailyTotals>> dailyRange({required DateTime from, required DateTime to}) async {
    final orders = await db.ticketsBetween(from, to);
    final payments = await db.paymentsBetween(from, to);
    if (orders.isEmpty && payments.isEmpty) return const [];

    // Bucket by the ORDER's own day, not by which range query returned it: a
    // ticket opened at 23:50 and paid at 00:05 belongs to the day it was sold
    // (a shop closes the day, not the shift minute).
    final byDay = <DateTime, List<OrderTicket>>{};
    for (final o in orders) {
      byDay.putIfAbsent(_dayOf(o.openedAt), () => []).add(o);
    }
    final payByDay = <DateTime, List<PaymentRow>>{};
    for (final p in payments) {
      payByDay.putIfAbsent(_dayOf(p.at), () => []).add(p);
    }
    final days = {...byDay.keys, ...payByDay.keys}.toList()..sort();
    return [
      for (final d in days)
        _totalsFor(d, byDay[d] ?? const [], payByDay[d] ?? const []),
    ];
  }

  DailyTotals _totalsFor(DateTime day, List<OrderTicket> orders, List<PaymentRow> payments) {
    // A voided ticket is counted (an owner must see it) but excluded from takings;
    // a ticket merely "served but not yet paid" is not in takings either — its
    // money arrives later and shows in `due` until then (R2).
    final counted = [for (final o in orders) if (!o.status.isVoided) o];
    final totals = [for (final o in counted) o.totals];
    final lineBase = Money.sum([for (final t in totals) t.lineBase]);
    final discount = Money.sum([for (final t in totals) t.discount]);
    final tax = Money.sum([for (final t in totals) t.tax]);
    final net = Money.sum([for (final t in totals) t.netBeforeTax]);
    final rounding = MoneyDelta.sum([for (final t in totals) t.rounding]);
    final due = Money.sum([for (final o in counted) o.due]);
    final byMode = <PaymentMode, Money>{};
    for (final p in payments) {
      byMode.update(
        PaymentMode.fromName(p.mode),
        (v) => Money(v.paise + p.amountPaise),
        ifAbsent: () => Money(p.amountPaise),
      );
    }
    return DailyTotals(
      day: day,
      bills: counted.where((o) => o.status == OrderStatus.paid).length,
      // `covers` needs a guest count on the ticket, which the schema does not
      // store — so it reports bills rather than inventing a number. A v1.1 task
      // can add `guest_count` to `orders` and this line becomes honest.
      covers: counted.length,
      gross: lineBase,
      discount: discount,
      tax: tax,
      rounding: rounding,
      netSales: net,
      due: due,
      byMode: byMode,
      voidedBills: orders.length - counted.length,
    );
  }

  @override
  Future<List<PaymentMode>> modesUsedOn(DateTime day) async {
    final from = _dayOf(day);
    final to = from.add(const Duration(days: 1));
    final rows = await db.paymentsBetween(from, to);
    final used = <PaymentMode>{for (final r in rows) PaymentMode.fromName(r.mode)};
    // Stable order (enum order), so two days' reports are comparable side by side.
    return [for (final m in PaymentMode.values) if (used.contains(m)) m];
  }

  @override
  Future<List<BestsellerRow>> bestsellers({
    required DateTime from,
    required DateTime to,
    int limit = 20,
  }) async {
    final orders = await db.ordersBetween(from, to);
    if (orders.isEmpty) return const [];
    // Bestsellers read `order_lines` snapshots, NOT the menu: what sold most in
    // March is a fact about March's prices and names, which a menu edit since
    // then must not rewrite (R3).
    final lines = await db.linesForOrders([for (final o in orders) o.id]);
    final qty = <String, int>{};
    final revenue = <String, int>{};
    final names = <String, String>{};
    for (final l in lines) {
      // A cancelled line sold nothing; a part-cancelled line sold the rest.
      final live = l.quantity - l.cancelledQuantity;
      if (live <= 0) continue;
      final key = l.itemId ?? l.nameSnapshot;
      qty.update(key, (v) => v + live, ifAbsent: () => live);
      revenue.update(key, (v) => v + live * l.unitPricePaise, ifAbsent: () => live * l.unitPricePaise);
      names[key] = l.nameSnapshot;
    }
    final rows = [
      for (final e in qty.entries)
        BestsellerRow(
          itemId: e.key,
          name: names[e.key] ?? e.key,
          quantity: e.value,
          revenue: Money(revenue[e.key] ?? 0),
        ),
    ]..sort((a, b) {
        final byQty = b.quantity.compareTo(a.quantity);
        return byQty != 0 ? byQty : b.revenue.paise.compareTo(a.revenue.paise);
      });
    return rows.take(limit).toList();
  }

  @override
  Future<List<HourBucket>> hourBuckets(DateTime day) async {
    final from = _dayOf(day);
    final to = from.add(const Duration(days: 1));
    final payments = await db.paymentsBetween(from, to);
    final revenue = List<int>.filled(24, 0);
    final bills = List<int>.filled(24, 0);
    for (final p in payments) {
      final h = p.at.hour;
      revenue[h] += p.amountPaise;
      bills[h] += 1;
    }
    // All 24 buckets, including empty ones: a chart that skips 3am is how a
    // dead hour gets mistaken for a missing day (R3).
    return [
      for (var h = 0; h < 24; h++)
        HourBucket(hour: h, revenue: Money(revenue[h]), bills: bills[h]),
    ];
  }

  // ------------------------------------------------------------------- csv --

  @override
  Future<String> buildCsv({required DateTime from, required DateTime to}) async {
    final rows = await dailyRange(from: from, to: to);
    final modes = PaymentMode.values;
    final buf = StringBuffer()
      ..writeln([
        'day',
        'bills',
        'covers',
        'gross_paise',
        'discount_paise',
        'tax_paise',
        'rounding_paise',
        'net_sales_paise',
        'due_paise',
        'voided_bills',
        for (final m in modes) '${m.name}_paise',
      ].join(','));
    for (final r in rows) {
      buf.writeln([
        r.day.toIso8601String().substring(0, 10),
        r.bills,
        r.covers,
        r.gross.paise,
        r.discount.paise,
        r.tax.paise,
        r.rounding.paise,
        r.netSales.paise,
        r.due.paise,
        r.voidedBills,
        for (final m in modes) (r.byMode[m] ?? Money.zero).paise,
      ].join(','));
    }
    return buf.toString();
  }

  static DateTime _dayOf(DateTime t) => DateTime(t.year, t.month, t.day);
  static String? _clean(String? v) {
    final t = v?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }
}

class _PartyBucket {
  _PartyBucket(this.phone);

  final String? phone;
  int paise = 0;
  int openTickets = 0;
  DateTime? oldest;
}
