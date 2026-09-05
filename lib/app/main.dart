/// Entry point (Task U1/U2).
///
/// Boot order matters and is the whole content of this file:
///   1. open the DB (a file path, so after `path_provider` is usable),
///   2. seed the demo menu + opening stock once,
///   3. THEN `runApp` — so no screen ever renders against an empty menu and
///      shows a spinner that resolves to "nothing to sell".
/// Calling `runApp` before step 2 is the classic first-launch blank-counter bug.
///
/// There is deliberately no nested `ProviderScope` here and no provider-based
/// boot: one scope, one override list, built synchronously. Every "elegant"
/// async-boot variant I have seen in a POS makes a boot failure impossible to
/// read on a phone screen at 9pm.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db/app_database.dart';
import '../core/providers.dart';
import 'kazama_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppDatabase? db;
  Object? bootError;
  try {
    db = await bootstrapDatabase();
  } catch (e) {
    bootError = e;
  }
  runApp(
    ProviderScope(
      overrides: [
        // Unsettled when boot failed: `KazamaApp` then shows the failure instead
        // of a database, and the message survives (no rethrow, no empty table).
        if (db != null) appDatabaseProvider.overrideWithValue(db),
      ],
      child: KazamaBootstrap(db: db, bootError: bootError),
    ),
  );
}
