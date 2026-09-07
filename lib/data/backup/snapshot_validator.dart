/// Offline validation of a snapshot, before anything is written (Task T4).
///
/// Deliberately imports **no drift**: it validates the raw decoded JSON, so it can
/// run on a file the app has never opened, on a phone with a broken DB, and in a
/// pure-Dart tool. If this file ever needs a table class, it's gone wrong — the
/// point is that a repair can be attempted without a working database.
///
/// It rejects instead of repairing. A snapshot with `10.5` in a paise column is a
/// hand-edit mistake or a truncation, and quietly rounding it would put a number
/// in a till that matches no bill ever printed.
library;

const int _maxReportedProblems = 40;

/// Names the enum columns may hold. Kept here as literal lists rather than
/// importing `data/models/enums.dart`: this file must stay import-free of the
/// app's own types so it can validate a snapshot with no other code loaded.
/// (If a model enum gains a value, add it here — the tests fail loudly if not.)
const Set<String> _orderStatuses = {
  'draft', 'open', 'inKitchen', 'ready', 'served', 'partiallyPaid', 'paid', 'voided',
};
const Set<String> _lineStatuses = {'pending', 'fired', 'ready', 'served', 'cancelled'};
const Set<String> _paymentModes = {'cash', 'upi', 'card', 'credit'};
const Set<String> _creditKinds = {'due', 'settled'};
const Set<String> _roles = {'cashier', 'kitchen', 'manager'};
const Set<String> _receiptKinds = {'sale', 'due', 'voidReceipt', 'copy'};

/// Result of validating: enough to show the operator, and enough to decide.
class SnapshotReport {
  SnapshotReport({
    required this.tableNames,
    required this.rowCounts,
    required this.exportedAt,
    required this.schemaVersion,
    required this.problems,
  });

  final List<String> tableNames;
  final Map<String, int> rowCounts;
  final String? exportedAt;
  final int schemaVersion;

  /// Empty means safe to apply. Non-empty means the file is not trustworthy.
  final List<String> problems;

  bool get isValid => problems.isEmpty;
  int get totalRows => rowCounts.values.fold(0, (a, b) => a + b);

  /// One-line summary for a confirmation dialog.
  String get summary =>
      'snapshot of ${exportedAt ?? 'unknown date'} · schema v$schemaVersion · '
      '$totalRows rows across ${rowCounts.length} tables';

  @override
  String toString() => isValid
      ? 'OK: $summary'
      : 'INVALID: $summary — ${problems.length} problem(s):\n${problems.take(15).map((e) => '  · $e').join('\n')}';
}

/// Validates the decoded envelope. Never throws for *content* problems (they come
/// back in `problems`); throws [FormatException] only if the bytes aren't a
/// snapshot at all, since that's a different class of user error.
SnapshotReport validateSnapshot(Map<String, Object?> envelope) {
  final problems = <String>[];
  void bad(String m) {
    if (problems.length < _maxReportedProblems) problems.add(m);
  }

  if (envelope['format'] != 'kazama-pos-snapshot') {
    throw const FormatException(
      "not a Kazama POS snapshot (missing/incorrect 'format' tag) — "
      'pick a file produced by this app',
    );
  }
  final formatVersion = envelope['formatVersion'];
  if (formatVersion is! int) {
    bad('formatVersion must be an integer, found ${formatVersion.runtimeType}');
  } else if (formatVersion > 1) {
    bad(
      'formatVersion $formatVersion is newer than this app reads (1). '
      'Update the app before restoring this file.',
    );
  }

  final tables = envelope['tables'];
  if (tables is! Map) {
    throw const FormatException("snapshot has no 'tables' map — the file is truncated");
  }
  final tableMap = tables.cast<String, Object?>();

  final rowCounts = <String, int>{};
  for (final name in tableMap.keys) {
    final rows = tableMap[name];
    if (rows is! List) {
      bad('table "$name" is not a list of rows');
      continue;
    }
    rowCounts[name] = rows.length;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      if (row is! Map) {
        bad('$name[$i]: row is not an object');
        continue;
      }
      _validateRow(name, row.cast<String, Object?>(), '$name[$i]', bad);
    }
  }

  // Cross-table checks that only the whole file can answer.
  _checkReferents(tableMap, bad);

  return SnapshotReport(
    tableNames: tableMap.keys.toList(growable: false),
    rowCounts: rowCounts,
    exportedAt: envelope['exportedAt'] as String?,
    schemaVersion: (envelope['schemaVersion'] as num?)?.toInt() ?? 0,
    problems: problems,
  );
}

void _validateRow(
  String table,
  Map<String, Object?> row,
  String path,
  void Function(String) bad,
) {
  // 1. money columns: integral, non-negative — the two things a ledger needs.
  for (final entry in row.entries) {
    final key = entry.key;
    if (!key.endsWith('paise')) continue;
    final v = entry.value;
    if (v == null) continue; // tendered_paise etc. are legitimately null
    if (v is! int) {
      bad('$path.$key: money must be whole paise (int), found ${v.runtimeType} <$v>');
      continue;
    }
    if (v < 0 && key != 'rounding_paise') {
      bad('$path.$key: negative money ($v) — only rounding_paise may be negative');
    }
  }

  // 2. counts
  for (final key in const ['sort_order', 'quantity', 'cancelled_quantity', 'attempts', 'tax_percent']) {
    final v = row[key];
    if (v == null) continue;
    if (v is! int) {
      bad('$path.$key: expected an integer count, found <$v>');
    } else if (v < 0) {
      bad('$path.$key: negative count ($v)');
    }
  }

  // 3. enum vocabularies
  void enumField(String column, Set<String> allowed) {
    final v = row[column];
    if (v == null) return;
    if (v is! String || !allowed.contains(v)) {
      bad('$path.$column: "$v" is not one of ${allowed.join('|')}');
    }
  }

  switch (table) {
    case 'orders':
      enumField('status', _orderStatuses);
      enumField('type', const {'dineIn', 'takeaway', 'delivery'});
      final total = (row['total_paise'] as num?)?.toInt() ?? 0;
      final paid = (row['paid_paise'] as num?)?.toInt() ?? 0;
      final due = (row['due_paise'] as num?)?.toInt() ?? 0;
      if (paid > total) bad('$path: paid_paise ($paid) exceeds total_paise ($total) — overpaid bill');
      if (due != total - paid && due != 0) {
        bad('$path: due_paise ($due) != total-paid (${total - paid}) — cached totals disagree');
      }
      final kind = (row['discount_kind'] as num?)?.toInt() ?? 0;
      if (kind < 0 || kind > 2) bad('$path.discount_kind: $kind is not 0/1/2');
      _jsonFieldIsArray(row, 'modifier_group_ids', '$path', bad);
      break;
    case 'order_lines':
      enumField('line_status', _lineStatuses);
      final qty = (row['quantity'] as num?)?.toInt() ?? 0;
      final cancelled = (row['cancelled_quantity'] as num?)?.toInt() ?? 0;
      if (cancelled > qty) bad('$path: cancelled_quantity ($cancelled) exceeds quantity ($qty)');
      _jsonFieldIsArray(row, 'modifiers_json', '$path', bad);
      break;
    case 'payments':
      enumField('mode', _paymentModes);
      final amount = (row['amount_paise'] as num?)?.toInt() ?? 0;
      final tendered = (row['tendered_paise'] as num?)?.toInt();
      if (amount <= 0) bad('$path: a payment row of $amount paise records nothing');
      if (tendered != null && row['mode'] != 'cash') {
        bad('$path: tendered_paise is cash-only, mode is ${row['mode']}');
      }
      if (tendered != null && tendered < amount) {
        bad('$path: tendered ($tendered) is less than the amount applied ($amount)');
      }
      break;
    case 'credit_entries':
      enumField('kind', _creditKinds);
      break;
    case 'users':
      enumField('role', _roles);
      if ((row['pin_hash'] as String?)?.isEmpty ?? true) bad('$path: empty pin_hash');
      break;
    case 'receipts':
      enumField('kind', _receiptKinds);
      break;
    case 'menu_items':
      _jsonFieldIsArray(row, 'modifier_group_ids', '$path', bad);
      break;
    case 'menu_categories':
      _jsonFieldIsArray(row, 'modifier_group_ids', '$path', bad);
      break;
  }
}

void _jsonFieldIsArray(
  Map<String, Object?> row,
  String column,
  String path,
  void Function(String) bad,
) {
  final raw = row[column];
  if (raw == null) return;
  if (raw is! String) {
    bad('$path.$column: expected a JSON string, found ${raw.runtimeType}');
    return;
  }
  // Cheap structural check only — no dart:convert import, to keep this file
  // dependency-free. A malformed array is caught by the reader with a clearer
  // error anyway; this catches the common "someone pasted a number here".
  final t = raw.trim();
  if (!t.startsWith('[') || !t.endsWith(']')) {
    bad('$path.$column: not a JSON array ($raw)');
  }
}

/// Orphans are allowed in a snapshot (a hand-trimmed file is still restorable),
/// but they must be *reported*, because "3 payments point at a ticket that isn't
/// in this file" is how a restored till ends up with money nobody can attribute.
void _checkReferents(Map<String, Object?> tables, void Function(String) bad) {
  Set<String> idsOf(String table) {
    final rows = tables[table];
    if (rows is! List) return const {};
    return {
      for (final r in rows)
        if (r is Map && r['id'] is String) r['id']! as String,
    };
  }

  final orderIds = idsOf('orders');
  for (final table in const ['order_lines', 'payments', 'credit_entries', 'receipts']) {
    final rows = tables[table];
    if (rows is! List) continue;
    final column = table == 'credit_entries' ? 'linked_order_id' : 'order_id';
    var orphans = 0;
    for (final r in rows) {
      if (r is! Map) continue;
      final id = r[column];
      if (id is String && id.isNotEmpty && !orderIds.contains(id)) orphans++;
    }
    if (orphans > 0) {
      bad('$table: $orphans row(s) reference orders missing from this snapshot ($column)');
    }
  }

  final itemIds = idsOf('menu_items');
  final lines = tables['order_lines'];
  if (lines is List) {
    var missing = 0;
    for (final r in lines) {
      if (r is! Map) continue;
      final id = r['item_id'];
      if (id is String && id.isNotEmpty && !itemIds.contains(id)) missing++;
    }
    if (missing > 0) {
      bad('order_lines: $missing row(s) reference menu_items missing from this snapshot');
    }
  }
}
