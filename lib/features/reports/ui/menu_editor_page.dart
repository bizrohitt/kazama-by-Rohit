/// Menu editor (Task M1, M3, M4, M6).
///
/// Three actions, and each one has a reason to exist here rather than in a
/// generic form:
///  * **price / tax / label edit** — writes through `MenuRepository.saveItem`,
///    which is the only path that keeps the availability flag intact (a naive
///    upsert on every menu edit would put a sold-out dish back on sale);
///  * **sold out** — flips `available` alone. This is the hook the stock module
///    also drives (I3): a human marking "out of momos" and the app marking it
///    must be the same column, not two;
///  * **deactivate** — soft delete only (M1). An item a bill references must
///    stay resolvable forever, or a reprint shows "(unknown item)" to a customer.
library;

///
/// It lives under `features/reports/ui` rather than `features/menu/ui` on purpose:
/// this is a *settings* page, reached only from the settings hub, and R1 forbids
/// one feature importing another. `lib/app/shell.dart` is the only place allowed
/// to compose screens from different features, and it does not need this one.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/money/money.dart';
import '../../../core/providers.dart';
import '../../../data/models/menu.dart';

/// Every item including the delisted ones — the editor's list is deliberately
/// NOT the same provider the till uses (M3 filters those out).
final StreamProvider<List<MenuItem>> editorItemsProvider =
    StreamProvider<List<MenuItem>>((ref) => ref.watch(menuRepositoryProvider).watchMenu(includeInactive: true));

class MenuEditorPage extends ConsumerWidget {
  const MenuEditorPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cats = ref.watch(menuCategoriesProvider).maybeWhen(data: (d) => d, orElse: () => const <MenuCategory>[]);
    final items = ref.watch(editorItemsProvider).maybeWhen(data: (d) => d, orElse: () => const <MenuItem>[]);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Menu'),
        actions: [
          IconButton(
            tooltip: 'New item',
            onPressed: () => _edit(context, ref, null, cats.isEmpty ? 'cat_burger' : cats.first.id, cats),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: cats.isEmpty
          ? const Center(child: Text('No categories. The demo menu is seeded on first run — check that the app booted with data.'))
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                for (final c in cats) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 12, bottom: 4, left: 4),
                    child: Text(c.name, style: Theme.of(context).textTheme.titleMedium),
                  ),
                  ...[
                    for (final it in items.where((i) => i.categoryId == c.id))
                      _ItemRow(item: it, categories: cats, onEdit: () => _edit(context, ref, it, c.id, cats)),
                  ],
                ],
              ],
            ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, MenuItem? existing, String categoryId, List<MenuCategory> cats) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ItemForm(existing: existing, categoryId: categoryId, categories: cats),
    );
    if (saved == true && context.mounted) showSnack(context, 'Menu saved');
  }
}

class _ItemRow extends ConsumerWidget {
  const _ItemRow({required this.item, required this.categories, required this.onEdit});

  final MenuItem item;
  final List<MenuCategory> categories;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        title: Text(item.name),
        subtitle: Text(
          '${rupeesText(item.price)}  ·  ${item.taxPercent}% GST  ·  '
          '${item.available ? (item.active ? 'on sale' : 'delisted') : 'SOLD OUT'}'
          '${item.prepSeconds == 0 ? '' : '  ·  ${(item.prepSeconds / 60).ceil()} min'}',
          style: theme.textTheme.bodySmall?.copyWith(
            // A delisted item is grey TEXT, not only a missing switch: on a
            // sunlit screen a grey row and a black row are the same row (U3).
            color: item.active ? null : theme.colorScheme.outline,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: item.available,
              onChanged: (v) => ref.read(menuRepositoryProvider).soldOut(item.id, available: v),
            ),
            IconButton(onPressed: onEdit, icon: const Icon(Icons.edit_outlined, size: 20)),
          ],
        ),
      ),
    );
  }
}

class _ItemForm extends ConsumerStatefulWidget {
  const _ItemForm({required this.existing, required this.categoryId, required this.categories});

  final MenuItem? existing;
  final String categoryId;
  final List<MenuCategory> categories;

  @override
  ConsumerState<_ItemForm> createState() => _ItemFormState();
}

class _ItemFormState extends ConsumerState<_ItemForm> {
  late final TextEditingController _name = TextEditingController(text: widget.existing?.name ?? '');
  late final TextEditingController _price = TextEditingController(
    text: widget.existing == null ? '' : (widget.existing!.price.paise / 100).toStringAsFixed(2),
  );
  late final TextEditingController _tax = TextEditingController(text: '${widget.existing?.taxPercent ?? 5}');
  late final TextEditingController _label = TextEditingController(text: widget.existing?.kitchenLabel ?? '');
  late final TextEditingController _prep = TextEditingController(text: '${widget.existing?.prepSeconds ?? 180}');
  late final TextEditingController _barcode = TextEditingController(text: widget.existing?.barcode ?? '');
  late String _categoryId = widget.existing?.categoryId ?? widget.categoryId;
  late bool _printable = widget.existing?.printable ?? true;
  String? _error;

  Money? get _parsedPrice {
    final v = double.tryParse(_price.text.trim());
    if (v == null || v < 0) return null;
    return Money.rupees(v);
  }

  @override
  void dispose() {
    for (final c in [_name, _price, _tax, _label, _prep, _barcode]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final price = _parsedPrice;
    if (price == null) {
      setState(() => _error = 'Price must be a number like 60 or 60.50');
      return;
    }
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'An item needs a name');
      return;
    }
    final tax = int.tryParse(_tax.text.trim()) ?? 5;
    if (tax < 0 || tax > 40) {
      setState(() => _error = 'GST rate must be 0-40 (5, 12, 18, 28 are the real ones)');
      return;
    }
    final base = widget.existing;
    final item = MenuItem(
      id: base?.id ?? 'itm_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
      categoryId: _categoryId,
      name: _name.text.trim(),
      price: price,
      taxPercent: tax,
      kitchenLabel: _label.text.trim().isEmpty ? _name.text.trim().toUpperCase() : _label.text.trim().toUpperCase(),
      prepSeconds: (int.tryParse(_prep.text.trim()) ?? 180).clamp(0, 3600),
      printable: _printable,
      barcode: _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
      stockItemId: base?.stockItemId,
      modifierGroupIds: base?.modifierGroupIds ?? const <String>[],
      active: base?.active ?? true,
      available: base?.available ?? true,
      sortOrder: base?.sortOrder ?? 99,
    );
    try {
      await ref.read(menuRepositoryProvider).saveItem(item);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _deactivate() async {
    final base = widget.existing;
    if (base == null) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Remove ${base.name} from the menu?'),
        content: const Text(
          'It stops appearing at the till, but every past bill still shows it. '
          'To sell it again, switch it back on from the list.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep it')),
          FilledButton(
            onPressed: () async {
              await ref.read(menuRepositoryProvider).deactivateItem(base.id);
              if (c.mounted) Navigator.pop(c, true);
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (sure == true && mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.existing == null ? 'New item' : widget.existing!.name, style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name at the counter'), textCapitalization: TextCapitalization.words),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: TextField(controller: _price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Price ₹ (GST inclusive)'))),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 110,
                    child: TextField(controller: _tax, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'GST %')),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: TextField(controller: _label, decoration: const InputDecoration(labelText: 'Kitchen label', helperText: 'UPPERCASE, printed on the KDS'))),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 110,
                    child: TextField(controller: _prep, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Prep sec')),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(controller: _barcode, decoration: const InputDecoration(labelText: 'Barcode (optional, not scanned in v1)')),
              const SizedBox(height: 10),
              // `value:` rather than `initialValue:` — the latter only exists on
              // recent Flutter SDKs and a settings form must not be what breaks an
              // upgrade.
              DropdownButtonFormField<String>(
                value: _categoryId,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [for (final c in widget.categories) DropdownMenuItem(value: c.id, child: Text(c.name))],
                onChanged: (v) => setState(() => _categoryId = v ?? _categoryId),
              ),
              SwitchListTile(
                value: _printable,
                title: const Text('Print on the kitchen slip'),
                subtitle: const Text('Off for drinks/water, so the cooks are not paged for a bottle'),
                onChanged: (v) => setState(() => _printable = v),
              ),
              if (_error != null) Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  if (widget.existing != null)
                    OutlinedButton(onPressed: _deactivate, child: const Text('Remove…')),
                  const Spacer(),
                  TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                  const SizedBox(width: 6),
                  FilledButton(onPressed: _save, child: const Text('Save')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
