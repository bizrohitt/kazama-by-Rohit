/// Item options sheet (Task O3) — modifiers, then quantity, then add.
///
/// The sheet reads the groups from the menu repository and returns a
/// `ModifierChoice`; it does not write anything. That split matters: the same
/// sheet is used by a future "re-add to a new bill" flow, and a widget that
/// writes tickets directly is a widget that cannot be reused or tested without a
/// database.
///
/// `minSelect`/`maxSelect`/`required` are enforced HERE only as a UX guard; the
/// repository accepts whatever the model allows, so a cheaper UI (or the KDS
/// re-firing a dish) is never blocked by a rule that only exists in a widget.
library;

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../core/money/money.dart';
import '../../../data/models/menu.dart';
import '../../../data/models/order_line.dart';

class ModifierChoice {
  const ModifierChoice({required this.options, required this.quantity});

  final Set<ModifierOption> options;
  final int quantity;
}

class ModifierSheet extends StatefulWidget {
  const ModifierSheet({
    super.key,
    required this.item,
    required this.groups,
    this.initialQuantity = 1,
  });

  final MenuItem item;
  final List<ModifierGroup> groups;
  final int initialQuantity;

  @override
  State<ModifierSheet> createState() => _ModifierSheetState();
}

class _ModifierSheetState extends State<ModifierSheet> {
  final Set<String> _selected = <String>{};
  late int _qty = widget.initialQuantity;

  /// Options by id, for the price line and for the returned set.
  Map<String, ModifierOption> get _byId => {
    for (final g in widget.groups)
      for (final o in g.options.where((o) => o.active)) o.id: o,
  };

  /// `item.price` is the INCLUSIVE printed price (tax-inclusive is the shop's
  /// model, §B2), and a modifier's delta is added to that printed price. The
  /// sheet shows the same number the line will store as `unitPrice`, so what a
  /// customer is told and what the till charges cannot drift.
  Money get _unit => widget.item.price + Money.sum(_selected.map((id) => _byId[id]!.priceDelta));

  /// Integer paise, deliberately not `scale()` (which exists for the tax-aware
  /// line maths): a preview of a total has no business re-deriving tax.
  Money get _lineTotal => Money(_unit.paise * _qty);

  /// The rule the OK button enforces: every required group must have at least
  /// `minSelect`, and no group may exceed `maxSelect` (0 = unlimited).
  String? get _problem {
    final byId = _byId;
    for (final g in widget.groups) {
      final n = _selected.where((id) => byId[id]?.groupId == g.id).length;
      if (g.required && n < (g.minSelect == 0 ? 1 : g.minSelect)) {
        return 'Choose ${g.minSelect == 0 ? 1 : g.minSelect} for ${g.name}';
      }
      if (g.maxSelect > 0 && n > g.maxSelect) return 'At most ${g.maxSelect} for ${g.name}';
    }
    if (_qty < 1) return 'Quantity must be at least 1';
    return null;
  }

  void _toggle(ModifierGroup g, ModifierOption o) {
    setState(() {
      if (_selected.contains(o.id)) {
        _selected.remove(o.id);
        return;
      }
      if (g.maxSelect == 1) {
        _selected.removeWhere((id) => o.groupId == g.id);
        _selected.add(o.id);
      } else {
        final inGroup = _selected.where((id) => o.groupId == g.id).toList();
        // `maxSelect == 0` means unlimited. Otherwise the OLDEST pick in the
        // group is dropped rather than the tap being refused silently: a no-op
        // on a touchscreen reads as a broken button, and a cashier mid-queue
        // has no time to work out why nothing happened.
        if (g.maxSelect > 0 && inGroup.length >= g.maxSelect) _selected.remove(inGroup.first);
        _selected.add(o.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problem = _problem;
    return Padding(
      // Keyboard-safe: the sheet is opened over the menu grid, and on a tablet
      // with the soft keyboard up an unfitted bottom sheet hides its own OK.
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(child: Text(widget.item.name, style: theme.textTheme.titleLarge)),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final g in widget.groups) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${g.name}${g.required ? '  (required)' : ''}'
                      '${g.maxSelect > 1 ? '  (pick up to ${g.maxSelect})' : ''}',
                      style: theme.textTheme.titleSmall,
                    ),
                    for (final o in g.options.where((o) => o.active))
                      CheckboxListTile(
                        value: _selected.contains(o.id),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(o.priceDelta.isPositive ? '${o.name}  +${rupeesText(o.priceDelta)}' : o.name),
                        onChanged: (_) => _toggle(g, o),
                      ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text('Quantity', style: theme.textTheme.titleSmall),
                      const Spacer(),
                      IconButton(
                        onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                      Text('$_qty', style: theme.textTheme.titleLarge),
                      IconButton(onPressed: () => setState(() => _qty++), icon: const Icon(Icons.add_circle_outline)),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      problem ?? '${rupeesText(_unit)} each   ·   ${rupeesText(_lineTotal)}',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  FilledButton(
                    onPressed: problem == null
                        ? () => Navigator.pop(
                              context,
                              ModifierChoice(options: _selected.map((id) => _byId[id]!).toSet(), quantity: _qty),
                            )
                        : null,
                    child: Text('Add $_qty'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
