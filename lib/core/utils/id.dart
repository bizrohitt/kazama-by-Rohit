/// Offline-safe id generation (Task U1).
///
/// No `package:uuid`: these ids only have to be unique within one device and
/// stable across a sync, and a monotonic `<time36>-<counter>` string gives that in
/// ~12 chars while ALSO sorting chronologically — which makes "give me the last
/// 50 rows" a plain `ORDER BY id` on an unindexed column. The uuid package stays
/// out of the dependency list rather than being replaced by something weaker: the
/// collision domain here is a single till, not a distributed system.
library;

class IdFactory {
  IdFactory({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  int _counter = 0;

  String newId() {
    _counter = (_counter + 1) & 0xffffff; // wraps at 16M ids/day, plenty
    return '${_clock().millisecondsSinceEpoch.toRadixString(36)}-${_counter.toRadixString(36)}';
  }

  /// Deterministic ids for tests, so a snapshot comparison doesn't need to strip
  /// random fields (the backup test's row-for-row assertion depends on this).
  static IdFactory fixed(String prefix, {int start = 0}) => _FixedIdFactory(prefix, start);
}

class _FixedIdFactory extends IdFactory {
  _FixedIdFactory(this.prefix, this.start) : super(clock: () => DateTime.utc(2026, 1, 1));

  final String prefix;
  final int start;
  int _n = -1;

  @override
  String newId() {
    _n = _n < 0 ? start : _n + 1;
    return '$prefix$_n';
  }
}

/// Salt for a staff PIN. 8 hex chars from the same monotonic source is fine here:
/// the salt only has to differ per user, and a 4-6 digit PIN has no real
/// secrecy to protect (see the note on `users.pin_hash`).
String newSalt([int seed = 0]) =>
    DateTime.now().microsecondsSinceEpoch.add(seed).toRadixString(16).padLeft(8, '0').substring(0, 8);
