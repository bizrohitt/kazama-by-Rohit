/// Staff / session / shift contract (Task S1-S4).
library;

import '../../../core/money/money.dart';
import '../../../core/money/money_delta.dart';
import '../../models/enums.dart';
import '../../models/payment.dart';
import '../../models/staff.dart';

abstract interface class StaffRepository {
  Future<List<StaffUser>> users();

  Stream<List<StaffUser>> watchUsers();

  /// First-run bootstrap: creates the manager, whose PIN then gates everything.
  /// Awaits the row count on purpose — a synchronous `hasAnyUser` getter would
  /// tempt a UI into deciding before the DB has answered.
  Future<bool> hasAnyUser();

  Future<StaffUser> createManager({required String name, required String pin});

  Future<StaffUser?> authenticate({required String userId, required String pin});

  Future<void> registerFailedAttempt(String userId);

  Future<void> clearFailedAttempts(String userId);

  /// Why a PIN was refused, for the sign-in message. A screen must not compute
  /// "how long left" itself: that number comes from the same clock rule as the
  /// lockout itself, or a cashier is told to wait 60s while the row says 12s.
  Future<PinLockInfo> lockInfo(String userId);

  Future<StaffUser> addUser({
    required String name,
    required String pin,
    required UserRole role,
  });

  Future<void> setUserActive({required String userId, required bool active});

  /// Closes any still-open shift for that user first (counting whatever is
  /// uncounted as a zero variance) so two open shifts can never coexist.
  Future<Shift> openShift(String userId, {Money openingFloat = Money.zero});

  Future<Shift?> currentShift(String userId);

  Future<void> closeShift({
    required String shiftId,
    required Money countedCash,
    String? note,
  });

  /// Cash actually in the drawer for a shift: cash-tendered rows minus change given.
  Future<Money> cashCollectedDuring(Shift shift);

  /// For the reports screen: every shift with its variance already computed.
  Future<List<ShiftSummary>> shiftSummaries({DateTime? from, DateTime? to});
}

/// Lockout state for one user (S1).
final class PinLockInfo {
  const PinLockInfo({required this.locked, this.remaining = Duration.zero, this.failedAttempts = 0});

  final bool locked;
  final Duration remaining;
  final int failedAttempts;

  /// Never "0 seconds" or "1 tries": the string is what the sign-in screen shows.
  String get message {
    if (locked) {
      final secs = remaining.inSeconds + (remaining.inMilliseconds % 1000 == 0 ? 0 : 1);
      return 'Wrong PIN too many times - try again in $secs s';
    }
    if (failedAttempts == 0) return '';
    final left = 5 - failedAttempts;
    return left <= 1 ? 'One try left before a 60 s lock' : '$left tries left before a 60 s lock';
  }

  static const PinLockInfo clear = PinLockInfo(locked: false);
}

/// A shift plus the numbers an owner needs at close (S4).
class ShiftSummary {
  const ShiftSummary({
    required this.shift,
    required this.userName,
    required this.cashCollected,
    required this.billsClosed,
    required this.expectedCash,
    this.countedCash,
  });

  final Shift shift;
  final String userName;
  final Money cashCollected;
  final int billsClosed;
  final Money expectedCash;
  final Money? countedCash;

  bool get isClosed => countedCash != null;

  /// Signed, short counts negative (SKILLS.md §B5). `MoneyDelta` rather than an
  /// `int?` paise field so a UI cannot accidentally format a raw paise count as
  /// rupees — the type carries the sign rule and the formatter together.
  MoneyDelta? get variance => countedCash == null ? null : MoneyDelta(countedCash!.paise - expectedCash.paise);

  /// True when the drawer is off by more than [tolerance] (₹1 default: paise are
  /// not physically issuable in most Indian counters, so a 1-rupee band absorbs
  /// the rounding line without hiding a real shortfall).
  /// The default tolerance is ZERO here and the UI passes ₹1 (100 paise): a
  /// default hidden in a contract is a rule nobody can find, while the screen
  /// that shows the warning knows exactly what band it is tolerating.
  bool needsExplanation({Money tolerance = Money.zero}) =>
      variance != null && variance!.paise.abs() > tolerance.paise;
}
