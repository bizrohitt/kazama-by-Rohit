/// App root + boot gate (Task U2).
///
/// Three states, and the order of the checks is the point:
///   1. boot failed  -> the error (a shop must never see a blank screen),
///   2. no staff yet -> first-run manager setup (S1), because a POS without a
///      user has nothing to sign in to,
///   3. otherwise    -> sign in (S2), then the counter.
/// The staff check happens here rather than inside `SigninScreen` so that the
/// sign-in screen cannot be reached with zero users — the bug where a fresh
/// install shows an empty user list and no way forward.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/db/app_database.dart';
import '../core/providers.dart';

import '../features/staff_auth/ui/signin_screen.dart';
import 'shell.dart';
import 'theme.dart';

class KazamaBootstrap extends StatelessWidget {
  const KazamaBootstrap({super.key, this.db, this.bootError});

  final AppDatabase? db;
  final Object? bootError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kazama POS',
      debugShowCheckedModeBanner: false,
      theme: KazamaTheme.light(),
      home: bootError != null
          ? _BootFailed(error: bootError!)
          : const KazamaGate(),
    );
  }
}

class _BootFailed extends StatelessWidget {
  const _BootFailed({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 44),
              const SizedBox(height: 14),
              Text(
                'Kazama could not open its database.',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              // The raw error, not a friendly string: whoever fixes this is
              // standing at a counter with a queue, and one clear sentence beats
              // a support call describing a smiley.
              Text('$error', textAlign: TextAlign.center),
              const SizedBox(height: 18),
              const BootRetryHint(),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Try again", honestly implemented: the provider scope was built once, before
/// `runApp`, so a widget CANNOT hand the app a working database by opening one —
/// it would be a second connection outside the overrides, with a second
/// `seedIfEmpty`, while every screen kept reading the missing one. The only real
/// retry is a fresh process, so this closes the app. On a counter tablet that is
/// a one-second cold start, and it is the difference between "try again" and a
/// second handle on the same SQLite file.
class BootRetryHint extends StatelessWidget {
  const BootRetryHint({super.key});

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: () => SystemNavigator.pop(),
      child: const Text('Close and start again'),
    );
  }
}

/// Chooses between first-run, sign-in and the counter. Reads `hasAnyUser()`
/// once and re-checks after a bootstrap so the flow advances without a restart.
class KazamaGate extends ConsumerStatefulWidget {
  const KazamaGate({super.key});

  @override
  ConsumerState<KazamaGate> createState() => _KazamaGateState();
}

class _KazamaGateState extends ConsumerState<KazamaGate> with WidgetsBindingObserver {
  late final Future<bool> _hasUser;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hasUser = ref.read(staffRepositoryProvider).hasAnyUser();
    // The outbox is drained on the way IN and when the app comes back to the
    // foreground (T5). It is *never* awaited by the boot path: a sync attempt that
    // hangs must not be able to hold a counter open.
    final engine = ref.read(syncEngineProvider);
    engine.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ref.read(syncEngineProvider).stop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // `resumed` only. A background flush would be the app's most common network
    // access and Android may kill it mid-request anyway, which turns a clean
    // retry into an ambiguous one.
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(syncEngineProvider).flush());
    }
  }

  Future<void> _recheck() async {
    final repo = ref.read(staffRepositoryProvider);
    final any = await repo.hasAnyUser();
    if (!mounted) return;
    setState(() => _hasUser = Future.value(any));
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _hasUser,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (snap.data == false) {
          return FirstRunScreen(onDone: _recheck);
        }
        final session = ref.watch(currentSessionProvider);
        if (!session.isSignedIn) {
          return const SignInScreen();
        }
        return const KazamaShell();
      },
    );
  }
}
