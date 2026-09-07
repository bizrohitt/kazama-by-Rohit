/// Staff PIN hashing + lockout rules (Task S1). Pure Dart, no Flutter import.
///
/// Read the limitation honestly: SHA-256 over a 4-digit PIN is **not** a security
/// boundary. There are 10,000 candidates; anyone holding the DB file can try them
/// all in milliseconds. What this does provide is (a) the PIN is not sitting in
/// plaintext where a colleague or a shared-backup viewer can read it, and
/// (b) a lockout that stops shoulder-surfing-and-try from being casual. If this
/// app ever leaves the counter, swap to a real KDF or server auth — do not
/// "improve" the hash and assume the threat is gone.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

final class PinHasher {
  const PinHasher();

  static const int pinLengthMin = 4;
  static const int pinLengthMax = 6;
  static const int maxFailedAttempts = 5;
  static const Duration lockout = Duration(seconds: 60);

  /// Rejects anything that isn't 4-6 digits, before hashing, so a whitespace or a
  /// stray paste can't silently become "a valid PIN nobody can type again".
  static String? validatePin(String pin) {
    final t = pin.trim();
    if (t.length < pinLengthMin || t.length > pinLengthMax) {
      return 'PIN must be $pinLengthMin-$pinLengthMax digits';
    }
    if (!RegExp(r'^\d+$').hasMatch(t)) return 'PIN must be digits only';
    if (_isCommon(t)) return 'Too obvious (try something like 7-3-9-1)';
    return null;
  }

  static bool _isCommon(String pin) => const {
    '1234',
    '0000',
    '1111',
    '1212',
    '2580',
    '12345',
    '123456',
    '9999',
  }.contains(pin);

  String hash({required String pin, required String salt}) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  bool verify({
    required String pin,
    required String salt,
    required String expectedHash,
  }) => hash(pin: pin, salt: salt) == expectedHash;

  /// Lockout arithmetic lives here, not in a widget, so "5 wrong tries -> 60s"
  /// is one testable rule that the login screen and any future API share.
  static bool isLocked({required int failedAttempts, DateTime? lockedUntil, DateTime? now}) {
    if (lockedUntil == null) return false;
    return (now ?? DateTime.now()).isBefore(lockedUntil);
  }

  static bool shouldLock(int failedAttemptsAfterThisTry) =>
      failedAttemptsAfterThisTry >= maxFailedAttempts;

  static DateTime lockUntil({DateTime? now}) => (now ?? DateTime.now()).add(lockout);
}

/// Current auth state, exposed to the whole app (S2/S3).
final class PosSession {
  const PosSession({this.userId, this.name, this.roleName, this.since});

  final String? userId;
  final String? name;
  final String? roleName;
  final DateTime? since;

  bool get isSignedIn => userId != null;

  static const PosSession anonymous = PosSession();
}
