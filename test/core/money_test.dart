// Task T1 — flutter_test mirror of tools/check_money.dart.
// Run after the scaffold exists:  flutter test test/core/money_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:kazama_pos/core/money/money.dart';

void main() {
  group('Money — construction & parsing', () {
    test('stores exact paise', () {
      expect(Money(1250).paise, 1250);
      expect(Money.rupees(12.5).paise, 1250);
      expect(Money.rupees(9.99).paise, 999);
      expect(Money.zero.paise, 0);
    });

    test('parses counter input', () {
      expect(Money.parse('₹12.34').paise, 1234);
      expect(Money.parse('Rs 45').paise, 4500);
      expect(Money.parse('45.').paise, 4500);
      expect(Money.parse('1,20,000.5').paise, 12000050);
    });

    test('rounds sub-paise input instead of truncating', () {
      expect(Money.parse('12.999').paise, 1300);
      expect(Money.parse('12.994').paise, 1299);
      expect(Money.parse('0.999').paise, 100);
    });

    test('rejects garbage rather than becoming zero', () {
      expect(() => Money.parse(''), throwsFormatException);
      expect(() => Money.parse('   '), throwsFormatException);
      expect(() => Money.parse('abc'), throwsFormatException);
      expect(() => Money.parse('12.3.4'), throwsFormatException);
      expect(() => Money.parse('-5'), throwsFormatException);
    });

    test('negative money is impossible', () {
      expect(() => Money(-1), throwsArgumentError);
      expect(() => Money(100) - Money(200), throwsArgumentError);
    });
  });

  group('Money — arithmetic', () {
    test('adds and scales', () {
      expect(Money(1000) + Money(2000) + Money(500), Money(3500));
      expect(Money(150).scale(3), Money(450));
      expect(Money.sum([Money(10), Money(20)]), Money(30));
      expect(Money.sum(const []), Money.zero);
      // percentOf takes basis-points-of-rupee: 12.50% of ₹10.00 = ₹1.25.
      expect(Money(1000).percentOf(1250), Money(125));
      expect(Money(1000).percentOf(333), Money(33));
    });

    test('comparisons and value equality', () {
      expect(Money(100) < Money(200), isTrue);
      expect(Money(200) <= Money(200), isTrue);
      expect(Money(201) > Money(200), isTrue);
      expect(Money(500) >= Money(501), isFalse);
      expect(Money(500) == Money(500), isTrue);
      expect({Money(500), Money(500)}.length, 1);
      expect([Money(200), Money(100)]..sort(), [Money(100), Money(200)]);
    });
  });

  group('Money — tax', () {
    test('tax-inclusive extraction is float-free and bounded', () {
      expect(Money.taxFromInclusive(Money(1400), 18), Money(214));
      expect(Money.taxFromInclusive(Money(1375), 5), Money(69));
      expect(Money.taxFromInclusive(Money(2750), 12), Money(295));
      expect(Money.taxFromInclusive(Money.zero, 18), Money.zero);
      expect(Money.taxFromInclusive(Money(1400), 0), Money.zero);
      // An absurd percent must not produce tax larger than the amount itself.
      expect(Money.taxFromInclusive(Money(1000), 150).paise <= 1000, isTrue);
    });

    test('tax-exclusive addition and gross', () {
      expect(Money.taxOnExclusive(Money(2750), 5), Money(138));
      expect(Money.grossFromExclusive(Money(2750), 5), Money(2888));
    });
  });

  group('Money — cash-drawer rules', () {
    test('rounds to the nearest rupee, half up', () {
      expect(Money(1049).roundedToRupee(), Money(1000));
      expect(Money(1050).roundedToRupee(), Money(1100));
      expect(Money(1051).roundedToRupee(), Money(1100));
    });

    test('exposes the ROUNDING line for the receipt', () {
      expect(Money(28501).roundingAdjustment, Money(99));
      expect(Money(28550).roundingAdjustment, Money(50));
      expect(Money(28500).roundingAdjustment, Money.zero);
    });

    test('change is never negative', () {
      expect(Money.changeFor(tendered: Money(6000), bill: Money(5750)), Money(250));
      expect(
        () => Money.changeFor(tendered: Money(5000), bill: Money(5750)),
        throwsArgumentError,
      );
    });
  });

  group('Money — allocation', () {
    test('split loses no paise (largest remainder)', () {
      expect(
        Money.split(Money(1000), [1, 1, 1]).map((m) => m.paise).toList(),
        [334, 333, 333],
      );
      expect(
        Money.split(Money(10000), [23000, 54000, 23000])
            .map((m) => m.paise)
            .toList(),
        [2300, 5400, 2300],
      );
      expect(Money.sum(Money.split(Money(999), [7, 11, 3])), Money(999));
      expect(Money.split(Money.zero, [1, 2, 3]).every((m) => m.isZero), isTrue);
    });

    test('split with all-zero weights still foots', () {
      final parts = Money.split(Money(10), [0, 0, 0]);
      expect(Money.sum(parts), Money(10));
      expect(parts.length, 3);
    });

    test('negative weight is a programming error', () {
      expect(() => Money.split(Money(10), [5, -1]), throwsArgumentError);
    });
  });

  group('Money — serialisation & display', () {
    test('drift column is an int, round-trip is lossless', () {
      expect(Money(7654).toJson(), 7654);
      expect(Money.fromJson(7654), Money(7654));
      expect(Money.fromJson('76.54'), Money(7654));
      expect(() => Money.fromJson(null), throwsFormatException);
    });

    test('display string is rupees with 2 decimals', () {
      expect(Money(1250).toString(), '₹12.50');
      expect(Money(1200000).toString(), '₹12000.00');
      expect(Money(105).toString(), '₹1.05');
      expect(Money(1250).toCompactString(), '12.50');
    });
  });
}
