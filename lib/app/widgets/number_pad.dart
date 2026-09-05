/// Shared numeric keypad (S1 sign-in, Y2 tender entry, I2 quantities).
///
/// One widget for all three because a POS must not have two different ways to
/// type a number: the PIN pad needs a large 0-9 grid with a backspace and no
/// decimal point, and the tender pad needs the same grid *plus* quick amounts.
/// Both are this, configured — not two screens that drift apart when someone
/// "improves" the layout of one.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NumberPad extends StatelessWidget {
  const NumberPad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    required this.onClear,
    this.onDecimal,
    this.extraKeys = const <Widget>[],
    this.textStyle = const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
  });

  final ValueChanged<int> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback? onDecimal;

  /// e.g. "₹100", "₹500", "Exact", "+5 min" — same size, same feel, one grid.
  final List<Widget> extraKeys;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget key(String label, VoidCallback onTap, {bool important = false}) => Padding(
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        height: 60,
        child: important
            ? FilledButton(onPressed: onTap, child: Text(label, style: theme.textTheme.labelLarge))
            : OutlinedButton(
                onPressed: onTap,
                child: Text(label, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurface)),
              ),
      ),
    );

    final rows = <List<Widget>>[
      for (final row in const ['123', '456', '789']) [
        for (final ch in row.split('')) key(ch, () => onDigit(int.parse(ch))),
      ],
      [
        key('C', onClear),
        key('0', () => onDigit(0)),
        IconButton(
          onPressed: onBackspace,
          iconSize: 30,
          tooltip: 'Delete',
          icon: const Icon(Icons.backspace_outlined),
        ),
      ],
    ];
    if (onDecimal != null) {
      rows.last[0] = key('.', onDecimal!);
    }
    for (final extra in extraKeys) {
      rows.add([Padding(padding: const EdgeInsets.all(4), child: SizedBox(width: double.infinity, height: 56, child: extra))]);
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in rows)
          Row(children: [for (final k in r) Expanded(child: k)]),
      ],
    );
  }
}

/// A digit-buffer that only ever holds digits (and one optional decimal point).
/// Lives next to the pad because the *rules* are the pad's: max length, no
/// leading zeros, one dot. A screen that re-implements them gets them subtly
/// different, and "the PIN accepted 000000" is a real bug in that design.
class DigitBuffer {
  /// `initial` is seeded through the same `append` rules rather than by writing
  /// the buffer directly, so a pre-filled amount can never smuggle in a third
  /// decimal digit or a length beyond `maxLength`.
  DigitBuffer({this.maxLength = 6, this.allowDecimal = false, this.onChange, String initial = ''}) {
    append(initial);
  }

  final int maxLength;
  final bool allowDecimal;
  final VoidCallback? onChange;

  final StringBuffer _s = StringBuffer();
  int _len = 0;

  String get text => _s.toString();
  bool get isEmpty => _len == 0;
  bool get isNotEmpty => _len > 0;
  int get length => _len;

  /// Appends one character at a time, because every rule is per-character: max
  /// length, one decimal point, and a leading zero that is meaningful for a PIN
  /// but not for an amount. A paste of "12.5" therefore becomes "12.5" or
  /// "125" depending on the mode, never "12.5abc".
  void append(String chars) {
    for (final ch in chars.split('')) {
      if (_len >= maxLength) break;
      final isDot = ch == '.';
      if (!isDot && !_isDigit(ch)) continue;
      if (isDot && !allowDecimal) continue;
      if (allowDecimal) {
        final cur = text;
        // An amount never starts with '.' or with a lone '0' (`0.50` is typed
        // `.50`? no — it is typed `50` in the paise-free UI, so a leading zero
        // is always a mistake here, unlike in a PIN).
        if (cur.isEmpty && (isDot || ch == '0')) continue;
        if (isDot && cur.contains('.')) continue; // one decimal point
        if (cur.contains('.') && cur.split('.').last.length >= 2) continue; // 2 dp
      }
      _s.write(ch);
      _len++;
    }
    onChange?.call();
  }

  void appendDigit(int d) => append('$d');

  void backspace() {
    if (_len == 0) return;
    final s = text;
    _s
      ..clear()
      ..write(s.substring(0, s.length - 1));
    _len--;
    onChange?.call();
  }

  void clear() {
    _s.clear();
    _len = 0;
    onChange?.call();
  }

  static bool _isDigit(String ch) {
    final code = ch.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }

  HapticFeedback tap() => HapticFeedback.selectionClick();
}
