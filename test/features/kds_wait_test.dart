// Task K1/K3 — the wait-time rule, which is the only thing on the KDS that can
// be wrong without anyone seeing it (a ticket that reads "4 min" when it is 19
// minutes old is how a kitchen stops being trusted by its own cook).
// Run: flutter test test/features/kds_wait_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:kazama_pos/data/models/enums.dart';
import 'package:kazama_pos/data/models/order.dart';
import 'package:kazama_pos/features/kitchen_display/ui/kds_screen.dart';

final base = DateTime.utc(2026, 9, 5, 19, 0);

OrderTicket t({DateTime? opened, DateTime? fired}) => OrderTicket(
      id: 'o1',
      type: OrderType.dineIn,
      status: OrderStatus.inKitchen,
      openedBy: 'u1',
      openedAt: opened ?? base,
      firedAt: fired,
      updatedAt: base,
    );

void main() {
  test('unfired tickets are measured from open (a held bill is already late)', () {
    expect(waitedMinutes(t(), now: base.add(const Duration(minutes: 7))), 7);
  });

  test('fired tickets are measured from the fire, not from the open', () {
    // The point of using firedAt: a ticket opened at 19:00, parked, and fired at
    // 19:40 is NOT 40 minutes of kitchen work, and showing it as such is how the
    // board turns into noise the cook ignores.
    final ticket = t(opened: base, fired: base.add(const Duration(minutes: 40)));
    expect(waitedMinutes(ticket, now: base.add(const Duration(minutes: 43))), 3);
  });

  test('a fire before the open timestamp cannot produce a negative wait', () {
    // Not a real state, but a restore of an old snapshot can carry a bad pair of
    // columns, and `late` should then mean "just now", not "never".
    final ticket = t(opened: base, fired: base.subtract(const Duration(minutes: 5)));
    expect(waitedMinutes(ticket, now: base).sign, greaterThanOrEqualTo(0));
  });

  test('the late line is exactly the constant the UI reads', () {
    expect(kLateAfterMinutes, greaterThan(0));
    final late = kLateAfterMinutes + 1;
    expect(waitedMinutes(t(), now: base.add(Duration(minutes: late))), late);
  });

  test('roles: a cashier never ticks, kitchen and manager do', () {
    expect(UserRole.kitchen.canViewKds, isTrue);
    expect(UserRole.manager.canViewKds, isTrue);
    expect(UserRole.cashier.canViewKds, isFalse);
    // ...and the billing half of that rule: the kitchen may not take money.
    expect(UserRole.kitchen.canBill, isFalse);
    expect(UserRole.cashier.canBill, isTrue);
  });
}
