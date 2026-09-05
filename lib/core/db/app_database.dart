/// The one database this app talks to (Task T3).
///
/// Everything below is local-first by construction: no query awaits a network
/// call, and `synced_at`-style "is it uploaded yet" state was deliberately
/// **not** added — the outbox (T5) is the only sync state the app needs, and
/// letting two sources exist is how they start disagreeing. The UI must never be
/// able to ask "has this row uploaded?" because it must render either way.
///
/// DAOs are mixed in with `with` rather than drift's `@DriftAccessor`
/// annotation: same result, one less generated layer, and a DAO reads as a plain
/// class when you open it next to its table definitions.
library;

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../../core/money/money.dart';
import '../../data/daos/dao_base.dart';
import '../../data/daos/menu_dao.dart';
import '../../data/daos/orders_dao.dart';
import '../../data/models/enums.dart';
import '../../data/models/menu.dart';
import '../../data/models/mutation.dart';
import '../../data/models/order.dart';
import '../../data/models/payment.dart';
import '../../data/models/staff.dart';
import '../../data/models/stock.dart';
import '../../data/tables/menu_tables.dart';
import '../../data/tables/money_tables.dart';
import '../../data/tables/order_tables.dart';
import '../../data/tables/stock_tables.dart';

part 'app_database.g.dart';
part '../../data/daos/menu_dao.dart';
part '../../data/daos/orders_dao.dart';
// The secondary DAOs (credit/stock/staff/payments) are a `part` of THIS library
// rather than an import: that is what lets them call `select(table)` with no
// drift import of their own and no exposure of generated row types to callers.
part '../../data/daos/aux_dao.dart';
part '../../data/daos/outbox_dao.dart';

@DriftDatabase(
  tables: [
    MenuCategories,
    ModifierGroups,
    ModifierOptions,
    MenuItems,
    AppMeta,
    Orders,
    OrderLines,
    OrderEvents,
    SyncOutbox,
    Payments,
    CreditEntries,
    Users,
    Shifts,
    Receipts,
    StockItems,
    ItemRecipes,
    StockMovements,
  ],
)
class AppDatabase extends _$AppDatabase
    with MenuDao, OrdersDao, CreditDao, StockDao, StaffDao, PaymentDao, OutboxDao {
  AppDatabase(super.e);

  /// In-memory instance for `flutter test` (T3's gate) and any later harness.
  AppDatabase.memory() : super(NativeDatabase.memory());

  /// Bumping this without writing the matching `onUpgrade` block fails loudly at
  /// startup instead of silently corrupting a till — that is the whole point of
  /// the funnel below.
  @override
  int get schemaVersion => 3;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      // v1 has no historical version to migrate from. Every future bump MUST add
      // a matching `if (from < N)` block here and MUST NOT call `createAll()`
      // again (that would drop real sales). The guard makes a forgotten block
      // impossible to ship rather than something a user discovers.
      // v1 -> v2: the inventory tables (I1). `createAll()` emits
      // `CREATE TABLE IF NOT EXISTS`, so this is additive and repeatable: an
      // existing till keeps every sale, and re-running the upgrade after a crash
      // halfway through cannot fail. That property is why this is the template
      // for every later additive migration; a column *change* must NOT reuse it.
      if (from < 2) {
        await m.createAll();
      }
      // v2 -> v3: `sync_outbox.last_error` (T5). Same additive trick as above —
      // `CREATE TABLE IF NOT EXISTS` for a fresh file, and the ALTER below for an
      // existing one. A nullable column with no default needs no backfill, which
      // is why this migration is safe to re-run after a crash mid-upgrade.
      if (from < 3) {
        await m.createAll();
        if (from >= 2) {
          await customStatement(
            'ALTER TABLE sync_outbox ADD COLUMN last_error TEXT',
          );
        }
      }
      if (!_migrationKnown(from)) {
        throw StateError(
          'schemaVersion $from -> $to has no migration. Add it in '
          'MigrationStrategy.onUpgrade before this build goes near a counter.',
        );
      }
    },
    beforeOpen: (details) async {
      // Drift turns FK enforcement on itself for `NativeDatabase`, so no PRAGMA
      // here. What IS worth recording is the version a file was created/last
      // opened at, because "the DB is from an older build" is the first question
      // in any field-reported corruption bug.
      await into(appMeta).insertOnConflictUpdate(
        _meta(MetaKeys.schemaVersion, '$schemaVersion'),
      );
      if (details.wasCreated) {
        // 32 columns = 58 mm paper, the common Indian counter printer (open
        // question in SESSION_LOG). Overwritten by the printer settings screen
        // (P4) and read by the receipt renderer (P1) — never hardcoded there.
        await into(appMeta).insertOnConflictUpdate(
          _meta(MetaKeys.printerPaperColumns, '32'),
        );
        await into(appMeta).insertOnConflictUpdate(
          _meta(MetaKeys.taxInclusive, '1'), // menu prices include GST (Q-open)
        );
      }
    },
  );

  /// Every version pair that has a real migration written above.
  static bool _migrationKnown(int from) => from == 0 || from == 1 || from == 2;

  static AppMetaCompanion _meta(String key, String value) => AppMetaCompanion.insert(
    metaKey: key,
    metaValue: value,
    updatedAt: DateTime.now(),
  );
}
