/// Snapshot file layout shared by export and restore (Task T4).
///
/// Why a JSON snapshot at all when SQLite is already a file: the .sqlite file is
/// (a) not shareable from a phone in a way an owner will actually do, (b) opaque
/// when it breaks, and (c) the first thing lost to "clear app data", a failed
/// app update, or a replaced phone. A JSON snapshot survives all three, and a
/// repair can be done by hand in a text editor — which is worth more than any
/// checksum when you are a shop owner at 23:00 with a dead tablet.
///
/// `formatVersion` is the FILE format; `schemaVersion` is the DATABASE version
/// inside the envelope. They change independently and conflating them is how a
/// restore tool starts refusing backups it could read perfectly well.
library;

/// File-format version. Bump only when the envelope shape changes.
const int kSnapshotFormatVersion = 1;

const String kSnapshotFormatTag = 'kazama-pos-snapshot';
const String kSnapshotChecksumPrefix = 'sha256:';

/// Table keys in the envelope, in the order they were exported.
///
/// EXPORT order (parents before children). Restore uses the same order; the wipe
/// order is the exact reverse, which is why both live here rather than in the
/// services — one list to keep in sync with the schema, not two.
const List<String> kSnapshotTables = [
  'app_meta',
  'users',
  'shifts',
  'menu_categories',
  'modifier_groups',
  'modifier_options',
  'menu_items',
  'orders',
  'order_lines',
  'order_events',
  'payments',
  'credit_entries',
  'receipts',
];

/// The outbox is intentionally absent: it is transient queue state, and restoring
/// a snapshot into a device that has already synced must not resurrect ACKed
/// mutations. Losing it costs nothing; replaying it could double-post a sale.
const String kOutboxTable = 'sync_outbox';

/// Columns that must hold whole, non-negative paise. The validator enforces these
/// names across every table, so a hand-edited `10.5` or a float `1000.0` is
/// rejected instead of being silently truncated into the ledger.
const List<String> kMoneyColumnSuffix = ['paise'];

/// Suffixes that must be non-negative but are counts, not money.
const List<String> kCountColumns = [
  'sort_order',
  'tax_percent',
  'prep_seconds',
  'quantity',
  'cancelled_quantity',
  'attempts',
  'paper_width_columns',
  'bill_number',
  'discount_kind',
  'discount_value',
];

/// Filename for a snapshot. Timestamp is local (a human reads it) but the
/// contents are UTC, so two files named an hour apart are unambiguous.
String snapshotFileName(DateTime at, {String suffix = 'full'}) =>
    'kazama_backup_${at.year}${_two(at.month)}${_two(at.day)}'
    '_${_two(at.hour)}${_two(at.minute)}${_two(at.second)}_$suffix.json';

String _two(int v) => v.toString().padLeft(2, '0');
