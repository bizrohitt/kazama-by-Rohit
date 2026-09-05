/// Staff, PIN and shift repository (Task S1-S4).
///
/// Deliberately the only place `PinHasher` is called from the data layer: the
/// hash of a PIN is a *policy* (which KDF, what salt, when to lock) and a policy
/// that lives in the DB layer cannot be swapped without a migration. So this
/// class receives a hasher and never constructs one.
library;

import '../../../core/db/app_database.dart';
import '../../../core/money/money.dart';
import '../../../core/utils/id.dart';
import '../../../features/staff_auth/domain/pin_hasher.dart';
import '../../models/enums.dart';
import '../../models/staff.dart';
import '../contract/staff_repository.dart';

class StaffRepositoryImpl implements StaffRepository {
  StaffRepositoryImpl(
    this.db, {
    this.hasher = const PinHasher(),
    IdFactory? idFactory,
  }) : ids = idFactory ?? IdFactory();

  final AppDatabase db;
  final PinHasher hasher;
  final IdFactory ids;

  @override
  Future<List<StaffUser>> users() => db.allUsers();

  @override
  Stream<List<StaffUser>> watchUsers() => db.watchUsers();

  @override
  Future<bool> hasAnyUser() async => (await db.userCount()) > 0;

  @override
  Future<StaffUser> createManager({required String name, required String pin}) async {
    if (name.trim().isEmpty) throw ArgumentError('a manager needs a name');
    final problem = PinHasher.validatePin(pin);
    if (problem != null) throw ArgumentError(problem);
    if (await hasAnyUser()) {
      // Only one bootstrap: a second "create the manager" would be how a
      // cashier gains manager rights through the first-run screen (S1).
      throw StateError('a manager already exists; add staff from the users screen');
    }
    final user = _newUser(name: name.trim(), pin: pin, role: UserRole.manager);
    await db.upsertUser(user, at: DateTime.now());
    return user;
  }

  @override
  Future<StaffUser?> authenticate({required String userId, required String pin}) async {
    final user = await db.userById(userId);
    if (user == null || !user.active) return null;
    if (PinHasher.isLocked(failedAttempts: user.failedAttempts, lockedUntil: user.lockedUntil)) {
      return null;
    }
    if (!hasher.verify(pin: pin, salt: user.pinSalt, expectedHash: user.pinHash)) {
      await registerFailedAttempt(userId);
      return null;
    }
    if (user.failedAttempts != 0) await clearFailedAttempts(userId);
    return user;
  }

  @override
  Future<void> registerFailedAttempt(String userId) async {
    final user = await db.userById(userId);
    if (user == null) return;
    final tries = user.failedAttempts + 1;
    await db.upsertUser(
      user.copyWith(
        failedAttempts: tries,
        lockedUntil: PinHasher.shouldLock(tries) ? PinHasher.lockUntil() : user.lockedUntil,
      ),
      at: DateTime.now(),
    );
  }

  @override
  Future<PinLockInfo> lockInfo(String userId) async {
    final user = await db.userById(userId);
    if (user == null) return PinLockInfo.clear;
    final locked = PinHasher.isLocked(failedAttempts: user.failedAttempts, lockedUntil: user.lockedUntil);
    return PinLockInfo(
      locked: locked,
      remaining: locked && user.lockedUntil != null
          ? user.lockedUntil!.difference(DateTime.now())
          : Duration.zero,
      failedAttempts: user.failedAttempts,
    );
  }

  @override
  Future<void> clearFailedAttempts(String userId) async {
    final user = await db.userById(userId);
    if (user == null) return;
    await db.upsertUser(user.copyWith(failedAttempts: 0, clearLock: true), at: DateTime.now());
  }

  @override
  Future<StaffUser> addUser({
    required String name,
    required String pin,
    required UserRole role,
  }) async {
    final problem = PinHasher.validatePin(pin);
    if (problem != null) throw ArgumentError(problem);
    final user = _newUser(name: name.trim(), pin: pin, role: role);
    await db.upsertUser(user, at: DateTime.now());
    return user;
  }

  @override
  Future<void> setUserActive({required String userId, required bool active}) async {
    final user = await db.userById(userId);
    if (user == null) throw StateError('unknown user $userId');
    if (!active && user.role == UserRole.manager && await _managerCount() <= 1) {
      // Disabling the last manager locks the shop out of its own settings, voids
      // and reports (S2). Loud refusal beats a recovery-from-backup afternoon.
      throw StateError('cannot disable the last manager');
    }
    await db.upsertUser(user.copyWith(active: active), at: DateTime.now());
  }

  Future<int> _managerCount() async =>
      (await users()).where((u) => u.active && u.role == UserRole.manager).length;

  // ------------------------------------------------------------------ shift --

  @override
  Future<Shift> openShift(String userId, {Money openingFloat = Money.zero}) async {
    final now = DateTime.now();
    final shift = Shift(id: ids.newId(), userId: userId, openingFloat: openingFloat, openedAt: now);
    await db.transaction(() async {
      final dangling = await db.openShiftFor(userId);
      if (dangling != null) {
        // Closing a dangling shift with an uncounted drawer is recorded AS
        // uncounted (counted = expected) rather than refused: the app was
        // killed or the cashier walked out, and the next person must still be
        // able to start. The zero-variance row is the audit trail of that.
        final expected = dangling.openingFloat + await db.drawerFromCash(from: dangling.openedAt, to: now);
        await db.closeShift(shiftId: dangling.id, countedCash: expected, note: 'auto-closed (uncounted)', at: now);
      }
      await db.insertShift(shift);
    });
    return shift;
  }

  @override
  Future<Shift?> currentShift(String userId) => db.openShiftFor(userId);

  @override
  Future<void> closeShift({
    required String shiftId,
    required Money countedCash,
    String? note,
  }) async {
    final shift = await db.shiftById(shiftId);
    if (shift == null) throw StateError('unknown shift $shiftId');
    if (!shift.isOpen) throw StateError('shift $shiftId is already closed');
    await db.closeShift(shiftId: shiftId, countedCash: countedCash, note: note, at: DateTime.now());
  }

  /// Cash the drawer gained. Delegates to the DAO so the rule ("tendered minus
  /// change", not "amount") has exactly one implementation shared with the
  /// cash-up report (R2) — two rules is how a close and a report disagree.
  @override
  Future<Money> cashCollectedDuring(Shift shift) =>
      db.drawerFromCash(from: shift.openedAt, to: shift.closedAt);

  @override
  Future<Money> expectedCashFor(Shift shift) async => shift.openingFloat + await cashCollectedDuring(shift);

  @override
  Future<List<ShiftSummary>> shiftSummaries({DateTime? from, DateTime? to}) async {
    final shifts = await db.shiftsInRange(from: from, to: to);
    final names = {for (final u in await db.allUsers(includeInactive: true)) u.id: u.name};
    final rangeTo = to ?? DateTime.now();
    final out = <ShiftSummary>[];
    for (final s in shifts) {
      final to = s.closedAt ?? rangeTo;
      final cash = await db.drawerFromCash(from: s.openedAt, to: to);
      final bills = await db.ticketsBetween(s.openedAt, to);
      // `expected` is float + cash gained; `cashCollected` is the float back out
      // plus what the shift took, so an OPEN shift reads `expected` as its live
      // target and a closed one compares `countedCash` against it (S4).
      final expected = s.openingFloat + cash;
      out.add(
        ShiftSummary(
          shift: s,
          userName: names[s.userId] ?? s.userId,
          cashCollected: cash,
          billsClosed: bills.where((t) => t.status == OrderStatus.paid).length,
          expectedCash: expected,
          countedCash: s.countedCash,
        ),
      );
    }
    return out;
  }

  StaffUser _newUser({required String name, required String pin, required UserRole role}) {
    final salt = newSalt();
    return StaffUser(
      id: ids.newId(),
      name: name,
      role: role,
      pinHash: hasher.hash(pin: pin, salt: salt),
      pinSalt: salt,
      createdAt: DateTime.now(),
    );
  }
}
