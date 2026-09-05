/// The counter shell (Task U2).
///
/// Five tabs, one IndexedStack. The stack (rather than swapping routes) is the
/// point: a cashier who jumps to the KDS to check a dish and back must find the
/// half-built ticket exactly as they left it, with the modifier sheet still
/// open. A `NavigationBar` rather than tabs because five is the most this fits
/// with 56 dp targets (R5: nothing here is decorative).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/models/order.dart';
import '../features/staff_auth/domain/pin_hasher.dart';
import '../features/billing/ui/billing_screen.dart';
import '../features/inventory/ui/stock_screen.dart';
import '../features/kitchen_display/ui/kds_screen.dart';
import '../features/order_taking/ui/order_screen.dart';
import '../features/reports/ui/settings_screen.dart';

class KazamaShell extends ConsumerWidget {
  const KazamaShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(shellTabProvider);
    final dueCount = ref.watch(openTicketsProvider).maybeWhen(
      data: (rows) => rows.where((t) => t.appearsInDueList).length,
      orElse: () => 0,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kazama POS'),
        actions: [
          const SessionChip(),
          const SizedBox(width: 8),
        ],
      ),
      body: IndexedStack(
        index: tab,
        children: const [
          OrderScreen(),
          BillingScreen(),
          KdsScreen(),
          StockScreen(),
          SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => ref.read(shellTabProvider.notifier).state = i,
        destinations: [
          const NavigationDestination(icon: Icon(Icons.restaurant_menu), label: 'Orders'),
          NavigationDestination(
            icon: Badge.count(count: dueCount, isLabelVisible: dueCount > 0, child: const Icon(Icons.payments_outlined)),
            label: 'Pay',
          ),
          const NavigationDestination(icon: Icon(Icons.receipt_long_outlined), label: 'Kitchen'),
          const NavigationDestination(icon: Icon(Icons.inventory_2_outlined), label: 'Stock'),
          const NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
        ],
      ),
    );
  }
}

/// Who is signed in, with a one-tap sign-out (S2/S3). A POS has no "account"
/// menu; the name on the bar IS the account, and tapping it is how you hand the
/// tablet to the next person.
class SessionChip extends ConsumerWidget {
  const SessionChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(currentSessionProvider);
    if (!s.isSignedIn) return const SizedBox.shrink();
    return InkWell(
      onTap: () async {
        final go = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('End ${s.name}\'s session?'),
            content: const Text(
              'The shift stays open so the next person continues on it. '
              'Close the shift from Settings > Cash up if you are finishing the day.',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Stay in')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Sign out')),
            ],
          ),
        );
        if (go == true && context.mounted) {
          ref.read(currentSessionProvider.notifier).state = PosSession.anonymous;
          ref.read(activeTicketIdProvider.notifier).state = null;
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.person_outline, size: 18),
              const SizedBox(width: 6),
              Text('${s.name} · ${s.roleName ?? ''}'),
            ],
          ),
        ),
      ),
    );
  }
}
