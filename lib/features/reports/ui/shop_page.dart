/// Shop + printer settings (Task P4's settings half, U2).
///
/// These are `app_meta` strings, not a table: a shop's address changes twice a
/// decade and a 4-row table would need a migration, a repository and a backup
/// entry for what is one form. The cost is that every read is a `SELECT` — which
/// for a receipt header printed a few times an hour is the right trade.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_database.dart';
import '../../../core/providers.dart';
import '../../../data/models/payment.dart';
import '../../../features/printing/domain/receipt_model.dart';
import '../../../features/printing/queue/printing_service.dart';

class ShopPage extends ConsumerStatefulWidget {
  const ShopPage({super.key});

  @override
  ConsumerState<ShopPage> createState() => _ShopPageState();
}

class _ShopPageState extends ConsumerState<ShopPage> {
  final _name = TextEditingController();
  final _address = TextEditingController();
  final _gstin = TextEditingController();
  final _phone = TextEditingController();
  int _columns = 32;
  String? _message;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    final profile = await ref.read(printingProvider).shopProfile();
    final cols = int.tryParse(await db.metaValue(MetaKeys.printerPaperColumns) ?? '') ?? 32;
    if (!mounted) return;
    _name.text = profile.name == ShopProfile.fallback.name ? '' : profile.name;
    _address.text = profile.address ?? '';
    _gstin.text = profile.gstin ?? '';
    _phone.text = profile.phone ?? '';
    setState(() {
      _columns = cols;
      _loaded = true;
    });
  }

  Future<void> _save() async {
    // Validate EVERYTHING before writing anything: the first version of this
    // handler saved the paper width and then bailed on an empty name, which is a
    // half-saved settings screen — the printer now lays out at the new width
    // while the header is still the old one, and nobody can tell from the screen.
    if (_name.text.trim().isEmpty) {
      setState(() => _message = 'A receipt with no shop name is a receipt nobody can identify.');
      return;
    }
    final db = ref.read(appDatabaseProvider);
    await db.setMetaValue(MetaKeys.printerPaperColumns, '$_columns');
    await ref.read(printingProvider).saveShopProfile(
      ShopProfile(
        name: _name.text.trim(),
        address: _address.text.trim().isEmpty ? null : _address.text.trim(),
        gstin: _gstin.text.trim().isEmpty ? null : _gstin.text.trim(),
        phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      ),
    );
    if (!mounted) return;
    setState(() => _message = 'Saved. The next receipt uses it.');
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Shop & printer')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Shop name (printed at the top)')),
          const SizedBox(height: 12),
          TextField(
            controller: _address,
            decoration: const InputDecoration(labelText: 'Address', helperText: 'Printed under the name; leave empty to omit'),
            maxLines: 2,
          ),
          const SizedBox(height: 12),
          TextField(controller: _gstin, decoration: const InputDecoration(labelText: 'GSTIN (optional)')),
          const SizedBox(height: 12),
          TextField(controller: _phone, decoration: const InputDecoration(labelText: 'Phone (optional)')),
          const SizedBox(height: 20),
          Text('Receipt paper width', style: theme.textTheme.titleMedium),
          // Column COUNT, not millimetres: the renderer lays out in cells, and the
          // 58 mm / 32 col mapping is only true for font A on most clones. Asking
          // for mm here would be a lie the renderer has to translate anyway.
          // ChoiceChips, not RadioListTile: `groupValue`/`onChanged` were
          // deprecated in a recent Flutter and a settings screen must not be the
          // thing that fails an SDK upgrade. Same keyboard access, same result.
          Wrap(
            spacing: 8,
            children: [
              for (final (label, cols) in const [
                ('32 · 58 mm roll', 32),
                ('42 · 76 mm roll', 42),
                ('80 · 80 mm roll', 80),
              ])
                ChoiceChip(
                  label: Text(label),
                  selected: _columns == cols,
                  onSelected: (_) => setState(() => _columns = cols),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // A live preview at the chosen width. This is the cheapest possible
          // proof for a shop owner, and the alternative (print a test, read the
          // paper, notice the total is cut) wastes a receipt roll and a customer.
          ReceiptPreview(columns: _columns),
          const SizedBox(height: 16),
          if (_message != null) Text(_message!, style: TextStyle(color: theme.colorScheme.primary)),
          const SizedBox(height: 12),
          FilledButton(onPressed: _save, child: const Text('Save')),
          const SizedBox(height: 20),
          const _SyncCard(),
          const SizedBox(height: 12),
          Text(
            'Bluetooth printing lands in P4: until then every job goes to the '
            'in-memory transport, and undelivered slips are listed on this screen '
            'so nothing is silently lost.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// Outbox status (T5) next to the printer settings, because a shop owner looks
/// at this screen once a day and nowhere else. v1 has no server, so the normal
/// state is "0 rows waiting" — which is exactly the proof that the journal is not
/// leaking rows when nobody is listening.
class _SyncCard extends ConsumerStatefulWidget {
  const _SyncCard();

  @override
  ConsumerState<_SyncCard> createState() => _SyncCardState();
}

class _SyncCardState extends ConsumerState<_SyncCard> {
  int? _pending;
  int? _stuck;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(appDatabaseProvider);
    final pending = await db.countPending();
    final rows = await db.stuck();
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _stuck = rows.length;
    });
  }

  Future<void> _sync() async {
    setState(() => _busy = true);
    try {
      await ref.read(syncEngineProvider).flush();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final engine = ref.read(syncEngineProvider);
    final cycle = engine.lastCycle;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Sync', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Server: ${engine.gateway.label}', style: theme.textTheme.bodySmall),
            Text('Device id: ${engine.deviceId}  ·  bills are numbered per device', style: theme.textTheme.bodySmall),
            const SizedBox(height: 6),
            Text(
              _pending == null
                  ? '…'
                  : _pending == 0
                      ? 'Nothing waiting to go out.'
                      : '$_pending row(s) waiting${_stuck == 0 ? '' : ' · $_stuck stuck'}',
              style: theme.textTheme.bodyMedium,
            ),
            if (cycle != null && cycle.error != null)
              Text('Last error: ${cycle.error}', style: TextStyle(color: theme.colorScheme.error)),
            if (cycle != null && cycle.sent > 0) Text('Last run sent ${cycle.sent} row(s).', style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.tonal(onPressed: _busy ? null : _sync, child: const Text('Sync now')),
                const SizedBox(width: 10),
                if ((_stuck ?? 0) > 0)
                  TextButton(onPressed: _busy ? null : () async {
                    await engine.retryStuck();
                    if (mounted) await _load();
                  }, child: const Text('Retry stuck rows')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The last bill, rendered at the chosen width, as text. Read-only, no printer.
class ReceiptPreview extends ConsumerWidget {
  const ReceiptPreview({super.key, required this.columns});

  final int columns;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ticket = ref.watch(activeTicketProvider) ??
        ref.watch(openTicketsProvider).maybeWhen(data: (d) => d.isEmpty ? null : d.first, orElse: () => null);
    final theme = Theme.of(context);
    if (ticket == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Text('Open a bill to see how it will print.', style: theme.textTheme.bodySmall),
        ),
      );
    }
    return FutureBuilder<String>(
      future: _text(context, ref, ticket.id),
      builder: (context, snap) => Card(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              snap.data ?? '…',
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.25),
            ),
          ),
        ),
      ),
    );
  }

  Future<String> _text(BuildContext context, WidgetRef ref, String ticketId) async {
    final repo = ref.read(paymentRepositoryProvider);
    final t = await ref.read(orderRepositoryProvider).loadForReceipt(ticketId);
    if (t == null) return '(ticket gone)';
    final payments = await repo.paymentsFor(ticketId);
    final profile = await ref.read(printingProvider).shopProfile();
    return ReceiptTextPreview.render(
      ticket: t,
      payments: payments,
      shopName: profile.name,
      address: profile.address,
      gstin: profile.gstin,
      phone: profile.phone,
      columns: columns,
    );
  }
}
