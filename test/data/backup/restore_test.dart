// Task T4 — restore gate. Run: flutter test test/data/backup/restore_test.dart
//
// The most important file in the project so far: it is the only proof that a till
// can be emptied and rebuilt from a file. If these tests go red, no feature is
// safe to ship, because the recovery path is what makes every other bug fixable.
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazama_pos/core/db/app_database.dart';
import 'package:kazama_pos/core/money/money.dart';
import 'package:kazama_pos/data/backup/backup_service.dart';
import 'package:kazama_pos/data/backup/restore_service.dart';
import 'package:kazama_pos/data/backup/snapshot_format.dart';
import 'package:kazama_pos/data/models/enums.dart';
import 'package:kazama_pos/data/models/order.dart';
import 'package:kazama_pos/data/models/order_line.dart';
import 'package:kazama_pos/data/models/payment.dart';

import 'helpers.dart';

void main() {
  late AppDatabase db;

  setUp(() async => db = await seedDatabase());
  tearDown(() async => db.close());

  Future<void> wipe(AppDatabase db) async {
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

  group('replace mode (a reset phone)', () {
    test('rebuilds the database row-for-row', () async {
      final payload = await payloadOf(db);
      final file = await tempSnapshot(payload);

      await wipe(db);
      expect(await db.select(db.orders).get(), isEmpty);
      expect(await db.select(db.menuItems).get(), isEmpty);

      final result = await RestoreService(db).restoreFile(file, replace: true, confirmReplace: true);
      expect(result.replaced, isTrue);
      expect(result.totalRows, (payload['rowCounts']! as Map).values.fold<int>(0, (a, b) => a + (b! as int)));

      // The rebuilt database must export the identical snapshot — this single
      // assertion is the whole reason backup exists.
      expect(comparable(await payloadOf(db)), comparable(payload));
    });

    test('money, timestamps, discount intent and line snapshots all survive', () async {
      final file = await tempSnapshot(await payloadOf(db));
      await wipe(db);
      await RestoreService(db).restoreFile(file, replace: true, confirmReplace: true);

      final o1 = (await db.ticketById('o1'))!;
      expect(o1.status, OrderStatus.open);
      expect(o1.type, OrderType.dineIn);
      expect(o1.tableOrName, 'T3');
      expect(o1.paid.paise, kTicketPaid);
      expect(o1.due.paise, kTicketDue);
      expect(o1.discount.kind, DiscountKind.absolute);
      expect(o1.discount.value, 440);
      expect(o1.openedAt, at);
      expect(o1.lines.length, 2);
      expect(o1.totals.total.paise, kTicketTotal,
          reason: 'the recomputed aggregate must equal the cached total that was billed');

      final cached = (await (db.select(db.orders)..where((o) => o.id.equals('o1'))).get()).single;
      expect(cached.totalPaise, kTicketTotal);
      expect(cached.roundingPaise, -38, reason: 'the signed ROUNDING line must survive a restore');

      final o2 = (await db.ticketById('o2'))!;
      expect(o2.billNumber, 41, reason: 'a restored bill keeps ITS number, not a new one');
      expect(o2.status, OrderStatus.paid);
      expect(o2.due.paise, 0);
    });

    test('menu, staff, shift, credit and receipt records come back', () async {
      final file = await tempSnapshot(await payloadOf(db));
      await wipe(db);
      await RestoreService(db).restoreFile(file, replace: true, confirmReplace: true);

      final items = await db.watchItems(includeInactive: true).first;
      expect(items.length, 2);
      expect(items.firstWhere((i) => i.id == 'i1').barcode, '8901234');
      expect(items.firstWhere((i) => i.id == 'i1').price.paise, 10000);

      final groups = await db.groupsFor(const {'mg1'});
      expect(groups.single.options.length, 2);
      expect(groups.single.isValidSelectionCount(2), isFalse);

      final user = (await db.select(db.users).get()).single;
      expect(user.role, 'cashier');
      expect(user.pinHash.length, 64);
      expect(user.pinSalt, 'salt');

      expect((await db.select(db.shifts).get()).single.openingFloatPaise, 50000);
      expect((await db.select(db.creditEntries).get()).single.party, 'Sharma ji');
      expect((await db.select(db.receipts).get()).single.transport, 'fake');
      expect((await db.select(db.orderEvents).get()).single.eventType, 'fired');
    });

    test('the bill counter is restored, so numbers do not restart at 1', () async {
      // Simulate a shop that has issued 41 bills.
      for (var i = 0; i < 40; i++) {
        await db.nextBillNumber();
      }
      final file = await tempSnapshot(await payloadOf(db));
      final seqBefore = (await (db.select(db.appMeta)..where((m) => m.metaKey.equals(MetaKeys.billSeq))).get())
          .single
          .metaValue;

      await wipe(db);
      await db.delete(db.appMeta).go();
      expect(await db.select(db.appMeta).get(), isEmpty);

      await RestoreService(db).restoreFile(file, replace: true, confirmReplace: true);
      final seqAfter = (await (db.select(db.appMeta)..where((m) => m.metaKey.equals(MetaKeys.billSeq))).get())
          .single
          .metaValue;
      expect(seqAfter, seqBefore, reason: 'losing the counter reissues duplicate bill numbers');
      expect(int.parse(seqAfter), greaterThan(40));
    });
  });

  group('merge mode (the everyday repair)', () {
    test('adds missing rows without destroying newer work', () async {
      final file = await tempSnapshot(await payloadOf(db));

      // A ticket opened AFTER the snapshot, plus a price change nobody has billed yet.
      await db.replaceTicket(
        OrderTicket(
          id: 'o9',
          type: OrderType.dineIn,
          status: OrderStatus.open,
          tableOrName: 'T7',
          openedBy: 'u1',
          openedAt: at,
          lines: [
            TicketLine(id: 'l9', itemId: 'i1', nameSnapshot: 'Veg Burger', unitPrice: Money(5000), taxPercent: 18),
          ],
        ),
        at: at,
      );
      await db.upsertItem(
        (await db.findItem('i1'))!.copyWith(price: Money(11000)),
        at: at,
      );

      final result = await RestoreService(db).restoreFile(file); // no replace
      expect(result.replaced, isFalse);

      final tickets = await db.select(db.orders).get();
      expect(tickets.map((t) => t.id).toSet(), containsAll(['o1', 'o2', 'o9']),
          reason: 'a merge must never destroy work done after the snapshot');
      expect(tickets.length, 3, reason: 'ids o1/o2 were upserted, not duplicated');
      expect((await db.select(db.payments).get()).length, 2, reason: 'no duplicate payment rows');

      // The restored item overwrote the newer price — documented merge behaviour,
      // asserted so it cannot surprise anyone later.
      expect((await db.findItem('i1'))!.price.paise, 10000);
    });

    test('restoring lines revives a ticket whose lines were lost', () async {
      await db.delete(db.orderLines).go();
      expect((await db.ticketById('o1'))!.lines, isEmpty);

      final result = await RestoreService(db).restoreFile(await tempSnapshot(await payloadOf(db)));
      expect(result.appliedRows['orders'], 2);
      final o1 = (await db.ticketById('o1'))!;
      expect(o1.lines.length, 2);
      expect(o1.totals.total.paise, kTicketTotal, reason: 'ticket foots again, exactly');
    });
  });

  group('safety rails', () {
    test('replace without confirmation changes nothing', () async {
      final file = await tempSnapshot(await payloadOf(db));
      await expectLater(
        RestoreService(db).restoreFile(file, replace: true),
        throwsA(
          isA<BackupException>().having((e) => e.message, 'message', contains('wipes every current row')),
        ),
      );
      expect((await db.select(db.orders).get()).length, 2);
      expect((await db.select(db.menuItems).get()).length, 2);
    });

    test('an invalid snapshot is refused before a single write', () async {
      final payload = decode(await payloadOf(db));
      final payments = (payload['tables']!['payments']! as List).cast<Map<String, Object?>>();
      payments[0]['amount_paise'] = 0;
      final file = await tempSnapshot(withTable(payload, 'payments', payments));

      await expectLater(
        RestoreService(db).restoreFile(file),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('invalid snapshot'))),
      );
      expect((await db.select(db.payments).get()).length, 2, reason: 'nothing was written');
    });

    test('an edited file is caught by its checksum sidecar', () async {
      final file = await tempSnapshot(await payloadOf(db), withChecksum: true);
      final text = await file.readAsString();
      await file.writeAsString(text.replaceFirst('"total_paise":$kTicketTotal', '"total_paise":${kTicketTotal + 1}'));

      await expectLater(
        RestoreService(db).inspect(file),
        throwsA(isA<BackupException>().having((e) => e.message, 'message', contains('checksum mismatch'))),
      );
    });

    test('a file with no sidecar is allowed (repairs have no sidecar)', () async {
      final file = await tempSnapshot(await payloadOf(db)); // withChecksum: false
      final v = await RestoreService(db).inspect(file);
      expect(v.report.isValid, isTrue);
    });

    test('replace writes a pre-restore snapshot that can itself be restored', () async {
      final file = await tempSnapshot(await payloadOf(db));
      final result = await RestoreService(db).restoreFile(file, replace: true, confirmReplace: true);
      expect(result.preWipeFile, isNotNull);
      expect(await result.preWipeFile!.exists(), isTrue);

      final re = await RestoreService(db).restoreFile(result.preWipeFile!);
      expect(re.totalRows, greaterThan(0));
      expect((await db.select(db.orders).get()).length, 2);
    });

    test('a corrupt newest file falls back to the next good one', () async {
      final dir = await Directory.systemTemp.createTemp('kazama_t4_latest');
      await File('${dir.path}/${snapshotFileName(DateTime.utc(2026, 1, 1))}')
          .writeAsString(encodeCanonical(await payloadOf(db)));
      await File('${dir.path}/${snapshotFileName(DateTime.utc(2026, 9, 3))}')
          .writeAsString('{"this is": "not json"');

      final result = await RestoreService(db).restoreLatest(dir, replace: true, confirmReplace: true);
      expect(result, isNotNull, reason: 'a broken nightly file must not block recovery');
      expect(result!.totalRows, greaterThan(10));
      await dir.delete(recursive: true);
    });

    test('a snapshot of a newer file format is refused', () async {
      final payload = {...decode(await payloadOf(db)), 'formatVersion': 7};
      await expectLater(
        RestoreService(db).restoreFile(await tempSnapshot(payload)),
        throwsA(isA<BackupException>()),
      );
    });
  });

  group('scale', () {
    test('a 500-ticket day exports fast enough to run mid-service', () async {
      final sw = Stopwatch()..start();
      for (var i = 0; i < 500; i++) {
        await db.replaceTicket(
          OrderTicket(
            id: 'bulk$i',
            billNumber: 1000 + i,
            type: OrderType.takeaway,
            status: OrderStatus.paid,
            openedBy: 'u1',
            openedAt: at,
            closedAt: at,
            paid: Money(10000),
            due: Money(0),
            lines: [
              TicketLine(
                id: 'bl${i}a',
                itemId: 'i1',
                nameSnapshot: 'Veg Burger',
                unitPrice: Money(10000),
                taxPercent: 18,
              ),
            ],
          ),
          at: at,
        );
      }
      final payload = await payloadOf(db);
      sw.stop();
      final kb = (encodeCanonical(payload).length / 1024).toStringAsFixed(0);
      expect(payload['tables']!['orders']! as List, hasLength(502));
      expect(sw.elapsedMilliseconds, lessThan(5000),
          reason: 'export took ${sw.elapsedMilliseconds}ms for $kb KB — a counter cannot wait longer');
      // ignore: avoid_print
      print('T4 scale: 502 tickets -> $kb KB in ${sw.elapsedMilliseconds}ms');
    });
  });
}
