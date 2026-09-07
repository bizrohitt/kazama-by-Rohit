/// Shared plumbing for drift accessors (Task T3).
///
/// Why this file exists: drift's recommended `@DriftAccessor` pattern needs a way
/// for a DAO to reach the database. Rather than depend on the exact protected
/// member name of a particular drift minor (`db` vs `attachedDatabase`, which has
/// moved between 2.x releases), every DAO declares the one member it needs. If a
/// future drift renames it, this file is the only place that changes.
library;

import 'package:drift/drift.dart';

/// Implemented by `AppDatabase`; consumed by every DAO.
abstract interface class HasDatabase {
  DatabaseConnectionUser get database;
}

/// Base for all DAOs in this app. Keep DAOs thin: a DAO maps rows <-> domain
/// models and nothing else. Business rules belong in `features/*/domain`, and
/// cross-table invariants (the outbox write, the paid-cache recompute) belong in
/// `data/repositories/impl` where a single transaction is visible on one screen.
abstract class KazamaDao with HasDatabase {
  /// Typed handle on the full database, so a DAO can use any table (the menu DAO
  /// reads `app_meta`; the order DAO writes `order_events`). One indirection,
  /// zero duplicated query code.
  AppDatabaseAccess get db => database as AppDatabaseAccess;
}

/// The subset of `AppDatabase` a DAO may rely on. Declared here rather than
/// importing `app_database.dart` to keep the `part`/`part of` chain one-way.
abstract interface class AppDatabaseAccess extends DatabaseConnectionUser {}
