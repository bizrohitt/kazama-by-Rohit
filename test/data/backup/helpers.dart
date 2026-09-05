// Shared fixtures for the T4 backup/restore tests (Task T4).
//
// A file, not a `part`, so each T4 test file runs on its own:
// `flutter test test/data/backup/restore_test.dart` is how you bisect a restore
// failure without re-running the export suite.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:kazama_pos/core/db/app_database.dart';
import 'package:kazama_pos/core/money/money.dart';
import 'package:kazama_pos/data/backup/backup_service.dart';
import 'package:kazama_pos/data/backup/snapshot_format.dart';
import 'package:kazama_pos/data/models/enums.dart';
import 'package:kazama_pos/data/models/menu.dart';
import 'package:kazama_pos/data/models/order.dart';
import 'package:kazama_pos/data/models/order_line.dart';
import 'package:kazama_pos/data/models/payment.dart';

final DateTime at = DateTime.utc(2026, 9, 3, 20, 30);

/// The dine-in ticket's numbers, hand-computed so a wrong total anywhere in the
/// pipeline (tax split, discount allocation, rounding, DAO cache) fails loudly:
///   lines 10000p@18% + 23456p@18%   -> bases 8475 + 19878 = 28353
///   discount 440p split 132 / 308   -> discounted bases 8343 / 19570
///   tax 1502 + 3523 = 5025          -> 28353 - 440 + 5025 = 32938
///   rounded to the rupee            -> 33000 (₹330.00), ROUNDING line -38p
const int kTicketTotal = 33000;
const int kTicketPaid = 15000;
const int kTicketDue = 18000;
const int kTicketBase = 28353;
const int kTicketTax = 5025;

/// A representative till: priced menu with modifiers, one open dine-in ticket
/// carrying a discount and a split payment, one settled takeaway, a customer due,
/// a shift, a staff user, an audit event and a printed-slip record.
Future<AppDatabase> seedDatabase() async {
  final db = AppDatabase(NativeDatabase.memory());
  await db.upsertCategory(
    MenuCategory(id: 'c1', name: 'Burgers', sortOrder: 1, modifierGroupIds: const ['mg1']),
    at: at,
  );
  await db.upsertGroup(
    const ModifierGroup(
      id: 'mg1',
      name: 'Size',
      minSelect: 1,
      maxSelect: 1,
      required: true,
      options: [
        ModifierOption(id: 'm1', groupId: 'mg1', name: 'Regular', priceDelta: Money(0)),
        ModifierOption(id: 'm2', groupId: 'mg1', name: 'Large', priceDelta: Money(2500)),
      ],
    ),
    at: at,
  );
  await db.upsertItem(
    MenuItem(
      id: 'i1',
      categoryId: 'c1',
      name: 'Veg Burger',
      price: Money(10000),
      taxPercent: 18,
      barcode: '8901234',
    ),
    at: at,
  );
  await db.upsertItem(
    MenuItem(id: 'i2', categoryId: 'c1', name: 'Chicken Burger', price: Money(23456), taxPercent: 18),
    at: at,
  );

  await db.replaceTicket(
    OrderTicket(
      id: 'o1',
      type: OrderType.dineIn,
      status: OrderStatus.open,
      tableOrName: 'T3',
      openedBy: 'u1',
      openedAt: at,
      updatedAt: at,
      discount: const OrderDiscount(DiscountKind.absolute, 440),
      lines: [
        TicketLine(id: 'l1', itemId: 'i1', nameSnapshot: 'Veg Burger', unitPrice: Money(10000), taxPercent: 18),
        TicketLine(id: 'l2', itemId: 'i2', nameSnapshot: 'Chicken Burger', unitPrice: Money(23456), taxPercent: 18),
      ],
    ),
    at: at,
  );
  await db.insertPayment(
    Payment(
      id: 'p1',
      orderId: 'o1',
      mode: PaymentMode.cash,
      amount: Money(kTicketPaid),
      tendered: Money(20000),
      change: Money(5000),
      recordedBy: 'u1',
      at: at,
    ),
  );

  await db.replaceTicket(
    OrderTicket(
      id: 'o2',
      billNumber: 41,
      type: OrderType.takeaway,
      status: OrderStatus.paid,
      openedBy: 'u1',
      openedAt: at,
      closedAt: at,
      updatedAt: at,
      paid: Money(10000),
      due: Money(0),
      lines: [
        TicketLine(id: 'l3', itemId: 'i1', nameSnapshot: 'Veg Burger', unitPrice: Money(10000), taxPercent: 18),
      ],
    ),
    at: at,
  );
  await db.insertPayment(
    Payment(
      id: 'p2',
      orderId: 'o2',
      mode: PaymentMode.upi,
      amount: Money(10000),
      reference: 'GPay 88213',
      recordedBy: 'u1',
      at: at,
    ),
  );

  await db.appendEvent(orderId: 'o1', eventType: 'fired', actorId: 'u1', at: at);
  await db.into(db.creditEntries).insert(
    CreditEntriesCompanion.insert(
      id: 'ce1',
      party: 'Sharma ji',
      amountPaise: 45000,
      kind: 'due',
      phone: const Value('9876543210'),
      linkedOrderId: const Value('o1'),
      createdBy: 'u1',
      at: at,
    ),
  );
  await db.into(db.users).insert(
    UsersCompanion.insert(
      id: 'u1',
      name: 'Zaid',
      role: 'cashier',
      pinHash: 'a' * 64,
      pinSalt: 'salt',
      createdAt: at,
      updatedAt: at,
    ),
  );
  await db.into(db.shifts).insert(
    ShiftsCompanion.insert(id: 's1', userId: 'u1', openingFloatPaise: const Value(50000), openedAt: at),
  );
  await db.into(db.receipts).insert(
    ReceiptsCompanion.insert(id: 'r1', orderId: 'o2', kind: 'sale', transport: 'fake', delivered: true, at: at),
  );
  return db;
}

/// Snapshot body exactly as the export service builds it.
Future<Map<String, Object?>> payloadOf(AppDatabase db) =>
    BackupService(db).buildSnapshot(at, appSchemaVersion: 1);

/// Passes through the real encoder so the tests validate the runtime types a file
/// read produces (`List<Object?>`, not a hand-built `List<Map<String, Object?>>`).
Map<String, Object?> decode(Map<String, Object?> payload) =>
    jsonDecode(jsonEncode(payload)) as Map<String, Object?>;

Future<File> tempSnapshot(Map<String, Object?> payload, {bool withChecksum = false}) async {
  final dir = await Directory.systemTemp.createTemp('kazama_t4_file');
  final file = File('${dir.path}/${snapshotFileName(at)}');
  final encoded = encodeCanonical(payload);
  await file.writeAsString(encoded);
  if (withChecksum) {
    await File('${file.path}.sha256').writeAsString(
      '$kSnapshotChecksumPrefix${sha256(utf8.encode(encoded))}\n',
    );
  }
  return file;
}

/// Writes a single table's rows back into a payload, keeping every other byte.
Map<String, Object?> withTable(
  Map<String, Object?> payload,
  String table,
  List<Map<String, Object?>> rows,
) => {
  ...payload,
  'tables': {
    ...(payload['tables']! as Map).cast<String, Object?>(),
    table: rows,
  },
};

/// Compares two payloads, ignoring fields that legitimately change per export.
String comparable(Map<String, Object?> payload) {
  final copy = Map<String, Object?>.from(payload)..remove('exportedAt');
  final tables = Map<String, Object?>.from(copy['tables']! as Map);
  tables['app_meta'] = []; // schema bookkeeping, not sales data
  // DAO writes stamp `updated_at`, so a restore legitimately moves it. Stripping
  // it keeps the comparison about DATA (money, ids, statuses, lines) while still
  // catching a dropped or mis-mapped column.
  for (final e in tables.entries.toList()) {
    tables[e.key] = (e.value! as List)
        .map((r) => (r! as Map).cast<String, Object?>()..remove('updated_at'))
        .toList();
  }
  copy['tables'] = tables;
  return jsonEncode(copy);
}
