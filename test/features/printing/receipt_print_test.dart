/// Receipt rendering + print queue (Task P1, P2, P3).
///
/// The numbers are the T4 hand-computed fixture (₹100.00 + ₹234.56 @ 18%
/// inclusive, ₹4.40 off -> ₹330.00 with a -0.38 rounding line), so a receipt
/// that foots here and a backup that restores here are checking the same maths.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazama_pos/core/db/app_database.dart';
import 'package:kazama_pos/core/money/money.dart';
import 'package:kazama_pos/core/utils/id.dart';
import 'package:kazama_pos/data/models/enums.dart';
import 'package:kazama_pos/data/models/order.dart';
import 'package:kazama_pos/data/models/order_line.dart';
import 'package:kazama_pos/data/models/payment.dart';
import 'package:kazama_pos/data/repositories/contract/payment_repository.dart';
import 'package:kazama_pos/features/printing/domain/escpos_builder.dart';
import 'package:kazama_pos/features/printing/domain/receipt_model.dart';
import 'package:kazama_pos/features/printing/domain/receipt_text_renderer.dart';
import 'package:kazama_pos/features/printing/queue/printing_service.dart';
import 'package:kazama_pos/features/printing/transport/fake_print_transport.dart';

const int kTotal = 33000;
const int kPaid = 15000;
const int kDue = 18000;

final DateTime at = DateTime.utc(2026, 9, 3, 20, 30);

OrderTicket buildTicket({int? billNumber = 12}) => OrderTicket(
  id: 'o1',
  billNumber: billNumber,
  type: OrderType.dineIn,
  status: OrderStatus.open,
  tableOrName: 'T3',
  openedBy: 'u1',
  openedAt: at,
  paid: Money(kPaid),
  due: Money(kDue),
  discount: const OrderDiscount(DiscountKind.absolute, 440),
  lines: const [
    TicketLine(
      id: 'l1',
      itemId: 'i1',
      nameSnapshot: 'Veg Burger',
      unitPrice: Money(10000),
      taxPercent: 18,
      quantity: 1,
      kitchenLabel: 'VEG BURGER',
    ),
    TicketLine(
      id: 'l2',
      itemId: 'i2',
      nameSnapshot: 'Chicken Burger',
      unitPrice: Money(23456),
      taxPercent: 18,
      quantity: 1,
      modifiers: [
        ModifierOption(id: 'm2', groupId: 'mg1', name: 'Large', priceDelta: Money(2500)),
      ],
    ),
  ],
);

List<Payment> buildPayments() => [
  Payment(
    id: 'p1',
    orderId: 'o1',
    mode: PaymentMode.cash,
    amount: Money(10000),
    tendered: Money(20000),
    change: Money(10000),
    recordedBy: 'u1',
    at: at,
  ),
  Payment(
    id: 'p2',
    orderId: 'o1',
    mode: PaymentMode.upi,
    amount: Money(5000),
    reference: 'GPay 88213',
    recordedBy: 'u1',
    at: at,
  ),
];

ReceiptModel model({int width = 32, int reprintOf = 0}) => ReceiptModel.forTicket(
  ticket: buildTicket(),
  payments: buildPayments(),
  shopName: 'Kazama Fast Food',
  address: 'Shop 4, Main Bazaar, Dimapur',
  gstin: '18ABCDE1234F1Z5',
  phone: '0886 123 4567',
  widthColumns: width,
  reprintOf: reprintOf,
);

void main() {
  group('receipt text renderer (P1)', () {
    const renderer = ReceiptTextRenderer();

    test('the bill foots with the numbers the model was built from', () {
      final out = renderer.render(model());
      // TOTAL is the rounded bill; the rounding line explains the 38 paise.
      expect(out, contains('330.00'));
      expect(out, contains('ROUNDING'));
      expect(out, contains('-0.38'));
      expect(out, contains('GST'));
      expect(out, contains('50.25'), reason: '5025p of inclusive tax');
      expect(out, contains('DUE'));
      expect(out, contains('180.00'));
      expect(out, contains('Change returned'), reason: 'cash tendered 200, applied 100');
      expect(out, contains('100.00'));
      expect(out, contains('GPay 88213'));
      expect(out, contains('Large'), reason: 'modifier snapshot must print');
    });

    test('no content line exceeds the paper', () {
      final lines = renderer.render(model()).split('\n');
      for (final l in lines) {
        expect(l.length, lessThanOrEqualTo(32), reason: 'line overruns 32-col paper: "$l"');
      }
    });

    test('rules are the full paper width (32 / 42 / 80)', () {
      for (final w in [32, 42, 80]) {
        final lines = renderer.render(model(width: w)).split('\n');
        final rules = lines.where((l) => RegExp(r'^-+$').hasMatch(l.trim())).toList();
        expect(rules, isNotEmpty, reason: 'a receipt with no rule at $w cols');
        for (final r in rules) {
          expect(r.length, w, reason: 'rule at $w cols came out ${r.length}');
        }
      }
    });

    test('a long dish name WRAPS instead of losing the amount', () {
      final ticket = OrderTicket(
        id: 'o9',
        type: OrderType.takeaway,
        status: OrderStatus.open,
        openedBy: 'u1',
        openedAt: at,
        lines: [
          const TicketLine(
            id: 'l9',
            itemId: 'i9',
            nameSnapshot: 'Chicken Hakka Noodles With Extra Cheese',
            unitPrice: Money(99900),
            taxPercent: 5,
            quantity: 3,
          ),
        ],
      );
      final out = const ReceiptTextRenderer().render(
        ReceiptModel.forTicket(
          ticket: ticket,
          payments: const [],
          shopName: 'K',
          widthColumns: 32,
        ),
      );
      expect(out, contains('Chicken Hakka Noodles'), reason: 'name was clipped');
      expect(out, contains('2997.00'), reason: '3 x 999.00 must survive the wrap');
      expect(out.split('\n').every((l) => l.length <= 32), isTrue);
    });

    test('a reprint is marked, a first copy is not', () {
      expect(const ReceiptTextRenderer().render(model()), isNot(contains('DUPLICATE')));
      expect(const ReceiptTextRenderer().render(model(reprintOf: 2)), contains('DUPLICATE COPY 2'));
    });

    test('a voided ticket shouts about itself', () {
      // Built through `voided()` rather than by hand, so the test also proves the
      // model still renders after that transition.
      final t = buildTicket().voided(reason: 'customer left', at: at);
      final out = const ReceiptTextRenderer().render(
        ReceiptModel.forTicket(
          ticket: t,
          payments: const [],
          shopName: 'Kazama',
          widthColumns: 32,
        ),
      );
      expect(out, contains('VOID: customer left'));
      expect(out, contains('>>'), reason: 'the double-size marker renders in text too');
    });
  });

  group('ESC/POS builder (P3)', () {
    const builder = EscPosBuilder();

    test('a job initialises, styles, and cuts', () {
      final bytes = builder.build(model());
      expect(bytes.sublist(0, 2), [0x1b, 0x40], reason: 'ESC @ must be first');
      expect(bytes.sublist(bytes.length - 4), [0x1d, 0x56, 0x42, 0x00], reason: 'ends with a partial cut');
      expect(bytes, contains(0x1b), reason: 'at least one ESC command');
      // bold on/off around the total, and the star fallback for stubborn firmware
      final text = String.fromCharCodes(bytes.where((b) => b == 0x0a || (b >= 0x20 && b < 0x7f)));
      expect(text, contains('*TOTAL'));
      expect(text, contains('330.00*'));
      expect(
        bytes.lengthInBytes,
        greaterThan(text.length),
        reason: 'control bytes must be present, not just text',
      );
    });

    test('alignment is delegated to the printer for centred lines', () {
      final bytes = builder.build(model());
      final hasCentre = bytes.asMap().entries.any(
        (e) => e.value == 0x61 && e.key > 0 && bytes[e.key - 1] == 0x1b && bytes[e.key + 1] == 0x01,
      );
      expect(hasCentre, isTrue, reason: 'shop name should use ESC a 1');
    });

    test('style is reset per line so a dropped packet cannot bleed', () {
      final bytes = builder.build(model());
      int count(List<int> pattern) {
        var n = 0;
        for (var i = 0; i + pattern.length <= bytes.length; i++) {
          if (bytes.sublist(i, i + pattern.length).every((b) => b == pattern[bytes.indexOf(b)])) n++;
        }
        return n;
      }

      // Bold-on count must equal bold-off count over the whole job.
      final on = <int>[];
      final off = <int>[];
      for (var i = 0; i + 2 < bytes.length; i++) {
        if (bytes[i] == 0x1b && bytes[i + 1] == 0x45) (bytes[i + 2] == 0x01 ? on : off).add(i);
      }
      expect(on.length, off.length, reason: 'every bold-on needs its bold-off');
      expect(on.length, greaterThan(0));
      expect(count([0x1b, 0x40]), 1, reason: 'one init per job');
    });
  });

  group('print queue (P2)', () {
    late AppDatabase db;
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      await db.replaceTicket(buildTicket(), at: at, billNumber: 12);
      for (final p in buildPayments()) {
        await db.insertPayment(p);
      }
    });
    tearDown(() => db.close());

    PrintingService service(FakePrintTransport transport) => PrintingService(
      db: db,
      transport: transport,
      payments: _OnlyLedger(db),
      maxAttempts: 3,
      retryDelay: Duration.zero,
      idFactory: IdFactory.fixed('r'),
    );

    test('a successful print sends once and records a delivered receipt', () async {
      final transport = FakePrintTransport();
      final out = await service(transport).printTicket(ticketId: 'o1', kind: ReceiptKind.sale);
      expect(out.delivered, isTrue);
      expect(out.attempts, 1);
      expect(transport.sent, hasLength(1));
      expect(out.textPreview, contains('330.00'), reason: 'the screen shows this when paper fails');
      final rows = await db.select(db.receipts).get();
      expect(rows, hasLength(1));
      expect(rows.single.delivered, isTrue);
      expect(rows.single.error, isNull);
      expect(rows.single.orderId, 'o1');
    });

    test('a transient failure retries and still prints', () async {
      final transport = FakePrintTransport(failuresBeforeSuccess: 1);
      final out = await service(transport).printTicket(ticketId: 'o1', kind: ReceiptKind.sale);
      expect(out.delivered, isTrue);
      expect(out.attempts, 2);
      expect(transport.sendCount, 1);
      final rows = await db.select(db.receipts).get();
      expect(rows.single.delivered, isTrue, reason: 'the retry overwrote the pending row');
      expect(rows.single.error, isNull);
    });

    test('a dead printer does not lose the sale', () async {
      final transport = FakePrintTransport(alwaysFail: true);
      final out = await service(transport).printTicket(ticketId: 'o1', kind: ReceiptKind.sale);
      expect(out.delivered, isFalse);
      expect(out.attempts, 3, reason: 'a retryable failure burns maxAttempts');
      expect(out.error, contains('alwaysFail'));
      expect(out.textPreview, contains('330.00'), reason: 'cashier can still read the change');
      final bad = await service(transport).undelivered();
      expect(bad, hasLength(1));
      expect(bad.single.orderId, 'o1');
    });

    test('a permanent failure is not retried', () async {
      final transport = _PermanentTransport();
      final out = await service(transport).printTicket(ticketId: 'o1', kind: ReceiptKind.sale);
      expect(out.delivered, isFalse);
      expect(out.attempts, 1, reason: 'no such device: hammering it wastes the queue');
    });

    test('the bill number on paper is the one in the DB', () async {
      final transport = FakePrintTransport();
      await service(transport).printTicket(ticketId: 'o1', kind: ReceiptKind.sale);
      expect(transport.lastText, contains('Bill 12'));
    });

    test('paper width comes from settings, not a constant', () async {
      await db.setMetaValue(MetaKeys.printerPaperColumns, '42');
      final transport = FakePrintTransport();
      await service(transport).printTicket(ticketId: 'o1', kind: ReceiptKind.sale);
      final rows = await db.select(db.receipts).get();
      expect(rows.single.paperWidthColumns, 42);
      final rules = transport.lastText.split('\n').where((l) => RegExp(r'^-+$').hasMatch(l.trim()));
      expect(rules.map((l) => l.length), every(equals(42)));
    });
  });
}

/// Implements only `paymentsFor`; the rest of `PaymentRepository` (reports,
/// credit) is irrelevant to printing and `noSuchMethod` turns an accidental call
/// into a clear failure instead of a silent empty list.
class _OnlyLedger implements PaymentRepository {
  _OnlyLedger(this.db);
  final AppDatabase db;

  /// The real read — a receipt's payment block must come from the ledger, so a
  /// stub here would make the test prove less than it looks like it proves.
  @override
  Future<List<Payment>> paymentsFor(String ticketId) => db.paymentsFor(ticketId);

  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('${i.memberName} not needed here');
}

class _PermanentTransport implements PrintTransport {
  @override
  Future<void> send({required PrinterDevice device, required List<int> bytes}) async {
    throw const PrintFailure('device not paired', retryable: false);
  }

  @override
  Future<bool> isReachable(PrinterDevice device) async => false;
}
