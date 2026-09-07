/// ESC/POS byte builder (Task P3) — the only file that knows printer commands.
///
/// Kept free of any Flutter import so `dart run tools/check_escpos.dart` (and a
/// plain widget-less test) can assert the exact bytes. Command set is the
/// generic ESC/POS subset every 58 mm Chinese-model printer supports — the ones
/// this shop can actually buy: ESC @, ESC a, ESC E, GS ! and ESC d. No vendor
/// SDK, no image/logo commands, no codepage switching beyond ASCII-safe text.
library;

import 'dart:convert';

import 'receipt_model.dart';

class EscPosBuilder {
  const EscPosBuilder({this.feedLinesOnCut = 3});

  /// Lines fed before the partial cut. Cheap printers have the tear bar a few
  /// lines above the cutter; feeding 3 is what makes the receipt detachable
  /// rather than half-cut through the total line.
  final int feedLinesOnCut;

  static const int esc = 0x1b;
  static const int gs = 0x1d;
  static const int lf = 0x0a;

  /// Builds a full job: init, style+text per line, feed, cut.
  ///
  /// `boldUnderscore: true` renders `ReceiptEmphasis.bold` as
  /// `*surrounding stars*` IN ADDITION to the bold command, for the many 58 mm
  /// clones whose ESC E is ignored by firmware. A receipt whose total is not
  /// visibly the total is a support call you cannot reproduce, so this defaults
  /// on and the setting exists for shops whose printer does it well.
  List<int> build(
    ReceiptModel r, {
    int? charWidth,
    bool boldUnderscore = true,
    bool cut = true,
  }) {
    final w = charWidth ?? r.widthColumns;
    final out = <int>[];
    out.addAll(init);
    for (final l in r.lines) {
      for (final line in _layoutFor(l, w)) {
        out.addAll(_styleFor(l, line, boldUnderscore: boldUnderscore));
        out.add(lf);
      }
      for (var i = 0; i < l.feed; i++) {
        out.add(lf);
      }
    }
    if (cut) {
      for (var i = 0; i < feedLinesOnCut; i++) {
        out.add(lf);
      }
      out.addAll(partialCut);
    }
    return out;
  }

  /// Same wrapping rule as the text renderer, duplicated deliberately small:
  /// the renderer needs it for display, this one needs it to know where to put
  /// LF. If they ever diverge the test `text and paper wrap identically` fails.
  List<String> _layoutFor(ReceiptLineModel l, int w) {
    if (l.dashed) return ['- ' * ((w - 2) ~/ 2) + '--'];
    if (l.text.isEmpty) return const [''];
    final lines = l.text.split('\n');
    final out = <String>[];
    for (final part in lines) {
      out.addAll(_wrap(part, w));
    }
    // CENTRE IS DELEGATED TO THE PRINTER, not padded here. The model's
    // left/right rows are already laid out to exactly `w` cells by
    // `_dualLeftRight`, so those must NOT be padded twice; a centred shop name
    // is short, and `ESC a 1` places it against the printer's *own* margin,
    // which is the only way it stays centred on a roll whose usable width is
    // one or two cells narrower than the nominal 32.
    if (l.align == ReceiptAlign.center) return out;
    return [for (final line in out) line.padRight(w)];
  }

  static List<String> _wrap(String s, int w) {
    if (s.length <= w) return [s];
    final words = s.split(RegExp(r'\s+'));
    final out = <String>[];
    var line = '';
    for (var word in words) {
      while (word.length > w) {
        if (line.isNotEmpty) {
          out.add(line);
          line = '';
        }
        out.add(word.substring(0, w));
        word = word.substring(w);
      }
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
    return out.isEmpty ? <String>[''] : out;
  }

  List<int> _styleFor(ReceiptLineModel l, String text, {required bool boldUnderscore}) {
    final bytes = <int>[];
    bytes.addAll(align(l.align));
    switch (l.emphasis) {
      case ReceiptEmphasis.double:
        bytes.addAll(doubleSizeOn);
      case ReceiptEmphasis.bold:
        bytes.addAll(boldOn);
      case ReceiptEmphasis.regular:
        break;
    }
    if (boldUnderscore && l.emphasis == ReceiptEmphasis.bold) {
      bytes.addAll(utf8.encode('*$text*'));
    } else {
      bytes.addAll(utf8.encode(text));
    }
    // Style is reset per line rather than per document: a dropped packet in the
    // middle of a long bill must not leave the rest of the roll in double size.
    switch (l.emphasis) {
      case ReceiptEmphasis.double:
        bytes.addAll(doubleSizeOff);
      case ReceiptEmphasis.bold:
        bytes.addAll(boldOff);
      case ReceiptEmphasis.regular:
        break;
    }
    return bytes;
  }

  // ------------------------------------------------------- raw command bytes --

  /// ESC @  — initialise: clears the line buffer and resets style, so a receipt
  /// printed after a power blip starts from a known state.
  static const List<int> init = [esc, 0x40];

  /// ESC a n — align (0 left, 1 centre, 2 right).
  static List<int> align(ReceiptAlign a) => [
    esc,
    0x61,
    switch (a) {
      ReceiptAlign.left => 0,
      ReceiptAlign.center => 1,
      ReceiptAlign.right => 2,
    },
  ];

  /// ESC E n — bold.
  static const List<int> boldOn = [esc, 0x45, 0x01];
  static const List<int> boldOff = [esc, 0x45, 0x00];

  /// GS ! n — character size; 0x11 = double width+height, 0x00 = normal.
  static const List<int> doubleSizeOn = [gs, 0x21, 0x11];
  static const List<int> doubleSizeOff = [gs, 0x21, 0x00];

  /// GS V m — paper cut. 66 = feed then partial cut (the mode 58 mm printers
  /// have; most have no full cut at all).
  static const List<int> partialCut = [gs, 0x56, 0x42, 0x00];

  /// ESC d n — print and feed n lines. Used for the trailing feed when a
  /// transport cannot be trusted to handle bare LFs after a cut.
  static List<int> feed(int n) => [esc, 0x64, n.clamp(0, 255)];
}
