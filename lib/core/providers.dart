/// Composition root — the only place a repository is built from a database (Task U1).
///
/// Features depend on these providers, never on `AppDatabase` directly (R1). That
/// is what lets a widget test override one line and run the entire app against an
/// in-memory database, and what keeps a future Supabase `SyncGateway` to one file.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'db/app_database.dart';
import 'db/connection.dart';
import '../data/backup/backup_service.dart';
import '../data/backup/restore_service.dart';
import '../data/models/enums.dart';
import '../data/models/payment.dart';
import '../data/models/staff.dart';
import '../data/repositories/contract/menu_repository.dart';
import '../data/repositories/contract/order_repository.dart';
import '../data/repositories/contract/payment_repository.dart';
import '../data/repositories/contract/staff_repository.dart';
import '../data/repositories/contract/stock_repository.dart';
import '../data/repositories/impl/menu_repository_impl.dart';
import '../data/repositories/impl/order_repository_impl.dart';
import '../data/repositories/impl/payment_repository_impl.dart';
import '../data/repositories/impl/staff_repository_impl.dart';
import '../data/repositories/impl/stock_repository_impl.dart';
import '../features/printing/queue/printing_service.dart';
import '../features/printing/transport/fake_print_transport.dart';
import '../features/printing/transport/print_transport.dart';
import '../features/staff_auth/domain/pin_hasher.dart';
import '../sync/sync_engine.dart';
import '../sync/sync_gateway.dart';

/// The sync gateway. v1 has no server, so this is [NoopSyncGateway]; replacing it
/// with a Supabase client is ONE line here (SKILLS.md §E1) and touches no screen.
final Provider<SyncGateway> syncGatewayProvider = Provider<SyncGateway>((ref) => const NoopSyncGateway());

/// The outbox drain loop (T5). Non-autodispose on purpose: a sync loop that
/// restarts every time the reports screen is opened would re-release in-flight
/// rows on a phone that is mid-upload. `stop()` is called from the app's
/// dispose path.
final Provider<SyncEngine> syncEngineProvider = Provider<SyncEngine>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return SyncEngine(outbox: db, gateway: ref.watch(syncGatewayProvider), deviceId: ref.watch(deviceIdProvider));
});

/// The one identifier that must not be invented per row: local bill numbers are
/// unique per device (SKILLS.md §C2), and a real server keys on `(deviceId,
/// billNumber)`. v1 ships a single till, so the value is constant and needs no
/// database read on the boot path; when a second device exists, this provider is
/// the ONLY thing that changes — it becomes a `FutureProvider` reading
/// `MetaKeys.deviceId`, and `main.dart` seeds it once at first launch.
final Provider<String> deviceIdProvider = Provider<String>((ref) => 'primary');

/// The live database. Tests override this with `AppDatabase.memory()`.
final Provider<AppDatabase> appDatabaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError('appDatabaseProvider must be overridden (see main.dart)');
});

final Provider<MenuRepository> menuRepositoryProvider =
    Provider<MenuRepository>((ref) => MenuRepositoryImpl(ref.watch(appDatabaseProvider)));

/// Order -> stock wiring lives HERE, not in either feature (R1): the order repo
/// gets a callback that happens to call the stock repo, so neither imports the
/// other and a unit test can construct `OrderRepositoryImpl` with no stock at all.
final Provider<OrderRepositoryImpl> orderRepositoryProvider = Provider<OrderRepositoryImpl>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return OrderRepositoryImpl(
    db,
    onTicketFired: (ticketId, deductions, actorId) =>
        ref.read(stockRepositoryProvider).deductForTicket(
              ticketId: ticketId,
              deductions: deductions,
              actorId: actorId,
            ),
  );
});

/// The same object, seen through its contract, for UI that only reads tickets.
final Provider<OrderRepository> orderRepositoryContractProvider =
    Provider<OrderRepository>((ref) => ref.watch(orderRepositoryProvider));

final Provider<PaymentRepository> paymentRepositoryProvider =
    Provider<PaymentRepository>((ref) => PaymentRepositoryImpl(ref.watch(appDatabaseProvider)));

final Provider<StaffRepository> staffRepositoryProvider = Provider<StaffRepository>((ref) {
  // The hasher is a provider rather than a private const so a test can pin the
  // lockout clock or swap the KDF without touching this file's other lines.
  return StaffRepositoryImpl(
    ref.watch(appDatabaseProvider),
    hasher: ref.watch(pinHasherProvider),
  );
});

final Provider<StockRepository> stockRepositoryProvider =
    Provider<StockRepository>((ref) => StockRepositoryImpl(ref.watch(appDatabaseProvider)));

/// Printing transport. Swapping to a real Bluetooth one is a change HERE only
/// (SKILLS.md §E1); every feature above stays untouched. `flutter_blue_plus`
/// (BSD-3) is the intended P4 driver and is deliberately NOT a dependency yet:
/// adding a BT package pulls Android permissions and a min-SDK bump into a build
/// that has never run on a device, so the seam ships first and the driver lands
/// with the printer on the counter.
final Provider<PrintTransport> printTransportProvider =
    Provider<PrintTransport>((ref) => FakePrintTransport());

/// Backup + restore (T4). Providers so the settings page never constructs a
/// service with the wrong database, and so a test can point both at a temp dir.
final Provider<BackupService> backupServiceProvider =
    Provider<BackupService>((ref) => BackupService(ref.watch(appDatabaseProvider)));
final Provider<RestoreService> restoreServiceProvider =
    Provider<RestoreService>((ref) => RestoreService(ref.watch(appDatabaseProvider)));

/// The queue (P2). Takes repositories rather than the raw DB for its reads, and
/// the DB only to persist `receipts` rows — that asymmetry is deliberate: the
/// receipt log is the queue's own bookkeeping, not shared state.
final Provider<PrintingService> printingProvider = Provider<PrintingService>((ref) {
  return PrintingService(
    db: ref.watch(appDatabaseProvider),
    transport: ref.watch(printTransportProvider),
    payments: ref.watch(paymentRepositoryProvider),
  );
});

final Provider<PinHasher> pinHasherProvider = Provider<PinHasher>((ref) => const PinHasher());

/// The signed-in user (S2/S3), mutable only by sign-in / sign-out. Kept as a
/// plain immutable value rather than a notifier: the counter has one user at a
/// time, and `ref.watch(currentSessionProvider)` rebuilding every screen is
/// exactly the behaviour wanted. Lives HERE rather than in `features/staff_auth`
/// because the shell and every feature read it, and a feature-owned provider
/// would make `core` read up into a feature (R1).
final StateProvider<PosSession> currentSessionProvider =
    StateProvider<PosSession>((ref) => PosSession.anonymous);

/// The signed-in user's role, as the enum rather than the label string (S2). A
/// permission test that compares a display string is a permission test that
/// breaks when somebody localises a label.
final Provider<UserRole?> currentRoleProvider = Provider<UserRole?>((ref) {
  final role = ref.watch(currentSessionProvider).roleName;
  if (role == null) return null;
  // `SignInScreen` stores the DISPLAY label ("Manager"), while
  // `UserRole.fromName` matches the enum name ("manager"); accepting both keeps
  // this provider correct for whatever a session happens to hold, and the
  // `fromName` fallback means an unknown string resolves to the least-privileged
  // role rather than null.
  for (final r in UserRole.values) {
    if (r.label == role || r.name == role) return r;
  }
  return UserRole.fromName(role);
});

/// Open credit accounts, live (Y4). A stream rather than a `FutureBuilder`: the
/// billing screen's "pay later" list and the settings screen's collect-against
/// list must show the same rows, and one shared stream makes "who is still owed"
/// one question with one answer.
final StreamProvider<List<CreditEntry>> openCreditProvider =
    StreamProvider<List<CreditEntry>>((ref) => ref.watch(paymentRepositoryProvider).watchOpenCredit());

/// Which ticket the counter is currently editing (O2). Null = "start a new one".
/// One provider, read by order-taking and billing alike: the Q4 split is about
/// *what each screen writes*, not about them disagreeing on what is open.
final StateProvider<String?> activeTicketIdProvider = StateProvider<String?>((ref) => null);

/// Everyone on the till, live (S2/S3 + the shift screen). A stream from the DB
/// rather than a cached list: a second device enrolling a helper should appear on
/// the shared tablet without an app restart.
final StreamProvider<List<StaffUser>> staffUsersProvider =
    StreamProvider<List<StaffUser>>((ref) => ref.watch(staffRepositoryProvider).watchUsers());

/// The category selected in the order grid (O3). Kept next to the active ticket
/// for the same reason, and it is a plain `String?` (not a value type) because
/// the menu screen's editor also sets it when you tap "open in the till".
final StateProvider<String?> selectedCategoryIdProvider = StateProvider<String?>(
  (ref) => null,
);

/// Boot helper used by `main()`: open the DB, then seed the demo menu and stock
/// exactly once so the counter has something to sell on first launch (M2/I1).
///
/// Seeding belongs here rather than in a screen's `initState`: two widgets
/// mounting at once (order tab + menu tab restored from a cold start) would each
/// call `seedIfEmpty`, and the guard would race. One await at boot cannot.
Future<AppDatabase> bootstrapDatabase() async {
  final db = openAppDatabase();
  final repo = MenuRepositoryImpl(db);
  await repo.seedIfEmpty();
  return db;
}

// --------------------------------------------------------------------- UI ---

/// The tab shown in the shell (U2). Kept as an int rather than an enum in a
/// feature so the shell does not have to import five features to know its own
/// navigation order.
final StateProvider<int> shellTabProvider = StateProvider<int>((ref) => 0);

/// Held tickets right now (O4). The shell badge and the billing tab's "go pay
/// this" list both read this, and both must show the same count.
final StreamProvider<List<OrderTicket>> openTicketsProvider =
    StreamProvider<List<OrderTicket>>((ref) => ref.watch(orderRepositoryProvider).watchOpenTickets());

/// The ticket every counter screen edits (O2/Y1). Null means "start a new one".
final Provider<OrderTicket?> activeTicketProvider = Provider<OrderTicket?>((ref) {
  final id = ref.watch(activeTicketIdProvider);
  if (id == null) return null;
  // Reading the LIST rather than a by-id stream keeps this to one query: the
  // list is already watched for the badge, and a ticket that leaves it (paid,
  // voided) is exactly when the editor must stop editing.
  for (final t in ref.watch(openTicketsProvider).maybeWhen(data: (d) => d, orElse: () => const <OrderTicket>[])) {
    if (t.id == id) return t;
  }
  return null;
});

/// Snackbars here are always one line and always actionable-in-text, because a
/// cashier's hands are full: no dialogs for non-decisions (R5 keeps the styling
/// out, this keeps the *interruptions* out).
void showSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        duration: Duration(seconds: error ? 5 : 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
}
