// Task Y1/Y2 — the round-up key. Asserted directly because the number it prints
// is the number a customer is handed change against: an off-by-one here is a
// real rupee lost at a real counter, and no widget test will notice.
// Run: flutter test test/features/billing_rounding_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:kazama_pos/core/money/money.dart';
import 'package:kazama_pos/features/billing/ui/billing_screen.dart';

int up(String rupees) => roundUpTo(Money.parse(rupees));

void main() {
  test('exact amounts are left alone', () {
    for (final n in [10, 20, 50, 100, 200, 500, 1000, 2000]) {
      expect(up('$n.00'), n, reason: '$n is already a note');
    }
  });

  test('anything over a note goes to the next note', () {
    expect(up('15'), 20);
    expect(up('51'), 100);
    expect(up('250'), 500);
    expect(up('1234'), 2000);
    expect(up('2000.01'), 2500, reason: 'past the note list, steps of 500');
  });

  test('a sub-rupee due never invents a ₹1 note', () {
    // `up('5') == 10`: the smallest tender an Indian counter has is a ₹10 coin,
    // and a "round up to ₹5" key would be a promise the drawer cannot keep.
    expect(up('5'), 10);
    expect(up('0.50'), 10);
    expect(up('0'), 10);
  });

  test('paise are rounded UP before the note search (a bill is never short)', () {
    expect(up('99.99'), 100);
    expect(up('499.01'), 500);
  });

  test('the result is always >= the due, in paise', () {
    for (final rupees in [1, 3, 7, 13, 19, 33, 66, 99, 101, 249, 501, 999, 2001, 3333]) {
      final due = Money(rupees * 100 + 55); // +55 paise: forces the ceil
      expect(Money(up('$rupees') * 100) >= due, isTrue, reason: '₹$rupees.55 -> ${up('$rupees')}');
    }
  });
}
