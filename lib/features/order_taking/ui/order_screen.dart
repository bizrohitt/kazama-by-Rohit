/// Order-taking screen (Task O2, O3, O5, O6) — the "people order first" half
/// of the counter (Q4).
///
/// It writes LINES and nothing else: no payments, no bill number, no discount.
/// That is not tidiness for its own sake — the Q4 requirement is that a cashier
/// can seat a family, fire their starters, and walk away, while the money half
/// waits at the till. Two files that both write money is how a till ends up with
/// a paid bill whose lines changed afterwards.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/providers.dart';
import '../../../data/models/enums.dart';
import '../../../data/models/menu.dart';
import '../../../data/models/order.dart';
import '../../../data/repositories/impl/order_repository_impl.dart';
import 'modifier_sheet.dart';
import 'ticket_lines_tile.dart';

/// Categories with their items resolved — one provider so the grid and the
/// search box cannot disagree about what is on sale (M3/O3).
final StreamProvider<List<MenuCategory>> menuCategoriesProvider =
    StreamProvider<List<MenuCategory>>((ref) => ref.watch(menuRepositoryProvider).watchCategories());

final StreamProvider<List<MenuItem>> menuItemsProvider =
    StreamProvider<List<MenuItem>>(
  (ref) => ref.watch(menuRepositoryProvider).watchMenu(),
);

class OrderScreen extends ConsumerStatefulWidget {
  const OrderScreen({super.key});

  @override
  ConsumerState<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends ConsumerState<OrderScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Same rule as the billing screen: a refresh must not blank the half-built
    // ticket out from under the cashier's finger.
    final asyncTicket = ref.watch(activeTicketProvider);
    final ticket = asyncTicket.hasValue ? asyncTicket.value : asyncTicket.previousValue;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Left: what is open / what is being held (O4).
        SizedBox(
          width: 250,
          child: _HeldTicketsPanel(onStartNew: _startNew, onOpen: (id) => ref.read(activeTicketIdProvider.notifier).state = id),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            children: [
              _SearchBar(controller: _search, query: _query, onChanged: (v) => setState(() => _query = v.trim().toLowerCase())),
              Expanded(
                child: ticket == null
                    ? _EmptyTicketHint(onStartNew: _startNew)
                    : _ActiveTicketArea(ticket: ticket),
              ),
              if (ticket != null)
                _MenuGrid(query: _query, onPicked: (item) => _add(item, ticket)),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _startNew() async {
    final type = await showDialog<OrderType>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('New bill'),
        content: const Text('Takeaway pays at the counter; dine-in comes to the till after eating (Q4).'),
        actions: [
          for (final t in OrderType.values)
            FilledButton.tonal(onPressed: () => Navigator.pop(c, t), child: Text(t.label)),
        ],
      ),
    );
    if (type == null || !mounted) return;
    final table = await _askTable(type);
    if (!mounted) return;
    final repo = ref.read(orderRepositoryProvider);
    final ticket = await repo.startTicket(
      type: type,
      openedBy: ref.read(currentSessionProvider).userId ?? 'system',
      tableOrName: table,
    );
    ref.read(activeTicketIdProvider.notifier).state = ticket.id;
  }

  /// Dine-in needs a table to find the bill by later; takeaway does not, and
  /// forcing a name there slows the queue for nothing.
  Future<String?> _askTable(OrderType type) async {
    if (type == OrderType.takeaway) return null;
    final controller = TextEditingController();
    final label = type == OrderType.dineIn ? 'Table number' : 'Customer name / phone';
    return showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: label, helperText: 'Leave empty to skip'),
          onSubmitted: (v) => Navigator.pop(c, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Skip')),
          FilledButton(onPressed: () => Navigator.pop(c, controller.text.trim()), child: const Text('Start')),
        ],
      ),
    );
  }

  /// Tap = add one. A long press opens the same sheet with quantity 1 so a
  /// "12 plates for a function" order is a sheet, not twelve taps (O3).
  Future<void> _add(MenuItem item, OrderTicket ticket) async {
    final groups = await ref.read(menuRepositoryProvider).loadGroupsFor(item.modifierGroupIds.toSet());
    if (!mounted) return;
    if (groups.isEmpty) {
      await _commit(item, const <ModifierOption>{}, 1, ticket);
      return;
    }
    final chosen = await showModalBottomSheet<ModifierChoice>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ModifierSheet(item: item, groups: groups),
    );
    if (chosen == null || !mounted) return;
    await _commit(item, chosen.options, chosen.quantity, ticket);
  }

  Future<void> _commit(MenuItem item, Set<ModifierOption> options, int qty, OrderTicket ticket) async {
    try {
      await ref.read(orderRepositoryProvider).addMenuItem(
        ticketId: ticket.id,
        item: item,
        quantity: qty,
        modifiers: options.toList()..sort((a, b) => a.groupId.compareTo(b.groupId)),
      );
      if (!mounted) return;
      showSnack(context, '$qty × ${item.name} added');
    } catch (e) {
      if (!mounted) return;
      // A settled ticket is the one real failure here (the family paid while you
      // were adding), and it must be loud: the line would otherwise vanish.
      showSnack(context, 'Could not add: $e', error: true);
    }
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.query, required this.onChanged});

  final TextEditingController controller;
  final String query;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: 'Search dishes',
          prefixIcon: const Icon(Icons.search),
          isDense: true,
          suffixIcon: query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
        ),
      ),
    );
  }
}

class _EmptyTicketHint extends StatelessWidget {
  const _EmptyTicketHint({required this.onStartNew});

  final VoidCallback onStartNew;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('No bill open', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          const Text('A held bill reopens from the list on the left.'),
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: onStartNew, icon: const Icon(Icons.add), label: const Text('Start a new bill')),
        ],
      ),
    );
  }
}

class _ActiveTicketArea extends ConsumerWidget {
  const _ActiveTicketArea({required this.ticket});

  final OrderTicket ticket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canAdd = ticket.status.allowsAddingItems;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${ticket.type.label}'
                  '${ticket.tableOrName == null ? '' : '  ·  ${ticket.tableOrName}'}'
                  '  ·  ${ticket.status.label}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: canAdd ? 'Add a line note in the list below' : 'This bill is settled',
                onPressed: null,
                icon: const Icon(Icons.info_outline),
              ),
            ],
          ),
        ),
        Expanded(
          child: ticket.lines.isEmpty
              ? Center(child: Text(canAdd ? 'Tap a dish to add it.' : 'Nothing left on this bill.'))
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final l in ticket.lines)
                      TicketLineTile(
                        ticketId: ticket.id,
                        line: l,
                        locked: !canAdd,
                      ),
                  ],
                ),
        ),
        TicketFooter(ticket: ticket),
        if (!canAdd)
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Text('This bill is settled - start a new one to keep ordering.', textAlign: TextAlign.center),
            ),
          ),
      ],
    );
  }
}

/// The held-tickets rail (O4). Newest touched first — the DB already orders
/// that way, because a list sorted by `openedAt` puts the 11am family above the
/// table that needs paying now.
class _HeldTicketsPanel extends ConsumerWidget {
  const _HeldTicketsPanel({required this.onStartNew, required this.onOpen});

  final VoidCallback onStartNew;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tickets = ref.watch(openTicketsProvider);
    final activeId = ref.watch(activeTicketIdProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onStartNew,
              icon: const Icon(Icons.add),
              label: const Text('New bill'),
            ),
          ),
        ),
        Expanded(
          child: tickets.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Padding(padding: const EdgeInsets.all(12), child: Text('$e')),
            data: (rows) => rows.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Nothing held. Every bill is settled.', textAlign: TextAlign.center),
                  )
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (_, i) {
                      final t = rows[i];
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        color: t.id == activeId ? Theme.of(context).colorScheme.secondaryContainer : null,
                        child: ListTile(
                          dense: true,
                          title: Text(t.tableOrName ?? (t.billNumber == null ? 'No. ${t.id}' : 'Bill ${t.billNumber}')),
                          subtitle: Text(
                            '${t.type.label}  ·  ${t.lineCount} line(s)  ·  ${t.status.label}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          trailing: Text(
                            t.due.isPositive ? rupeesText(t.due) : rupeesText(t.total),
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          onTap: () => onOpen(t.id),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

/// Category strip + item grid (O3). Sold-out items stay visible and DISABLED
/// rather than disappearing: "we are out of momos" is information the counter has
/// to be able to say, and a vanished button invites "your app is broken" (M6).
class _MenuGrid extends ConsumerWidget {
  const _MenuGrid({required this.query, required this.onPicked});

  final String query;
  final ValueChanged<MenuItem> onPicked;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cats = ref.watch(menuCategoriesProvider).maybeWhen(data: (d) => d, orElse: () => const <MenuCategory>[]);
    final items = ref.watch(menuItemsProvider).maybeWhen(data: (d) => d, orElse: () => const <MenuItem>[]);
    final selected = ref.watch(selectedCategoryIdProvider);
    final visible = [
      for (final it in items)
        if (selected == null || it.categoryId == selected)
          if (query.isEmpty || it.name.toLowerCase().contains(query) || (it.kitchenLabel?.toLowerCase().contains(query) ?? false))
            it,
    ];
    return Column(
      children: [
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              _CatChip(label: 'All', selected: selected == null, onTap: () => ref.read(selectedCategoryIdProvider.notifier).state = null),
              for (final c in cats)
                _CatChip(
                  label: c.name,
                  selected: selected == c.id,
                  onTap: () => ref.read(selectedCategoryIdProvider.notifier).state = c.id,
                ),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('Nothing here yet - check the category, or add items in Settings > Menu.'))
              : GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 190,
                    mainAxisExtent: 92,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (_, i) => _ItemButton(item: visible[i], onPicked: onPicked),
                ),
        ),
      ],
    );
  }
}

class _CatChip extends StatelessWidget {
  const _CatChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(label: Text(label), selected: selected, onSelected: (_) => onTap()),
    );
  }
}

class _ItemButton extends StatelessWidget {
  const _ItemButton({required this.item, required this.onPicked});

  final MenuItem item;
  final ValueChanged<MenuItem> onPicked;

  @override
  Widget build(BuildContext context) {
    final sellable = item.available && item.active;
    return OutlinedButton(
      onPressed: sellable ? () => onPicked(item) : null,
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodyLarge),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(rupeesText(item.price), style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              if (!sellable)
                Text('OUT', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700))
              else if (item.prepSeconds >= 300)
                Text('${(item.prepSeconds / 60).ceil()} min', style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ],
      ),
    );
  }
}
