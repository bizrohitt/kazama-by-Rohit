/// Opening the database (Task T3).
///
/// Two things this deliberately does NOT do, and both are decisions rather than
/// omissions:
///  * **No background isolate.** drift's `DatabaseConnection` isolates are the
///    documented answer to jank on huge DBs. A single-branch fast-food till has
///    thousands of rows, so an isolate would add a serialisation boundary to every
///    query for no measurable gain — and it makes the stream-based reads (K1, O4)
///    harder to reason about. Revisit only if a device report says otherwise.
///  * **No `drift_flutter`.** Its `driftDatabase(name:)` helper is nicer to write
///    but is a smaller package whose API moved more than once; going through
///    `path_provider` + `drift/native.dart` uses two APIs that have been stable
///    for years, and T4 needs `path_provider` anyway for backup files.
library;

import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_database.dart';

const String _fileName = 'kazama_pos.sqlite';

/// The single entry point every feature uses. Nothing in `features/` may open a
/// database or run a migration — that's this file's job (R1).
AppDatabase openAppDatabase({bool forTests = false}) {
  if (forTests) return AppDatabase.memory();
  return AppDatabase(
    LazyDatabase(() async {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(p.join(dir.path, _fileName));
      return NativeDatabase.openDatabase(file);
    }),
  );
}

/// Absolute path of the live DB file, for the backup/restore screens (T4) and for
/// "where is my data?" when a customer calls. Returns null in-memory/test mode so
/// a test can never copy a real till's file by accident.
Future<String?> databaseFilePath({bool forTests = false}) async {
  if (forTests) return null;
  final dir = await getApplicationDocumentsDirectory();
  return p.join(dir.path, _fileName);
}

/// Size on disk in bytes — the number that decides whether a backup can be
/// shared over WhatsApp (it can, at these sizes) and the one that grows fastest.
Future<int?> databaseFileSize() async {
  final path = await databaseFilePath();
  if (path == null) return null;
  final file = File(path);
  return file.existsSync() ? await file.length() : 0;
}
