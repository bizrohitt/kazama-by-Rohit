/// Settings hub (Task U2 + the P4/S/R entry points).
///
/// Settings is a LIST of pages, not tabs: a counter tablet is operated one-handed
/// while a queue watches, and a page you can back out of is faster than a tab you
/// have to find again. Every page here mutates something durable (prices, PINs,
/// the whole database), which is also why none of them are reachable without a
/// signed-in user — `canEditMenu`/`canVoid` gate the actions inside each page.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../data/models/enums.dart';
import 'backup_page.dart';
import 'reports_screen.dart';
import 'menu_editor_page.dart';
import 'shop_page.dart';
import 'staff_shift_page.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentSessionProvider);
    // Compared by `UserRole`, never by the display string: `roleName` is what the
    // sign-in screen writes and a translated label would silently open every
    // manager-only page to a cashier.
    final isManager = ref.watch(currentRoleProvider) == UserRole.manager;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Settings', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        _Tile(
          icon: Icons.storefront_outlined,
          title: 'Shop & printer',
          subtitle: 'Name on the receipt, GSTIN, paper width',
          onTap: () => _push(context, const ShopPage()),
        ),
        _Tile(
          icon: Icons.restaurant_menu,
          title: 'Menu',
          subtitle: 'Prices, tax rate, sold-out, kitchen labels',
          onTap: () => _push(context, const MenuEditorPage()),
          disabled: !isManager,
        ),
        _Tile(
          icon: Icons.groups_outlined,
          title: 'Staff & shifts',
          subtitle: 'Add a cashier, close a shift, cash up',
          onTap: () => _push(context, const StaffShiftPage()),
          disabled: !isManager,
        ),
        _Tile(
          icon: Icons.query_stats_outlined,
          title: 'Daily report',
          subtitle: 'Totals, modes, top items, shifts — by day',
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReportsScreen())),
          disabled: !isManager,
        ),
        _Tile(
          icon: Icons.settings_backup_restore,
          title: 'Backup & restore',
          subtitle: 'A JSON snapshot of every table, with a checksum',
          onTap: () => _push(context, const BackupPage()),
          disabled: !isManager,
        ),
        const SizedBox(height: 12),
        // A manager-only list, with the reason ON SCREEN: the day a cashier
        // cannot change a price is the day someone calls, and "the app is
        // broken" is a much worse report than "you are signed in as a cashier".
        Text(
          isManager
              ? 'Signed in as ${me.name} (manager) - everything above is editable.'
              : 'Signed in as ${me.name} (${me.roleName}). Menu, staff and backup '
                  'need a manager PIN: sign out and in as one to change them.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  static void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.disabled = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: disabled ? const Icon(Icons.lock_outline, size: 20) : const Icon(Icons.chevron_right),
        onTap: disabled ? null : onTap,
      ),
    );
  }
}
