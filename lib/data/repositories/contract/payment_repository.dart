/// Payment / credit / report read contracts (Task Y1 + R1).
library;

import '../../../core/money/money.dart';
import '../../models/enums.dart';
import '../../models/payment.dart';
import '../../models/report.dart';

abstract interface class PaymentRepository {
  Future<List<Payment>> paymentsFor(String ticketId);

  Stream<List<CreditEntry>> watchOpenCredit();

  Future<List<DailyTotals>> dailyRange({required DateTime from, required DateTime to});

  Future<DailyTotals> day(DateTime day);

  Future<List<PaymentMode>> modesUsedOn(DateTime day);

  Future<List<BestsellerRow>> bestsellers({required DateTime from, required DateTime to, int limit = 20});

  Future<List<HourBucket>> hourBuckets(DateTime day);

  Future<List<DueParty>> dueParties();

  /// Settles a credit row (Y4) without touching any ticket: the party pays cash
  /// at the counter against their name, not against a bill.
  Future<void> settleCredit({
    required String creditEntryId,
    required PaymentMode mode,
    required Money amount,
    required String actorId,
    String? note,
  });

  Future<void> addCredit({
    required String party,
    required Money amount,
    String? phone,
    String? note,
    String? linkedOrderId,
    required String actorId,
  });

  /// CSV for export (R4). Header + one row per day; money as plain paise ints so
  /// a spreadsheet never re-rounds what a till already settled.
  Future<String> buildCsv({required DateTime from, required DateTime to});
}
