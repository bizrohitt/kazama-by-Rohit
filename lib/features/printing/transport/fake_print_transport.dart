/// In-memory printer used by every test and by the app until a real driver lands
/// (P4). Records what it was asked to print so the queue's behaviour — retry,
/// receipt row, error message — is assertable without hardware.
library;

import 'print_transport.dart';

class FakePrintTransport implements PrintTransport {
  FakePrintTransport({this.failuresBeforeSuccess = 0, this.alwaysFail = false, this.reachable = true});

  /// Everything sent, oldest first. Tests assert on this.
  final List<List<int>> sent = <List<int>>[];
  final List<PrinterDevice> devicesUsed = <PrinterDevice>[];

  /// Number of calls that throw before the first success — models "the printer
  /// was asleep, the queue retried, the customer got their bill on attempt 2".
  int failuresBeforeSuccess;
  bool alwaysFail;
  bool reachable;

  int get sendCount => sent.length;

  /// The last receipt as text, which is far more readable in a failing test than
  /// a byte list. ESC/POS control bytes are stripped; the receipt's own
  /// `*`/`=` decoration survives.
  String get lastText {
    if (sent.isEmpty) return '';
    return String.fromCharCodes(
      sent.last.where((b) => b == 0x0a || (b >= 0x20 && b < 0x7f)),
    );
  }

  @override
  Future<bool> isReachable(PrinterDevice device) async => reachable;

  @override
  Future<void> send({required PrinterDevice device, required List<int> bytes}) async {
    devicesUsed.add(device);
    if (alwaysFail) throw const PrintFailure('Fake printer: alwaysFail is on');
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess -= 1;
      throw const PrintFailure('Fake printer: transient failure (retryable)');
    }
    sent.add(List<int>.of(bytes));
  }
}
