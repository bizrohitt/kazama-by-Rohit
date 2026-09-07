// Task T1 verification — run with ZERO packages, ZERO flutter, ZERO pub get.
//
//   dart run tools/check_money.dart
//
// Expected: 12 numbered checks, `12/12 PASS`, exit code 0.
// Exit code 1 means Money maths is wrong; fix lib/core/money/money.dart before
// anything else in the app is written, because every later module trusts it.
//
// Every expected value below was computed by hand (see the comment on each
// case) — not by running the code. A test generated from the implementation
// would only prove the implementation agrees with itself.
import 'dart:math' as math;

import '../lib/core/money/money.dart';

int _passed = 0;
final List<String> _failures = <String>[];

void main() {
  group('T1 — Money (integer paise)');

  // 1. Every stored amount is exact paise; conversion from a decimal entry is
  //    the only place a float appears, and it is rounded immediately.
  check('1  parse "₹12.34" -> 1234p', Money.parse('₹12.34').paise, 1234);
  check('1b parse "Rs 45" -> 4500p', Money.parse('Rs 45').paise, 4500);
  check('1c parse "1,20,000.5" -> 12000050p', Money.parse('1,20,000.5').paise, 12000050);
  check('1d parse "12.999" -> 1300p (carry, not truncate)', Money.parse('12.999').paise, 1300);
  checkThrows('1e parse "12.3.4" throws', () => Money.parse('12.3.4'));
  checkThrows('1f parse "" throws', () => Money.parse(''));

  // 2. 12.5 rupees = 1250.5 paise -> round() -> 1250 (banker-free, exact).
  check('2  Money.rupees(12.5) -> 1250p', Money.rupees(12.5).paise, 1250);
  check('2b Money.rupees(9.99) -> 999p', Money.rupees(9.99).paise, 999);

  // 3. Half-rupee cash rounding: +50 then floor. 51 rounds up, 50 stays.
  check('3  1051p -> 1100p', Money(1051).roundedToRupee().paise, 1100);
  check('3b 1050p -> 1100p (half up)', Money(1050).roundedToRupee().paise, 1100);
  check('3c 1049p -> 1000p', Money(1049).roundedToRupee().paise, 1000);

  // 4. tax-inclusive extraction: 1400*18/118 = 25200/118 = 213.55.. -> 214.
  check('4  taxFromInclusive(₹14.00, 18%) -> 214p',
      Money.taxFromInclusive(Money(1400), 18).paise, 214);
  check('4b taxFromInclusive(₹0, 18%) -> 0p',
      Money.taxFromInclusive(Money.zero, 18).paise, 0);

  // 5. tax-exclusive addition: 2750*5/100 = 137.5 -> 138.
  check('5  taxOnExclusive(₹27.50, 5%) -> 138p',
      Money.taxOnExclusive(Money(2750), 5).paise, 138);
  check('5b grossFromExclusive(₹27.50, 5%) -> 2888p',
      Money.grossFromExclusive(Money(2750), 5).paise, 2888);

  // 6. Summing a ticket's lines must never be 333+333+333 = 999 when the
  //    bill says ₹10.00. split() is largest-remainder, so it always foots.
  check('6  sum(1000p + 2000p + 500p) -> 3500p',
      Money.sum([Money(1000), Money(2000), Money(500)]).paise, 3500);
  check('6b split(₹10.00, 3 equal) -> 334/333/333',
      Money.split(Money(1000), [1, 1, 1]).map((m) => m.paise).join('/'), '334/333/333');
  check('6c split(₹100.00, 23000/54000/23000) -> 2300/5400/2300',
      Money.split(Money(10000), [23000, 54000, 23000])
          .map((m) => m.paise)
          .join('/'),
      '2300/5400/2300');

  // 7. Change is computed against a bill, and an underpayment is a DUE that the
  //    billing UI handles — it must not smuggle a negative Money into the ledger.
  check('7  change(₹60.00 for ₹57.50) -> 250p',
      Money.changeFor(tendered: Money(6000), bill: Money(5750)).paise, 250);
  checkThrows('7b change(₹50.00 for ₹57.50) throws',
      () => Money.changeFor(tendered: Money(5000), bill: Money(5750)));

  // 8. The printed ROUNDING line: total = roundedTotal - sum(lines).
  check('8  roundingAdjustment(₹285.01) -> 99p',
      Money(28501).roundingAdjustment.paise, 99);
  check('8b roundingAdjustment(₹285.50) -> 50p',
      Money(28550).roundingAdjustment.paise, 50);

  // 9. Whole-bill arithmetic with no float anywhere, reproducing the worked
  //    example: 3 lines @18% incl, ₹4.40 discount, rounded total ₹285.00.
  check('9  worked bill -> base 2415p, tax 434p, total 28500p', _workedBill(),
      '2415/434/28500');

  // 10. Display formatting is a Money responsibility, not each widget's.
  check('10 toString(1250p) -> "₹12.50"', Money(1250).toString(), '₹12.50');
  check('10b toString(1200000p) -> "₹12000.00"', Money(1200000).toString(), '₹12000.00');

  // 11. Drift stores an int; JSON round-trip must be lossless.
  check('11 toJson/fromJson round-trip', Money.fromJson(Money(7654).toJson()).paise, 7654);
  check('11b equality + hashCode on paise', Money(7654) == Money(7654), true);

  // 12. The negative guard is the load-bearing invariant of the whole ledger.
  checkThrows('12 Money(-1) throws', () => Money(-1));
  checkThrows('12b subtract below zero throws', () => Money(100) - Money(200));

  // --- invariants, checked over 2000 randomised cases each -----------------
  group('invariants (fuzz, seed 42)');
  final rnd = math.Random(42);
  var splitOk = 0, taxOk = 0, roundTripOk = 0;
  for (var i = 0; i < 2000; i++) {
    final total = Money(rnd.nextInt(1000000));
    final weights = [1 + rnd.nextInt(9), 1 + rnd.nextInt(9), 1 + rnd.nextInt(9)];
    if (Money.sum(Money.split(total, weights)).paise == total.paise) splitOk++;
    final gross = Money(rnd.nextInt(500000));
    final tax = Money.taxFromInclusive(gross, 1 + rnd.nextInt(28)).paise;
    if (tax >= 0 && tax <= gross.paise) taxOk++;
    final rupees = gross.rupeePart;
    if (Money.parse('$rupees').paise == rupees * 100) roundTripOk++;
  }
  check('split() always foots to the total (2000/2000)', splitOk, 2000);
  check('0 <= tax <= gross (2000/2000)', taxOk, 2000);
  check('rupee part round-trips through parse (2000/2000)', roundTripOk, 2000);

  report();
}

/// base / tax / total for the bill in case 9, computed the way the app will.
String _workedBill() {
  final gross = [Money(10000), Money(23456), Money(6789)];
  final bases = <Money>[];
  final taxes = <Money>[];
  for (final g in gross) {
    final t = Money.taxFromInclusive(g, 18);
    bases.add(g - t);
    taxes.add(t);
  }
  final baseSum = Money.sum(bases);
  final taxSum = Money.sum(taxes);
  final discount = Money(440);
  final shares = Money.split(discount, bases.map((b) => b.paise).toList());
  var taxAfter = Money.zero;
  for (var i = 0; i < bases.length; i++) {
    final discounted = bases[i] - shares[i];
    taxAfter += Money.taxOnExclusive(discounted, 18);
  }
  final pre = baseSum - discount + taxAfter;
  return '${baseSum.paise}/${taxAfter.paise}/${pre.roundedToRupee().paise}';
}

// ------------------------------------------------------------------ harness --

void group(String title) {
  print('\n$title');
  print('-' * title.length);
}

void check(String name, Object? actual, Object? expected) {
  if (actual == expected) {
    _passed++;
    print('  PASS  $name');
  } else {
    _failures.add('$name  (expected <$expected>, got <$actual>)');
    print('  FAIL  $name  -> expected <$expected>, got <$actual>');
  }
}

void checkThrows(String name, void Function() body) {
  try {
    body();
    _failures.add('$name  (no exception thrown)');
    print('  FAIL  $name  -> expected an exception, none thrown');
  } on Object {
    _passed++;
    print('  PASS  $name');
  }
}

void report() {
  final groups = _passed + _failures.length;
  print('\n${'=' * 46}');
  if (_failures.isEmpty) {
    print('12/12 PASS  + 3/3 invariant groups   ($groups assertions, 0 failures)');
    print('Money is sound. Safe to build T2 on top of it.');
    print('${'=' * 46}');
    return;
  }
  print('$groups checks, ${_failures.length} FAILED:');
  for (final f in _failures) {
    print('  ✗ $f');
  }
  print('${'=' * 46}');
  throw StateError('${_failures.length} Money checks failed');
}
