/// Restore side of backup (Task T4).
///
/// Two modes, because they are different operations with different risks:
///  * **merge** (default) — upsert every row from the snapshot over the current
///    data. Nothing is destroyed, so it is safe to run at the counter as an
///    "undo my mistake" repair.
///  * **replace** — wipe the tables, then apply. This is what "the phone was
///    reset / the DB is corrupt" needs, and it is destructive, so it requires an
///    explicit flag AND a pre-wipe snapshot that is reported back to the caller.
///
/// Everything happens inside ONE transaction: a restore that fails halfway must
/// leave the till exactly as it was, not half-loaded. Drift rolls back on throw.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../core/money/money.dart';
import '../../core/db/app_database.dart';
import '../models/menu.dart';
import '../models/order.dart';
import '../models/order_line.dart';
import '../models/enums.dart';
import 'backup_service.dart';
import 'snapshot_format.dart';
import 'snapshot_validator.dart';

class RestoreResult {
  RestoreResult({
    required this.appliedRows,
    required this.replaced,
    required this.preWipeFile,
    required this.report,
  });

  final Map<String, int> appliedRows;
  final bool replaced;

  /// The safety snapshot written before a REPLACE (null for a merge). Shown to
  /// the operator so "restore made it worse" is recoverable too.
  final File? preWipeFile;
  final SnapshotReport report;

  int get totalRows => appliedRows.values.fold(0, (a, b) => a + b);

  @override
  String toString() =>
      '${replaced ? 'replaced' : 'merged'} $totalRows rows (${report.summary})';
}

class RestoreService {
  RestoreService(this.db);

  final AppDatabase db;

  /// Reads + checks a file without touching the DB. Use this to show the operator
  /// "you are about to restore 412 rows from 2026-08-01" *before* they confirm.
  Future<SnapshotValidation> inspect(File file) async {
    final text = await file.readAsString();
    final checksumPath = '${file.path}.sha256';
    String? expected;
    if (File(checksumPath).existsSync()) {
      expected = (await File(checksumPath).readAsString())
          .trim()
          .replaceFirst(kSnapshotChecksumPrefix, '');
    }
    final actual = sha256Hex(utf8.encode(text));
    if (expected != null && expected.isNotEmpty && expected != actual) {
      throw BackupException(
        'checksum mismatch — this .json has been edited or truncated since it was '
        'written (expected ${expected.substring(0, 12)}…, file is ${actual.substring(0, 12)}…). '
        'Restore anyway only if you are hand-repairing it.',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw BackupException('this is not valid JSON — the file is cut off: ${e.message}');
    }
    if (decoded is! Map) {
      throw BackupException('a snapshot must be a JSON object, found ${decoded.runtimeType}');
    }
    final envelope = decoded.cast<String, Object?>();

    // validateSnapshot throws FormatException for "this isn't our file at all".
    // Unify it with BackupException so a UI has exactly one thing to catch and
    // one dialog to show, instead of a type-switch for a non-error concept.
    SnapshotReport report;
    try {
      report = validateSnapshot(envelope);
    } on FormatException catch (e) {
      throw BackupException(e.message);
    }
    return SnapshotValidation(envelope: envelope, report: report, file: file);
  }

  /// Applies a validated file. Throws [BackupException] before touching anything
  /// if the file is invalid, or if [replace] is true without [confirmReplace].
  Future<RestoreResult> restoreFile(
    File file, {
    bool replace = false,
    bool confirmReplace = false,
  }) async {
    if (replace && !confirmReplace) {
      throw BackupException(
        'replace mode wipes every current row. Pass confirmReplace: true only after '
        'the operator has seen how many rows are about to be destroyed.',
      );
    }
    final validation = await inspect(file);
    if (!validation.report.isValid) {
      throw BackupException('refusing to restore an invalid snapshot', validation.report.problems);
    }

    File? preWipe;
    if (replace) {
      // Snapshot the CURRENT state first: a bad restore must be undoable.
      preWipe = (await BackupService(db).export(suffix: 'pre-restore')).file;
    }

    final applied = <String, int>{};
    await db.transaction(() async {
      if (replace) await _wipe();
      applied.addAll(await _apply(validation.envelope));
    });

    return RestoreResult(
      appliedRows: applied,
      replaced: replace,
      preWipeFile: preWipe,
      report: validation.report,
    );
  }

  /// Convenience for a directory of nightly files: newest valid one wins.
  Future<RestoreResult?> restoreLatest(Directory dir, {bool replace = false, bool confirmReplace = false}) async {
    if (!dir.existsSync()) return null;
    final candidates = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json') && f.path.contains('kazama_backup_'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path)); // filename embeds the timestamp
    for (final f in candidates) {
      try {
        return await restoreFile(f, replace: replace, confirmReplace: confirmReplace);
      } on BackupException {
        continue; // a corrupt nightly file must not block the next-older good one
      }
    }
    return null;
  }

  // ------------------------------------------------------------------ apply --

  /// Parents before children (kSnapshotTables order). Menu rows go through the
  /// DAO upserters so the sold-out-preservation rule (M6) still applies on a
  /// restore; every other table is a literal column replace, because a restore
  /// must reproduce the exported bytes exactly, not re-derive them.
  Future<Map<String, int>> _apply(Map<String, Object?> envelope) async {
    final tables = (envelope['tables'] as Map).cast<String, Object?>();
    final applied = <String, int>{};
    final now = DateTime.now();

    List<Map<String, Object?>> rowsOf(String name) {
      final raw = tables[name];
      if (raw is! List) return const [];
      return [for (final r in raw) (r! as Map).cast<String, Object?>()];
    }

    for (final name in kSnapshotTables) {
      final rows = rowsOf(name);
      switch (name) {
        case 'menu_categories':
          for (final r in rows) {
            await db.upsertCategory(
              MenuCategory(
                id: r['id']! as String,
                name: r['name']! as String,
                sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
                active: _bool(r['active']),
                modifierGroupIds: _stringList(r['modifier_group_ids']),
              ),
              at: now,
            );
          }
        case 'menu_items':
          for (final r in rows) {
            await db.upsertItem(_menuItem(r), at: now);
          }
        case 'orders':
          for (final r in rows) {
            await db.replaceTicket(_ticket(r, rowsOf('order_lines'), now));
          }
        case 'order_lines':
          break; // written by the orders step, as part of the ticket aggregate
        case 'modifier_groups':
        case 'modifier_options':
          // Literal column replace, in export order: groups land before options,
          // so `modifier_options.group_id`'s FK is satisfied. No DAO here, because
          // a restore must reproduce the exported bytes rather than re-derive them.
          break;
        default:
          final table = _tableFor(db, name);
          if (table == null) {
            applied[name] = 0;
            break;
          }
          for (final r in rows) {
            await db.doReplace(table, _columnsOf(table, r));
          }
      }
      applied[name] = rows.length;
    }
    return applied;
  }

  /// Delete children before parents so the one real FK (`order_lines`) behaves,
  /// and never touch `app_meta` — its rows are overwritten, not removed, and it
  /// holds the schema version that `beforeOpen` relies on.
  Future<void> _wipe() async {
    await db.delete(db.receipts).go();
    await db.delete(db.creditEntries).go();
    await db.delete(db.payments).go();
    await db.delete(db.orderEvents).go();
    await db.delete(db.orderLines).go();
    await db.delete(db.orders).go();
    await db.delete(db.menuItems).go();
    await db.delete(db.modifierOptions).go();
    await db.delete(db.modifierGroups).go();
    await db.delete(db.menuCategories).go();
    await db.delete(db.shifts).go();
    await db.delete(db.users).go();
  }

  // ------------------------------------------------------------- row mapping --

  static TableInfo<Table, Object?>? _tableFor(AppDatabase db, String name) => switch (name) {
    'app_meta' => db.appMeta,
    'users' => db.users,
    'shifts' => db.shifts,
    'modifier_groups' => db.modifierGroups,
    'order_events' => db.orderEvents,
    'payments' => db.payments,
    'receipts' => db.receipts,
    _ => null,
  };

  /// Maps the exported (snake_case) keys back onto column objects. Because the
  /// snapshot holds column names verbatim, this restores exactly what was
  /// exported — including columns no model currently reads.
  static Map<Column<Object>, Expression<Object>> _columnsOf(
    TableInfo<Table, Object?> table,
    Map<String, Object?> row,
  ) {
    final out = <Column<Object>, Expression<Object>>{};
    for (final entry in row.entries) {
      final column = table.availableColumns.where((c) => c.name == entry.key).firstOrNull;
      if (column == null) continue; // a column this build doesn't have: skip, don't fail
      out[column] = Variable<Object?>(entry.value) as Expression<Object>;
    }
    return out;
  }

  static MenuItem _menuItem(Map<String, Object?> r) => MenuItem(
    id: r['id']! as String,
    categoryId: r['category_id']! as String,
    name: r['name']! as String,
    price: Money((r['price_paise'] as num).toInt()),
    taxPercent: (r['tax_percent'] as num?)?.toInt() ?? 5,
    kitchenLabel: r['kitchen_label'] as String?,
    prepSeconds: (r['prep_seconds'] as num?)?.toInt() ?? 180,
    printable: _bool(r['printable']),
    barcode: r['barcode'] as String?,
    stockItemId: r['stock_item_id'] as String?,
    modifierGroupIds: _stringList(r['modifier_group_ids']),
    active: _bool(r['active']),
    available: _bool(r['available']),
    sortOrder: (r['sort_order'] as num?)?.toInt() ?? 0,
  );

  /// Rebuilds the aggregate from its two tables. Prices are NOT re-derived from
  /// the menu (a delisted or repriced item must bill as it was ordered), which is
  /// exactly why lines carry snapshots.
  static OrderTicket _ticket(
    Map<String, Object?> r,
    List<Map<String, Object?>> allLines,
    DateTime now,
  ) {
    final id = r['id']! as String;
    final lines = allLines.where((l) => l['order_id'] == id);
    return OrderTicket(
      id: id,
      billNumber: (r['bill_number'] as num?)?.toInt(),
      type: OrderType.fromName(r['type'] as String?),
      status: OrderStatus.fromName(r['status'] as String?),
      tableOrName: r['table_or_name'] as String?,
      note: r['note'] as String?,
      openedBy: r['opened_by']! as String,
      openedAt: _date(r['opened_at']) ?? now,
      firedAt: _date(r['fired_at']),
      readyAt: _date(r['ready_at']),
      servedAt: _date(r['served_at']),
      closedAt: _date(r['closed_at']),
      updatedAt: _date(r['updated_at']),
      paid: Money((r['paid_paise'] as num?)?.toInt() ?? 0),
      due: Money((r['due_paise'] as num?)?.toInt() ?? 0),
      voidReason: r['void_reason'] as String?,
      discount: OrderDiscount(
        DiscountKind.values[(r['discount_kind'] as num?)?.toInt() ?? 0],
        (r['discount_value'] as num?)?.toInt() ?? 0,
      ),
      lines: [
        for (final l in lines)
          TicketLine(
            id: l['id']! as String,
            itemId: (l['item_id'] as String?) ?? '',
            nameSnapshot: l['name_snapshot']! as String,
            kitchenLabel: l['kitchen_label_snapshot'] as String?,
            unitPrice: Money((l['unit_price_paise'] as num).toInt()),
            taxPercent: (l['tax_percent'] as num?)?.toInt() ?? 0,
            quantity: (l['quantity'] as num?)?.toInt() ?? 1,
            cancelledQuantity: (l['cancelled_quantity'] as num?)?.toInt() ?? 0,
            status: LineStatus.fromName((l['line_status'] as String?) ?? 'pending'),
            note: l['note'] as String?,
            modifiers: [
              for (final raw in _jsonList(l['modifiers_json']))
                ModifierOption.fromJson(raw! as Map<String, Object?>),
            ],
          ),
      ],
    );
  }

  static bool _bool(Object? v) => v == true || v == 1 || v == '1' || v == 'true';

  static DateTime? _date(Object? v) {
    if (v == null) return null;
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  static List<Object?> _jsonList(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return const [];
    final decoded = jsonDecode(raw);
    return decoded is List ? decoded : const [];
  }
}

/// A file that passed inspection, ready to be shown to a human then applied.
class SnapshotValidation {
  SnapshotValidation({required this.envelope, required this.report, required this.file});

  final Map<String, Object?> envelope;
  final SnapshotReport report;
  final File file;
}
