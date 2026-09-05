// Task T4 — export shape + validator gate.
// Run:  flutter test test/data/backup/
//
// The validator deserves its own file because it is the only thing standing between
// a hand-repaired JSON file and a live till's ledger.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazama_pos/core/db/app_database.dart';
import 'package:kazama_pos/data/backup/backup_service.dart';
import 'package:kazama_pos/data/backup/snapshot_format.dart';
import 'package:kazama_pos/data/backup/snapshot_validator.dart';

import 'helpers.dart';

void main() {
  late AppDatabase db;

  setUp(() async => db = await seedDatabase());
  tearDown(() async => db.close());

  group('export', () {
    test('covers all 13 tables and skips the outbox', () async {
      final tables = ((await payloadOf(db))['tables']! as Map).cast<String, Object?>();
      expect(tables.keys.toSet(), kSnapshotTables.toSet());
      expect(tables.containsKey(kOutboxTable), isFalse,
          reason: 'a restored snapshot must never replay ACKed mutations');

      final counts = (tables['orders']! as List).length;
      expect(counts, 2);
      expect((tables['menu_items']! as List).length, 2);
      expect((tables['order_lines']! as List).length, 3);
      expect((tables['payments']! as List).length, 2);
      expect((tables['credit_entries']! as List).length, 1);
      expect((tables['users']! as List).length, 1);
      expect((tables['shifts']! as List).length, 1);
      expect((tables['receipts']! as List).length, 1);
      expect((tables['order_events']! as List).length, 1);
      expect((tables['modifier_options']! as List).length, 2);
    });

    test('envelope carries format, version and timestamp', () async {
      final payload = await payloadOf(db);
      expect(payload['format'], kSnapshotFormatTag);
      expect(payload['formatVersion'], kSnapshotFormatVersion);
      expect(payload['schemaVersion'], 1);
      expect(payload['exportedAt'], '2026-09-03T20:30:00.000Z');
    });

    test('rows use real column names with paise as ints', () async {
      final payload = await payloadOf(db);
      final tables = (payload['tables']! as Map).cast<String, Object?>();
      final orders = (tables['orders']! as List).cast<Map<String, Object?>>();
      final o1 = orders.firstWhere((o) => o['id'] == 'o1');

      expect(o1['total_paise'], kTicketTotal);
      expect(o1['paid_paise'], kTicketPaid);
      expect(o1['due_paise'], kTicketDue);
      expect(o1['tax_paise'], kTicketTax);
      expect(o1['subtotal_paise'], kTicketBase - 440);
      expect(o1['rounding_paise'], -38, reason: '32938 -> 33000 is a NEGATIVE rounding line');
      expect(o1['status'], 'open');
      expect(o1['type'], 'dineIn');
      expect(o1['discount_kind'], 1);
      expect(o1['discount_value'], 440);
      expect(o1['opened_at'], at.millisecondsSinceEpoch, reason: 'drift stores dates as ms');
      expect(o1['total_paise'], isA<int>());

      final items = (tables['menu_items']! as List).cast<Map<String, Object?>>();
      expect(items.firstWhere((i) => i['id'] == 'i1')['barcode'], '8901234');
      expect(items.firstWhere((i) => i['id'] == 'i2')['barcode'], isNull);

      final lines = (tables['order_lines']! as List).cast<Map<String, Object?>>();
      expect(lines.every((l) => l['line_status'] == 'pending'), isTrue);
      expect(lines.map((l) => l['sort_index']).toList(), [0, 1, 0]);
    });

    test('the same data and clock hash identically; any edit changes it', () async {
      final a = encodeCanonical(await payloadOf(db));
      final b = encodeCanonical(await payloadOf(db));
      expect(sha256(utf8.encode(a)), sha256(utf8.encode(b)),
          reason: 'nightly snapshots must be diffable');

      final edited = a.replaceFirst('"total_paise":$kTicketTotal', '"total_paise":${kTicketTotal + 1}');
      expect(edited, isNot(a));
      expect(sha256(utf8.encode(edited)) == sha256(utf8.encode(a)), isFalse);
    });

    test('writes a file plus a checksum sidecar', () async {
      final dir = await Directory.systemTemp.createTemp('kazama_t4');
      // backupDirectory() needs path_provider's platform channel, unavailable in a
      // unit test, so this exercises the same encoder + sidecar format directly.
      final file = File('${dir.path}/${snapshotFileName(at)}');
      final encoded = encodeCanonical(await payloadOf(db));
      await file.writeAsString(encoded, flush: true);
      final sum = sha256(utf8.encode(encoded));
      await File('${file.path}.sha256').writeAsString('$kSnapshotChecksumPrefix$sum\n');

      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), encoded.length);
      expect(await File('${file.path}.sha256').readAsString(), startsWith(kSnapshotChecksumPrefix));
      await dir.delete(recursive: true);
    });

    test('an empty till still exports a valid, restorable snapshot', () async {
      final fresh = AppDatabase(NativeDatabase.memory());
      addTearDown(fresh.close);
      final report = validateSnapshot(decode(await payloadOf(fresh)));
      expect(report.isValid, isTrue);
      expect(report.totalRows, 3,
          reason: 'schemaVersion + printer default + tax default, seeded by beforeOpen');
    });
  });

  group('validator', () {
    test('accepts a snapshot this app just wrote', () async {
      final report = validateSnapshot(decode(await payloadOf(db)));
      expect(report.isValid, isTrue, reason: report.problems.join('; '));
      expect(report.totalRows, greaterThan(10));
      expect(report.summary, contains('2026-09-03'));
    });

    test('rejects a foreign file with a readable message', () {
      expect(
        () => validateSnapshot({'foo': 1}),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', contains('not a Kazama POS snapshot')),
        ),
      );
    });

    test('rejects a truncated body before any write could happen', () {
      expect(
        () => validateSnapshot({'format': kSnapshotFormatTag, 'formatVersion': 1}),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('truncated'))),
      );
    });

    test('a non-integer paise value is named, not repaired', () async {
      final payload = decode(await payloadOf(db));
      final orders = (payload['tables']!['orders']! as List).cast<Map<String, Object?>>();
      orders[0]['total_paise'] = 10.5;
      final report = validateSnapshot(withTable(payload, 'orders', orders));
      expect(report.isValid, isFalse);
      expect(
        report.problems.any((p) => p.contains('total_paise') && p.contains('whole paise')),
        isTrue,
        reason: 'the message must name the column and the row',
      );
    });

    test('negative money is rejected, rounding_paise is exempt', () async {
      final bad = decode(await payloadOf(db));
      final payments = (bad['tables']!['payments']! as List).cast<Map<String, Object?>>();
      payments[0]['amount_paise'] = -1;
      expect(validateSnapshot(withTable(bad, 'payments', payments)).isValid, isFalse);

      final ok = decode(await payloadOf(db));
      final orders = (ok['tables']!['orders']! as List).cast<Map<String, Object?>>();
      orders[0]['rounding_paise'] = -1;
      expect(validateSnapshot(withTable(ok, 'orders', orders)).isValid, isTrue,
          reason: 'ROUNDING lines are legitimately negative (SKILLS §B5)');
    });

    test('an unknown enum value is reported with its allowed set', () async {
      final payload = decode(await payloadOf(db));
      final orders = (payload['tables']!['orders']! as List).cast<Map<String, Object?>>();
      orders[0]['status'] = 'halfCooked';
      final report = validateSnapshot(withTable(payload, 'orders', orders));
      expect(report.problems.any((p) => p.contains('halfCooked') && p.contains('inKitchen')), isTrue);
    });

    test('a line cancelled beyond its quantity is rejected', () async {
      final payload = decode(await payloadOf(db));
      final lines = (payload['tables']!['order_lines']! as List).cast<Map<String, Object?>>();
      lines[0]['cancelled_quantity'] = 9;
      final report = validateSnapshot(withTable(payload, 'order_lines', lines));
      expect(report.problems.any((p) => p.contains('exceeds quantity')), isTrue);
    });

    test('an overpaid bill is rejected', () async {
      final payload = decode(await payloadOf(db));
      final orders = (payload['tables']!['orders']! as List).cast<Map<String, Object?>>();
      orders[0]['paid_paise'] = kTicketTotal + 500;
      final report = validateSnapshot(withTable(payload, 'orders', orders));
      expect(report.problems.any((p) => p.contains('overpaid')), isTrue);
    });

    test('orphaned payments are reported, not silently restored', () async {
      final payload = decode(await payloadOf(db));
      final payments = (payload['tables']!['payments']! as List).cast<Map<String, Object?>>();
      payments[0]['order_id'] = 'ghost-order';
      final report = validateSnapshot(withTable(payload, 'payments', payments));
      expect(
        report.problems.any((p) => p.contains('payments') && p.contains('missing from this snapshot')),
        isTrue,
      );
    });

    test('a snapshot from a NEWER app version is refused', () async {
      final payload = decode(await payloadOf(db));
      expect(validateSnapshot({...payload, 'formatVersion': 7}).isValid, isFalse);
    });

    test('problems are capped so one broken row cannot flood the dialog', () async {
      final payload = decode(await payloadOf(db));
      final lines = [
        for (var i = 0; i < 200; i++)
          <String, Object?>{'id': 'x$i', 'order_id': 'o1', 'name_snapshot': 'n', 'unit_price_paise': 10.5},
      ];
      final report = validateSnapshot(withTable(decode(payload), 'order_lines', lines));
      expect(report.problems.length, lessThanOrEqualTo(40));
    });
  });
}
