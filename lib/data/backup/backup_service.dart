/// Export side of backup (Task T4).
///
/// The snapshot is a *dump of rows*, not of models. Reasons: a row set is what
/// SQLite can restore exactly, models drop columns that exist only for sync or
/// debugging, and a model-based snapshot would make the file format hostage to
/// refactorings in `data/models/`. Reading it back into models is the DAO's job.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/db/app_database.dart';
import 'snapshot_format.dart';

/// Thrown for anything a human can fix: a truncated file, a foreign snapshot, a
/// hand-edit that produced `10.5` paise. Carries every problem found, not just the
/// first, because "fix this one and run again" wastes an evening.
class BackupException implements Exception {
  BackupException(this.message, [this.problems = const <String>[]]);

  final String message;
  final List<String> problems;

  @override
  String toString() {
    if (problems.isEmpty) return 'BackupException: $message';
    final list = problems.take(20).map((e) => '\n    · $e').join();
    final more = problems.length > 20 ? '\n    · … ${problems.length - 20} more' : '';
    return 'BackupException: $message (${problems.length} problem(s)):$list$more';
  }
}

/// Directory that holds snapshots. `getApplicationDocumentsDirectory` survives an
/// app update; it does NOT survive uninstall, which is why the file must also be
/// shareable out of the device (T4's `share` flag, wired to the UI in T-P2).
Future<Directory> backupDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory(p.join(docs.path, 'backups'));
  if (!dir.existsSync()) await dir.create(recursive: true);
  return dir;
}

class BackupService {
  BackupService(this.db);

  final AppDatabase db;

  /// Writes `<name>.json` and, unless [withChecksum] is false, `<name>.json.sha256`.
  /// Returns the paths so the caller can show them (and so a test can assert).
  Future<BackupArtifact> export({
    DateTime? at,
    int appSchemaVersion = 0,
    bool withChecksum = true,
    String suffix = 'full',
  }) async {
    final when = at ?? DateTime.now();
    final payload = await buildSnapshot(when, appSchemaVersion: appSchemaVersion);
    final encoded = encodeCanonical(payload);
    final dir = await backupDirectory();
    final file = File(p.join(dir.path, snapshotFileName(when, suffix: suffix)));

    await file.writeAsString(encoded, flush: true);
    final checksum = sha256Hex(utf8.encode(encoded));
    File? checksumFile;
    if (withChecksum) {
      checksumFile = File('${file.path}.sha256');
      await checksumFile.writeAsString('$kSnapshotChecksumPrefix$checksum\n', flush: true);
    }

    return BackupArtifact(
      file: file,
      checksumFile: checksumFile,
      checksum: checksum,
      payload: payload,
      bytes: await file.length(),
    );
  }

  /// The snapshot body: every table as a list of row maps, plus envelope fields.
  /// Ordered parents-first, so the same map can drive restore without re-sorting.
  Future<Map<String, Object?>> buildSnapshot(
    DateTime when, {
    int appSchemaVersion = 0,
  }) async {
    final tables = <String, Object?>{};
    tables['app_meta'] = _rows(await db.select(db.appMeta).get());
    tables['users'] = _rows(await db.select(db.users).get());
    tables['shifts'] = _rows(await db.select(db.shifts).get());
    tables['menu_categories'] = _rows(await db.select(db.menuCategories).get());
    tables['modifier_groups'] = _rows(await db.select(db.modifierGroups).get());
    tables['modifier_options'] = _rows(await db.select(db.modifierOptions).get());
    tables['menu_items'] = _rows(await db.select(db.menuItems).get());
    tables['orders'] = _rows(await db.select(db.orders).get());
    tables['order_lines'] = _rows(await db.select(db.orderLines).get());
    tables['order_events'] = _rows(await db.select(db.orderEvents).get());
    tables['payments'] = _rows(await db.select(db.payments).get());
    tables['credit_entries'] = _rows(await db.select(db.creditEntries).get());
    tables['receipts'] = _rows(await db.select(db.receipts).get());

    return <String, Object?>{
      'format': kSnapshotFormatTag,
      'formatVersion': kSnapshotFormatVersion,
      'schemaVersion': appSchemaVersion > 0 ? appSchemaVersion : db.schemaVersion,
      'exportedAt': when.toUtc().toIso8601String(),
      'rowCounts': {
        for (final e in tables.entries) e.key: (e.value as List).length,
      },
      'tables': tables,
    };
  }

  /// `toJson()` on a drift row class is generated, stable, and gives us the exact
  /// column names the DB uses — which is what makes a hand-edit possible.
  static List<Map<String, Object?>> _rows(List<DataClass> rows) => [
    for (final r in rows) Map<String, Object?>.from(r.toJson() as Map<String, Object?>),
  ];
}

/// Compact, deterministic JSON. Deterministic because the checksum is computed
/// over these exact bytes, so `export()` twice with the same clock and the same
/// data yields the same hash — a property the tests assert and a human relies on
/// when comparing two nightly snapshots.
String encodeCanonical(Map<String, Object?> payload) => jsonEncode(payload);

/// Result of an export, kept small enough to show in a UI toast.
class BackupArtifact {
  BackupArtifact({
    required this.file,
    required this.checksumFile,
    required this.checksum,
    required this.payload,
    required this.bytes,
  });

  final File file;
  final File? checksumFile;
  final String checksum;
  final Map<String, Object?> payload;
  final int bytes;

  /// `rows` across every table — the number to show after "Backup written".
  int get totalRows =>
      (payload['rowCounts'] as Map<String, Object?>).values.fold<int>(
        0,
        (a, b) => a + (b! as int),
      );

  @override
  String toString() => '${file.path} (${bytes}B, sha256 ${checksum.substring(0, 12)}…)';
}
