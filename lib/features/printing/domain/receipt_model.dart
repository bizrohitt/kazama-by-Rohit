/// The receipt as a printer-agnostic line model (Task P1).
///
/// Two layers, deliberately: `ReceiptModel` is "what the customer must see"
/// (content + alignment + emphasis), and a renderer turns that into either plain
/// text (tests, SMS/WhatsApp preview) or ESC/POS bytes (a real printer). A model
/// built directly for ESC/POS would make the *content* untestable without a
/// printer, which is exactly how a wrong total ends up on paper.
///
/// Width, not millimetres: a 58 mm roll is 32 columns at font A and 48 at font B.
/// The setting stored in `app_meta` is the column count for precisely that reason
/// — the renderer never has to know about paper.
library;

import '../../../core/money/money.dart';
import '../../models/enums.dart';
import '../../models/payment.dart';
import '../../models/order.dart';
import 'receipt_text_renderer.dart';

enum ReceiptAlign { left, center, right }

enum ReceiptEmphasis { regular, bold, double }

/// One printed line. No trailing newline: the renderer owns line breaks, because
/// "what fits on a line" is the width question and belongs in one place.
final class ReceiptLineModel {
  const ReceiptLineModel(
    this.text, {
    this.align = ReceiptAlign.left,
    this.emphasis = ReceiptEmphasis.regular,
    this.dashed = false,
    this.feed = 0,
  });

  /// A rule across the paper. `dashed` rather than a literal '----' string: the
  /// renderer fills it to the exact width, so 32/42/80-column receipts all get a
  /// full rule instead of a short one.
  ReceiptLineModel.rule() : this('', dashed: true);

  ReceiptLineModel.blank({int feed = 1}) : this('', feed: feed);

  final String text;
  final ReceiptAlign align;
  final ReceiptEmphasis emphasis;
  final bool dashed;

  /// Extra blank lines AFTER this one (the barcode/cut area uses this).
  final int feed;

  @override
  String toString() => '[$align/${emphasis.name}] "$text"${dashed ? ' (rule)' : ''}';
}

/// A printed document: bill, due/token, or void notice (P1).
final class ReceiptModel {
  const ReceiptModel({
    required this.kind,
    required this.headerLines,
    required this.body,
    required this.footerLines,
    required this.widthColumns,
  });

  final ReceiptKind kind;
  final List<ReceiptLineModel> headerLines;
  final List<ReceiptLineModel> body;
  final List<ReceiptLineModel> footerLines;

  /// Columns of paper available at font A. Read from settings, never hardcoded.
  final int widthColumns;

  List<ReceiptLineModel> get lines => [...headerLines, ...body, ...footerLines];

  /// A bill receipt: shop header, lines with modifiers, tax/discount/rounding,
  /// payment split, and an explicit DUE when the ticket is not settled.
  ///
  /// Every number printed comes from `ticket.totals` (the same computation that
  /// the paid/due caches are checked against), and `payments` is the ledger —
  /// so a receipt can never disagree with the bill it was printed from.
  static ReceiptModel forTicket({
    required OrderTicket ticket,
    required List<Payment> payments,
    required String shopName,
    required String? address,
    required String? gstin,
    required String? phone,
    required int widthColumns,
    int reprintOf = 0,
    bool showTax = true,
    bool showPrices = true,
  }) {
    final w = widthColumns;
    final t = ticket.totals;
    final header = <ReceiptLineModel>[
      ReceiptLineModel(shopName, align: ReceiptAlign.center, emphasis: ReceiptEmphasis.double),
      if (address != null && address.isNotEmpty) ...[
        for (final l in _wrap(address, w)) ReceiptLineModel(l, align: ReceiptAlign.center),
      ],
      if (phone != null && phone.isNotEmpty) ReceiptLineModel('Ph: $phone', align: ReceiptAlign.center),
      if (gstin != null && gstin.isNotEmpty) ReceiptLineModel('GSTIN: $gstin', align: ReceiptAlign.center),
      ReceiptLineModel.rule(),
      ReceiptLineModel('${ticket.type.label}   Bill ${ticket.billNumber ?? '-'}'),
      ReceiptLineModel(
        _dualLeftRight(
          'Date ${_stamp(ticket.openedAt)}',
          ticket.tableOrName == null ? '' : '${ticket.tableOrName}',
          w,
        ),
      ),
      ReceiptLineModel.rule(),
    ];

    final body = <ReceiptLineModel>[
      if (ticket.lines.isEmpty)
        const ReceiptLineModel('(no items)')
      else
        for (final l in ticket.lines) ..._lineBlock(l, w, showPrices: showPrices),
      ReceiptLineModel.rule(),
      if (showPrices) _row('SUBTOTAL', _rupees(t.lineBase), w),
      if (showPrices && t.discount.isPositive) _row('DISCOUNT', '-${_rupees(t.discount)}', w),
      if (showPrices && showTax) _row('GST', _rupees(t.tax), w),
      if (showPrices && !t.rounding.isZero) _row('ROUNDING', _rupeesDelta(t.rounding.paise), w),
      ReceiptLineModel.rule(),
      if (showPrices)
        ReceiptLineModel(
          _dualLeftRight('TOTAL', _rupees(t.total), w),
          emphasis: ReceiptEmphasis.bold,
        ),
      if (showPrices) ReceiptLineModel.rule(),
    ];

    if (showPrices && payments.isNotEmpty) {
      body.add(const ReceiptLineModel('PAYMENT'));
      for (final p in payments) {
        body.add(_row('  ${p.mode.label}', _rupees(p.amount), w));
        if (p.change != null && p.change!.isPositive) {
          body.add(_row('  Change returned', _rupees(p.change!), w));
        }
        if (p.reference != null) body.add(ReceiptLineModel('  Ref: ${p.reference}'));
      }
      body.add(ReceiptLineModel.rule());
    }
    if (showPrices && !ticket.due.isZero) {
      body.add(ReceiptLineModel(_dualLeftRight('DUE', _rupees(ticket.due), w), emphasis: ReceiptEmphasis.bold));
      body.add(ReceiptLineModel.rule());
    }

    final footer = <ReceiptLineModel>[
      const ReceiptLineModel('Thank you - please come again', align: ReceiptAlign.center),
      ReceiptLineModel(_stamp(DateTime.now()), align: ReceiptAlign.center),
      if (reprintOf > 0)
        ReceiptLineModel('*** DUPLICATE COPY $reprintOf ***', align: ReceiptAlign.center, emphasis: ReceiptEmphasis.bold),
      // A KOT says so at the top: a cook who mistakes a reprint for a second
      // order makes duplicate food, and that waste never shows up in the till's
      // numbers.
      if (kind == ReceiptKind.kitchen)
        ReceiptLineModel('*** KITCHEN ***', align: ReceiptAlign.center, emphasis: ReceiptEmphasis.double),
      if (ticket.status == OrderStatus.voided)
        ReceiptLineModel('VOID: ${ticket.voidReason ?? '-'}', align: ReceiptAlign.center, emphasis: ReceiptEmphasis.double),
      // Four feeds: past the tear bar on the cheap printers, which cut short.
      const ReceiptLineModel('', feed: 4),
    ];

    return ReceiptModel(
      kind: ticket.due.isPositive && !ticket.status.isSettled ? ReceiptKind.due : ReceiptKind.sale,
      headerLines: header,
      body: body,
      footerLines: footer,
      widthColumns: w,
    );
  }

  /// The kitchen slip (K4): bill number, table, quantities, modifiers, notes —
  /// and NO money anywhere, by construction. There is no `showPrices` argument to
  /// forget here: this factory cannot build a priced slip, so "the KOT leaked the
  /// prices" is not a mistake a counter can configure into existence.
  static ReceiptModel forKitchenTicket({
    required OrderTicket ticket,
    required String shopName,
    required int widthColumns,
    int reprintOf = 0,
  }) {
    final model = forTicket(
      ticket: ticket,
      // An empty ledger makes the absence of payment/DUE lines true rather than
      // merely likely, and reuses the one layout that already wraps at width.
      payments: const <Payment>[],
      shopName: shopName,
      address: null,
      gstin: null,
      phone: null,
      widthColumns: widthColumns,
      reprintOf: reprintOf,
      showPrices: false,
    );
    return ReceiptModel(
      kind: ReceiptKind.kitchen,
      headerLines: model.headerLines,
      body: model.body,
      footerLines: model.footerLines,
      widthColumns: widthColumns,
    );
  }

  /// Item name + amount on one line, modifiers underneath, exactly the two-row
  /// layout a 32-column bill can actually hold (a single-row "name ... qty price"
  /// truncates "Chicken Hakka Noodles" on the common printer).
  /// `showPrices: false` is the kitchen slip (K4): the same block, minus every
  /// money figure — a cook must not have to edit a printed ticket to hide a price
  /// from a customer standing at the pass.
  static List<ReceiptLineModel> _lineBlock(TicketLine l, int w, {bool showPrices = true}) {
    final qty = l.quantity;
    final left = '$qty x ${l.nameSnapshot}';
    final right = showPrices ? _rupees(l.lineTotal) : '';
    final out = <ReceiptLineModel>[
      ReceiptLineModel(_dualLeftRight(left, right, w)),
    ];
    for (final m in l.modifiers) {
      if (showPrices && m.priceDelta.isPositive) {
        out.add(ReceiptLineModel('  + ${m.name} (${_rupees(m.priceDelta)})'));
      } else {
        out.add(ReceiptLineModel('  + ${m.name}'));
      }
    }
    if (l.note != null && l.note!.isNotEmpty) out.add(ReceiptLineModel('  * ${l.note}'));
    if (l.cancelledQuantity > 0) {
      out.add(ReceiptLineModel('  (${l.cancelledQuantity} cancelled)'));
    }
    // Per-line tax is NOT printed on a 32-col bill: the tax is inclusive and the
    // GST summary line is what a customer is entitled to see. A 42/80-col layout
    // can add it later without changing this model (P1 decision, documented).
    return out;
  }

  static ReceiptLineModel _row(String label, String value, int w) =>
      ReceiptLineModel(_dualLeftRight(label, value, w));

  /// `label  value`, value flush right. Two rules protect the money:
  ///  * a label longer than the paper is NOT truncated here — the renderer
  ///    wraps it, and a silently-clipped item name is a receipt nobody can
  ///    dispute accurately;
  ///  * if label+value cannot share a line, the value drops to its own line
  ///    rather than losing digits. A truncated *amount* is the one defect a
  ///    thermal receipt must never have, so the layout gives up alignment first.
  static String _dualLeftRight(String left, String right, int w) {
    if (right.isEmpty) return left;
    if (left.length + 2 <= w && left.length + 1 + right.length <= w) {
      final pad = (w - left.length - right.length).clamp(1, w);
      return '$left${' ' * pad}$right';
    }
    return '$left\n$right';
  }

  static List<String> _wrap(String s, int w) {
    final words = s.split(RegExp(r'\s+'));
    final out = <String>[];
    var line = '';
    for (final word in words) {
      if (line.isEmpty) {
        line = word;
      } else if (line.length + 1 + word.length <= w) {
        line = '$line $word';
      } else {
        out.add(line);
        line = word;
      }
    }
    if (line.isNotEmpty) out.add(line);
    return out.isEmpty ? const [''] : out;
  }

  /// ASCII, no ₹ glyph: ESC/POS code pages vary, and a missing glyph prints as a
  /// random character on the cheap models — a garbled amount is worse than a
  /// plain one. The text renderer keeps the same numbers so tests match paper.
  static String _rupees(Money m) => m.toCompactString();

  static String _rupeesDelta(int paise) {
    final sign = paise < 0 ? '-' : '+';
    final abs = paise.abs();
    return '$sign${(abs ~/ 100).toString()}.${(abs % 100).toString().padLeft(2, '0')}';
  }

  /// `dd/MM HH:mm` — 24h, day first (Indian convention), no year on a till slip.
  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}/${two(t.month)} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// A bill rendered to text for a settings screen (P4 preview). Lives with the
/// model rather than in `features/reports` so the report page does not have to
/// know that a receipt is built from `ticket.totals` — one less place that can
/// disagree with the printer.
class ReceiptTextPreview {
  const ReceiptTextPreview._();

  static String render({
    required OrderTicket ticket,
    required List<Payment> payments,
    required String shopName,
    String? address,
    String? gstin,
    String? phone,
    required int columns,
  }) =>
      ReceiptTextRenderer().render(
        ReceiptModel.forTicket(
          ticket: ticket,
          payments: payments,
          shopName: shopName,
          address: address,
          gstin: gstin,
          phone: phone,
          widthColumns: columns,
        ),
      );
}
