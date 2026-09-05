/// Staff / shift models (Task T2). Pure Dart.
///
/// `users` is deliberately tiny: v1 needs "who opened this ticket" and "who may
/// bill", nothing more (Phase S). The PIN is a 4-6 digit counter convenience,
/// not a security boundary — see `pinHashNote` for what it does and doesn't buy.
library;

import '../../core/money/money.dart';
import 'payment.dart';
import '../../core/money/money_delta.dart';
import 'enums.dart';

final class StaffUser {
  const StaffUser({
    required this.id,
    required this.name,
    required this.role,
    required this.pinHash,
    /// Paired with `pinHash`; the DB column is NOT NULL so the model defaults to
    /// an empty salt rather than an optional field — a user with no salt is a
    /// real state (legacy/imported row), and `''` makes it visible instead of
    /// hiding it behind `String?`.
    this.pinSalt = '',
    this.active = true,
    this.failedAttempts = 0,
    this.lockedUntil,
    required this.createdAt,
  });

  final String id;
  final String name;
  final UserRole role;

  /// SHA-256 of the PIN **plus** the per-user salt held in the row. Computed in
  /// `features/staff_auth/domain/pin_hasher.dart` (S1), never here — a model
  /// that hashes is a model that can't be tested without crypto wiring.
  final String pinHash;

  /// Per-user random salt (generated in `core/utils/id.dart`). Stored so a
  /// restore can rebuild the same hash; without it every user would share one
  /// rainbow table.
  final String pinSalt;
  final bool active;

  /// Lockout counter lives on the row so a re-login after a crash still sees it.
  final int failedAttempts;
  final DateTime? lockedUntil;
  final DateTime createdAt;

  bool get canBill => role.canBill;
  bool get canEditMenu => role.canEditMenu;
  bool get canSeeReports => role.canSeeReports;
  bool get canVoid => role.canVoid;
  bool get canViewKds => role.canViewKds;
  bool get isLocked =>
      lockedUntil != null && DateTime.now().isBefore(lockedUntil!);

  StaffUser copyWith({
    String? name,
    UserRole? role,
    String? pinHash,
    String? pinSalt,
    bool? active,
    int? failedAttempts,
    DateTime? lockedUntil,
    bool? clearLock,
  }) => StaffUser(
    id: id,
    name: name ?? this.name,
    role: role ?? this.role,
    pinHash: pinHash ?? this.pinHash,
    pinSalt: pinSalt ?? this.pinSalt,
    active: active ?? this.active,
    failedAttempts: failedAttempts ?? this.failedAttempts,
    lockedUntil: clearLock == true ? null : (lockedUntil ?? this.lockedUntil),
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'role': role.name,
    'pinHash': pinHash,
    'pinSalt': pinSalt,
    'active': active,
    'failedAttempts': failedAttempts,
    'lockedUntil': lockedUntil?.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
  };

  factory StaffUser.fromJson(Map<String, Object?> j) => StaffUser(
    id: j['id']! as String,
    name: j['name']! as String,
    role: UserRole.fromName(j['role'] as String?),
    pinHash: j['pinHash']! as String,
    pinSalt: (j['pinSalt'] as String?) ?? '',
    active: (j['active'] as bool?) ?? true,
    failedAttempts: (j['failedAttempts'] as int?) ?? 0,
    lockedUntil: _date(j['lockedUntil']),
    createdAt: DateTime.parse(j['createdAt']! as String),
  );

  static DateTime? _date(Object? raw) => raw == null ? null : DateTime.parse(raw! as String);

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is StaffUser &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.name == name &&
      other.role == role &&
      other.pinHash == pinHash &&
      other.pinSalt == pinSalt &&
      other.active == active &&
      other.failedAttempts == failedAttempts &&
      other.lockedUntil == lockedUntil &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hashAll([
      id.hashCode,
      name.hashCode,
      role.hashCode,
      pinHash.hashCode,
      pinSalt.hashCode,
      active.hashCode,
      failedAttempts.hashCode,
      lockedUntil.hashCode,
      createdAt.hashCode,
    ]);
}

/// A cashier's open session. Needed because a shared tablet with no shift
/// record makes "who shorted the drawer ₹200" unanswerable (S4).
final class Shift {
  const Shift({
    required this.id,
    required this.userId,
    required this.openingFloat,
    required this.openedAt,
    this.closedAt,
    this.countedCash,
    this.note,
  });

  final String id;
  final String userId;
  final Money openingFloat;
  final DateTime openedAt;
  final DateTime? closedAt;
  final Money? countedCash;
  final String? note;

  bool get isOpen => closedAt == null;

  /// Expected drawer = float + cash taken + cash change already given back.
  /// [cashPayments] must contain only `mode == cash` rows (PaymentMode does the
  /// filtering; passing the full ledger is a silent rupee-short bug waiting to happen).
  Money expectedCash(List<Payment> cashPayments) =>
      openingFloat + Money.sum(cashPayments.map((p) => p.amount));

  /// Variance is signed on purpose: over-count and short-count are different
  /// conversations, and a `Money` cannot hold the difference (SKILLS.md §B5).
  MoneyDelta variance(List<Payment> cashPayments, Money counted) =>
      MoneyDelta(counted.paise - expectedCash(cashPayments).paise);

  Map<String, Object?> toJson() => {
    'id': id,
    'userId': userId,
    'openingFloatPaise': openingFloat.toJson(),
    'openedAt': openedAt.toIso8601String(),
    'closedAt': closedAt?.toIso8601String(),
    'countedCashPaise': countedCash?.toJson(),
    'note': note,
  };

  factory Shift.fromJson(Map<String, Object?> j) => Shift(
    id: j['id']! as String,
    userId: j['userId']! as String,
    openingFloat: Money.fromJson(j['openingFloatPaise'] ?? 0),
    openedAt: DateTime.parse(j['openedAt']! as String),
    closedAt: j['closedAt'] == null ? null : DateTime.parse(j['closedAt']! as String),
    countedCash: j['countedCashPaise'] == null
        ? null
        : Money.fromJson(j['countedCashPaise']),
    note: j['note'] as String?,
  );

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is Shift &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.userId == userId &&
      other.openingFloat == openingFloat &&
      other.openedAt == openedAt &&
      other.closedAt == closedAt &&
      other.countedCash == countedCash &&
      other.note == note;

  @override
  int get hashCode => Object.hashAll([
      id.hashCode,
      userId.hashCode,
      openingFloat.hashCode,
      openedAt.hashCode,
      closedAt.hashCode,
      countedCash.hashCode,
      note.hashCode,
    ]);
}

/// Printed-slip bookkeeping (P2/P4): did it actually reach a printer, and was
/// it a reprint? An owner audit asks "was this bill ever printed twice".
final class ReceiptRecord {
  const ReceiptRecord({
    required this.id,
    required this.orderId,
    required this.kind,
    required this.transport,
    required this.delivered,
    required this.at,
    this.printerName,
    this.paperWidthColumns = 32,
    this.bytesPath,
    this.error,
  });

  final String id;
  final String orderId;
  final ReceiptKind kind;

  /// `fake` | `bt:AA:BB:...` | `lan:192.168.1.50` — recorded so a debugging
  /// session can tell which transport produced a bad slip.
  final String transport;
  final bool delivered;
  final DateTime at;
  final String? printerName;

  /// 32 (58mm) or 48 (80mm). Stored per receipt because a template change must
  /// not silently reflow yesterday's reprint.
  final int paperWidthColumns;
  final String? bytesPath;
  final String? error;

  bool get isCopy => kind.mustBeMarkedCopy;

  Map<String, Object?> toJson() => {
    'id': id,
    'orderId': orderId,
    'kind': kind.name,
    'transport': transport,
    'delivered': delivered,
    'at': at.toIso8601String(),
    'printerName': printerName,
    'paperWidthColumns': paperWidthColumns,
    'bytesPath': bytesPath,
    'error': error,
  };

  factory ReceiptRecord.fromJson(Map<String, Object?> j) => ReceiptRecord(
    id: j['id']! as String,
    orderId: j['orderId']! as String,
    kind: ReceiptKind.fromName(j['kind'] as String?),
    transport: j['transport']! as String,
    delivered: (j['delivered'] as bool?) ?? false,
    at: DateTime.parse(j['at']! as String),
    printerName: j['printerName'] as String?,
    paperWidthColumns: (j['paperWidthColumns'] as int?) ?? 32,
    bytesPath: j['bytesPath'] as String?,
    error: j['error'] as String?,
  );

  /// Value equality exists for the T2 gate: `M.fromJson(m.toJson()) == m` catches a
  /// field dropped from either codec. Nested collections compare structurally via
  /// `deep_eq.dart` rather than a package dependency.
  @override
  bool operator ==(Object other) =>
      other is ReceiptRecord &&
      other.runtimeType == runtimeType &&
      other.id == id &&
      other.orderId == orderId &&
      other.kind == kind &&
      other.transport == transport &&
      other.delivered == delivered &&
      other.at == at &&
      other.printerName == printerName &&
      other.paperWidthColumns == paperWidthColumns &&
      other.bytesPath == bytesPath &&
      other.error == error;

  @override
  int get hashCode => Object.hashAll([
      id.hashCode,
      orderId.hashCode,
      kind.hashCode,
      transport.hashCode,
      delivered.hashCode,
      at.hashCode,
      printerName.hashCode,
      paperWidthColumns.hashCode,
      bytesPath.hashCode,
      error.hashCode,
    ]);
}
