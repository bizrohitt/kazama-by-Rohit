/// Print queue: model -> bytes -> transport, with a durable `receipts` row (P2).
///
/// Why a queue when a print is one function call: a Bluetooth write fails for
/// reasons that have nothing to do with the bill (printer asleep, paper jam, the
/// phone walked out of range mid-write). The customer has already paid, so a
/// failed print must NOT fail the sale — it must be recorded, retried, and
/// visible on the billing screen as "receipt not delivered". The `receipts`
/// table is what makes that possible across an app kill, and it doubles as the
/// reprint counter (P3).
library;

import '../../../core/db/app_database.dart';
import '../../../core/utils/id.dart';
import '../../../data/repositories/contract/order_repository.dart';
import '../../../data/repositories/contract/payment_repository.dart';
import '../../../data/models/enums.dart';
import '../../../data/models/staff.dart';
import '../domain/escpos_builder.dart';
import '../domain/receipt_model.dart';
import '../domain/receipt_text_renderer.dart';
import 'print_transport.dart';

class PrintOutcome {
  const PrintOutcome({
    required this.receiptId,
    required this.delivered,
    required this.attempts,
    this.error,
    this.textPreview = '',
  });

  final String receiptId;
  final bool delivered;
  final int attempts;
  final String? error;

  /// The plain-text bill, returned so the caller can show/preview it even when
  /// the printer was unreachable. A cashier must be able to read the change due
  /// from the screen if the paper never comes out.
  final String textPreview;

  bool get failed => !delivered;
}

class PrintingService {
  PrintingService({
    required AppDatabase db,
    required PrintTransport transport,
    required PaymentRepository payments,
    EscPosBuilder builder = const EscPosBuilder(),
    int maxAttempts = 3,
    Duration retryDelay = const Duration(milliseconds: 400),
    IdFactory? idFactory,
    Future<void> Function(Duration)? sleeper,
  }) : _db = db,
       _transport = transport,
       _payments = payments,
       _builder = builder,
       _maxAttempts = maxAttempts,
       _retryDelay = retryDelay,
       _ids = idFactory ?? IdFactory(),
       _sleep = sleeper ?? Future<void>.delayed;

  final AppDatabase _db;
  final PrintTransport _transport;
  final PaymentRepository _payments;
  final EscPosBuilder _builder;
  final int _maxAttempts;
  final Duration _retryDelay;
  final IdFactory _ids;
  final Future<void> Function(Duration) _sleep;

  /// Settings the printer needs, read here rather than passed by every caller:
  /// paper width lives in `app_meta` (set at first run, edited in P4), and a
  /// caller forgetting to read it is exactly how a 42-column bill gets printed
  /// on 32-column paper and cut off mid-total.
  Future<PrintSettings> settings() async {
    final cols = int.tryParse(await _db.metaValue(MetaKeys.printerPaperColumns) ?? '') ?? 32;
    return PrintSettings(widthColumns: cols.clamp(24, 80));
  }

  /// Prints the bill for a ticket. Never throws: a print failure is returned as
  /// `delivered: false`, because the caller's sale is already committed.
  Future<PrintOutcome> printTicket({
    required String ticketId,
    required ReceiptKind kind,
    PrinterDevice? device,
    String transportName = 'fake',
    ShopProfile? profile,
  }) async {
    final s = await settings();
    // The shop's name/address come from settings (app_meta), not from a widget:
    // a receipt printed by the retry queue at 2am has no screen to ask.
    final shop = profile ?? await shopProfile();
    final shopName = shop.name;
    final ticket = await _db.ticketById(ticketId);
    if (ticket == null) {
      throw StateError('cannot print: ticket $ticketId not found');
    }
    final payments = await _payments.paymentsFor(ticketId);
    final prior = await _db.receiptsFor(ticketId);
    final model = ReceiptModel.forTicket(
      ticket: ticket,
      payments: payments,
      shopName: shopName,
      address: shop.address,
      gstin: shop.gstin,
      phone: shop.phone,
      widthColumns: s.widthColumns,
      reprintOf: prior.length,
    );
    final bytes = _builder.build(model);
    final target = device ?? PrinterDevice(id: 'default', name: 'Default printer', paperWidthColumns: s.widthColumns);
    final receiptId = _ids.newId();

    // The row is written BEFORE the attempt: a crash during a print would
    // otherwise leave no trace of a receipt the customer may or may not have.
    await _db.insertReceipt(
      ReceiptRecord(
        id: receiptId,
        orderId: ticketId,
        kind: kind,
        transport: transportName,
        delivered: false,
        at: DateTime.now(),
        printerName: target.name,
        paperWidthColumns: s.widthColumns,
        error: 'pending',
      ),
    );

    var attempts = 0;
    String? error;
    var delivered = false;
    while (attempts < _maxAttempts) {
      attempts++;
      try {
        await _transport.send(device: target, bytes: bytes);
        delivered = true;
        break;
      } on PrintFailure catch (f) {
        error = f.message;
        if (!f.retryable) break; // no point hammering a device that says "gone"
        if (attempts < _maxAttempts) await _sleep(_retryDelay);
      } catch (e) {
        // A platform exception (unhandled UUID, closed socket) arrives as a
        // generic object; treating it as permanent would hide a transient
        // Bluetooth drop behind a "printer error" the cashier cannot fix.
        error = e.toString();
        if (attempts < _maxAttempts) await _sleep(_retryDelay);
      }
    }

    await _db.insertReceipt(
      ReceiptRecord(
        id: receiptId,
        orderId: ticketId,
        kind: kind,
        transport: transportName,
        delivered: delivered,
        at: DateTime.now(),
        printerName: target.name,
        paperWidthColumns: s.widthColumns,
        error: delivered ? null : (error ?? 'unknown failure'),
      ),
    );
    return PrintOutcome(
      receiptId: receiptId,
      delivered: delivered,
      attempts: attempts,
      error: error,
      textPreview: const ReceiptTextRenderer().render(model),
    );
  }

  Future<ShopProfile> shopProfile() async {
    final name = await _db.metaValue(MetaKeys.shopName);
    if (name == null || name.isEmpty) return ShopProfile.fallback;
    return ShopProfile(
      name: name,
      address: await _db.metaValue(MetaKeys.shopAddress),
      gstin: await _db.metaValue(MetaKeys.shopGstin),
      phone: await _db.metaValue(MetaKeys.shopPhone),
    );
  }

  Future<void> saveShopProfile(ShopProfile p) async {
    await _db.setMetaValue(MetaKeys.shopName, p.name);
    await _db.setMetaValue(MetaKeys.shopAddress, p.address ?? '');
    await _db.setMetaValue(MetaKeys.shopGstin, p.gstin ?? '');
    await _db.setMetaValue(MetaKeys.shopPhone, p.phone ?? '');
  }

  /// Undelivered receipts from the last 24 hours, oldest first (the badge on the
  /// billing screen, P3).
  Future<List<ReceiptRecord>> undelivered() async {
    final rows = await _db.select(_db.receipts).get();
    final since = DateTime.now().subtract(const Duration(days: 1));
    final out = [
      for (final r in rows)
        if (!r.delivered && r.at.isAfter(since))
          ReceiptRecord(
            id: r.id,
            orderId: r.orderId,
            kind: ReceiptKind.fromName(r.kind),
            transport: r.transport,
            delivered: r.delivered,
            at: r.at,
            printerName: r.printerName,
            paperWidthColumns: r.paperWidthColumns,
            error: r.error,
          ),
    ]..sort((a, b) => a.at.compareTo(b.at));
    return out;
  }
}

final class PrintSettings {
  const PrintSettings({required this.widthColumns});
  final int widthColumns;
}

/// Header block printed on every slip. Four meta keys, one type: keeping it in
/// `app_meta` (rather than a table) means a restore carries it and no migration
/// is needed when a shop adds a GSTIN.
final class ShopProfile {
  const ShopProfile({required this.name, this.address, this.gstin, this.phone});

  final String name;
  final String? address;
  final String? gstin;
  final String? phone;

  static const ShopProfile fallback = ShopProfile(name: 'Kazama POS');
}
