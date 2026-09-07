/// The printer seam (Task P4).
///
/// Everything above this file knows nothing about Bluetooth: the renderer turns a
/// ticket into bytes, the queue turns bytes into a `receipts` row, and this is the
/// one interface a real driver implements. Keeping it at the *byte* level (not
/// "print this text") is what lets a receipt be rendered, measured, asserted in a
/// test, and even written to a file for a support ticket while the printer is
/// turned off — which is most of the time in development.
library;

/// A transport failure the UI can show. Deliberately not an exception type per
/// device: the counter only needs "it did not print, and why, in one line".
class PrintFailure implements Exception {
  const PrintFailure(this.message, {this.retryable = true});

  final String message;

  /// `true` for "printer asleep / out of paper / link dropped"; `false` for a
  /// permanent problem (no such device, unsupported encoding) where retrying
  /// only wastes a customer's time.
  final bool retryable;

  @override
  String toString() => 'PrintFailure($message${retryable ? '' : ', permanent'})';
}

class PrinterDevice {
  const PrinterDevice({
    required this.id,
    required this.name,
    this.macAddress,
    this.paperWidthColumns = 32,
  });

  /// Stable identifier for the settings screen; for RFCOMM it is the MAC, for a
  /// file transport a path.
  final String id;
  final String name;
  final String? macAddress;

  /// 32 = 58 mm roll (the common Indian counter printer), 42/80 for wider rolls.
  /// Stored per device because a shop may own two widths.
  final int paperWidthColumns;

  @override
  String toString() => '$name ($id, $paperWidthColumns col)';
}

/// Bytes out, one-way. Implementations must be safe to await from a background
/// queue and must throw `PrintFailure` rather than a platform exception, so the
/// queue can distinguish "retry later" from "tell the cashier".
abstract interface class PrintTransport {
  Future<void> send({required PrinterDevice device, required List<int> bytes});

  /// Cheap probe used by the settings screen's "Test print" button (P4). Not
  /// used by the queue: the queue just tries and records the error.
  Future<bool> isReachable(PrinterDevice device);
}
