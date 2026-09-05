/// Plain-text receipt renderer (Task P1).
///
/// This is the renderer the tests assert on, and the one a WhatsApp/SMS bill
/// preview would reuse — which is why it produces the SAME layout as the thermal
/// print rather than a nicer-looking different one. If text and paper ever
/// disagree, `test/features/printing/receipt_render_test.dart` fails, and that
/// is the whole point of having both renderers read one model.
library;

import 'receipt_model.dart';

class ReceiptTextRenderer {
  const ReceiptTextRenderer();

  /// `showRuler: true` draws a column ruler, so an off-by-one width bug is
  /// visible in the test output instead of counted by hand.
  String render(ReceiptModel r, {bool showRuler = false}) {
    final w = r.widthColumns;
    final b = StringBuffer();
    if (showRuler) b.writeln('|${_ruler(w)}|');
    for (final l in r.lines) {
      for (final line in layout(l, w)) {
        b.writeln(line);
      }
      for (var i = 0; i < l.feed; i++) {
        b.writeln();
      }
    }
    return b.toString();
  }

  /// One model line -> 1..n rendered lines of at most `w` cells.
  ///
  /// Long text WRAPS instead of truncating: a bill that hides half an item name
  /// is a bill the customer cannot check, and on a 32-column roll that happens
  /// with normal dish names ("Chicken Hakka Noodles 1 x ..."), not just with
  /// adversarial input.
  List<String> layout(ReceiptLineModel l, int w) {
    if (l.dashed) return ['- ' * ((w - 2) ~/ 2) + '--'];
    final lines = l.text.isEmpty ? <String>[''] : _wrap(l.text, w);
    if (l.align == ReceiptAlign.center) {
      return [for (final s in lines) s.center(w)];
    }
    return lines;
  }

  static List<String> _wrap(String s, int w) {
    if (w <= 0) return [s];
    if (s.length <= w) return [s];
    final words = s.split(RegExp(r'\s+'));
    final out = <String>[];
    var line = '';
    for (var word in words) {
      // A single word longer than the paper (a URL, a long name) is broken
      // rather than dropped; `substring` here can never overflow because the
      // guard above already proved `word.length > w`.
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

  static String _ruler(int w) {
    final full = '1234567890' * (w ~/ 10);
    final tail = '123456789'.substring(0, w % 10);
    return '$full$tail'
        .padRight(w, ' ')
        .substring(0, w > 0 ? w : 0);
  }
}
