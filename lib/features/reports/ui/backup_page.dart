/// Backup + restore (Task T4's UI).
///
/// Two buttons and a list. Deliberately no "auto-backup daily" toggle in v1: an
/// automatic write to the app documents dir on a phone nobody plugs in is a file
/// nobody ever opens, so v1 makes the export explicit and the *reminder* is a
/// line on the reports screen. (A scheduled export belongs with the sync engine,
/// T5, where there is a real place for it to go.)
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../data/backup/backup_service.dart';
import '../../../data/backup/restore_service.dart';
import '../../../data/backup/snapshot_format.dart';
import '../../../data/backup/snapshot_validator.dart';
import '../../../data/tables/menu_tables.dart' show MetaKeys;

class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  bool _busy = false;
  String? _message;
  bool _isError = false;
  List<_BackupFile> _files = const [];

  /// `MetaKeys.backupLastAt`, for the staleness line below. Read from meta and not
  /// from the newest file's mtime, because those two disagree after a restore onto
  /// a fresh device — and the honest question is "when did THIS app last write
  /// one", not "when was something touched on this filesystem".
  DateTime? _lastAt;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final db = ref.read(appDatabaseProvider);
      final lastRaw = await db.metaValue(MetaKeys.backupLastAt);
      final dir = await backupDirectory();
      // `snapshotFileName` writes `kazama_backup_<stamp>_<suffix>.json`. Only
      // those are offered: the sidecar (`....json.sha256`) is NOT a restore
      // source, and a user who picked it by mistake must not get as far as trying.
      final entries = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last.startsWith('kazama_backup_') && f.path.endsWith('.json')).toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      if (!mounted) return;
      setState(() => _files = [
        for (final f in entries)
          _BackupFile(
            path: f.path,
            name: f.uri.pathSegments.last,
            bytes: f.lengthSync(),
            written: f.statSync().modified,
          ),
      ]);
    } catch (e) {
      if (mounted) setState(() => _message = 'Could not list the backups folder: $e');
    }
  }

  Future<void> _export() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      // The drift `schemaVersion` IS the app schema number here (T3 owns both),
      // so no second source of truth is introduced. `beforeOpen` mirrors it into
      // `app_meta` (`MetaKeys.schemaVersion`) for anyone reading the file.
      final db = ref.read(appDatabaseProvider);
      final artifact = await ref.read(backupServiceProvider).export(appSchemaVersion: db.schemaVersion);
      await _load();
      if (!mounted) return;
      final rows = _rowsIn(artifact.payload);
      // Recorded so the reports/settings screens can nag about a day without a
      // snapshot. A backup nobody can prove is recent is a backup nobody trusts.
      await ref.read(appDatabaseProvider).setMetaValue(MetaKeys.backupLastAt, DateTime.now().toIso8601String());
      setState(() {
        _lastAt = DateTime.now();
        _isError = false;
        _message = 'Wrote ${artifact.file.uri.pathSegments.last} · '
            '$rows rows · ${artifact.bytes} bytes.\n'
            'Checksum: ${artifact.checksumFile?.uri.pathSegments.last ?? 'none'}';
      });
    } on BackupException catch (e) {
      if (mounted) setState(() { _isError = true; _message = e.toString(); });
    } catch (e) {
      if (mounted) setState(() { _isError = true; _message = '$e'; });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(_BackupFile f, {required bool replace}) async {
    final service = ref.read(restoreServiceProvider);
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      // `inspect` FIRST: the validator reads and rejects before a single write,
      // which is what makes "restore a corrupt file" safe at a counter (T4).
      // The validator runs BEFORE any write, and its problems are what we show:
      // a truncated or foreign file must fail here, with a sentence a shopkeeper
      // can read, not as a crash in the middle of a table wipe (T4).
      final validation = await service.inspect(f.asFile);
      if (!validation.report.isValid) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _isError = true;
          _message = 'Not restored — ${validation.report.problems.length} problem(s):\n'
              '${validation.report.problems.take(8).map((p_) => "  · $p_").join("\n")}';
        });
        return;
      }
      final result = await service.restoreFile(f.asFile, replace: replace, confirmReplace: replace);
      if (!mounted) return;
      final applied = result.appliedRows.entries.map((e) => '${e.key}: ${e.value}').join('\n    ');
      setState(() {
        _isError = false;
        _message = 'Restored from ${f.name}'
            '${result.replaced ? ' (REPLACE — tables wiped first; safety copy: ${result.preWipeFile?.uri.pathSegments.last ?? "none"})' : ''}\n'
            '    $applied\n'
            '  Reload the till: the menu and bills on screen are still the old ones.';
      });
    } on BackupException catch (e) {
      if (mounted) setState(() { _isError = true; _message = e.toString(); });
    } catch (e) {
      if (mounted) setState(() { _isError = true; _message = '$e'; });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & restore')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'A snapshot is one JSON file with every table plus a .sha256 sidecar. '
            'Copy it off the phone (WhatsApp it to yourself is fine) — a backup on '
            'the same device is not a backup.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: _busy ? null : _export,
            icon: _busy ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt),
            label: const Text('Write a snapshot now'),
          ),
          const SizedBox(height: 16),
          // The staleness line, above the list: the list's newest row may be
          // weeks old and still LOOK fine unless someone says so in words.
          Text(_stalenessNote, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 6),
          Text('Files on this device', style: theme.textTheme.titleMedium),
          if (_files.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('None yet.')),
          for (final f in _files)
            Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                title: Text(f.name, style: theme.textTheme.bodyMedium),
                subtitle: Text('${f.readable} · ${f.writtenText}'),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    IconButton(
                      tooltip: 'Merge (keep current rows, apply this file over them)',
                      icon: const Icon(Icons.merge_outlined),
                      onPressed: _busy ? null : () => _restore(f, replace: false),
                    ),
                    IconButton(
                      tooltip: 'Replace (wipe, then restore)',
                      icon: const Icon(Icons.dangerous_outlined, color: null),
                      onPressed: _busy ? null : () => _confirmReplace(f),
                    ),
                  ],
                ),
              ),
            ),
          if (_message != null) ...[
            const SizedBox(height: 16),
            SelectableText(
              _message!,
              style: TextStyle(color: _isError ? theme.colorScheme.error : theme.colorScheme.primary),
            ),
          ],
          const SizedBox(height: 18),
          // The rule the whole T4 design hangs on, in the UI rather than only in
          // the code: a person must know which of the two buttons is destructive.
          Text(
            'Merge is safe and is what you want after fixing a wrong price. '
            'Replace destroys every current bill — it is for a new phone or a '
            'corrupt database, and it writes its own snapshot first.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  /// Plain words, because "when did you last copy this off the phone?" is a
  /// question a shopkeeper can only answer if the app remembered it.
  String get _stalenessNote {
    final last = _lastAt;
    if (last == null) {
      return _files.isEmpty
          ? 'No snapshot has ever been written from this device.'
          : 'A snapshot exists but this app has no record of writing it (restored device?).';
    }
    final days = DateTime.now().difference(last).inDays;
    final hour = DateTime.now().difference(last).inHours;
    if (hour < 1) return 'Last snapshot: just now.';
    if (days == 0) return 'Last snapshot: ${hour}h ago — write one before you close today.';
    return 'Last snapshot: $days day${days == 1 ? '' : 's'} ago. Anything sold since then exists ONLY on this phone.';
  }

  Future<void> _confirmReplace(_BackupFile f) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Replace everything?'),
        content: Text(
          'This deletes every bill, payment, menu item and stock row on this '
          'device and loads $f.name. A snapshot of the current state is written '
          'FIRST, so this is undoable — but only with that file.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Wipe and restore'),
          ),
        ],
      ),
    );
    if (sure == true) await _restore(f, replace: true);
  }

}

/// Rows across every table of an envelope — the number a person wants to see
/// after an export ("did it really take my 4,000 lines?"), computed here rather
/// than carried by the service so the service keeps one return type.
int _rowsIn(Map<String, Object?> payload) {
  final tables = payload['tables'];
  if (tables is! Map) return 0;
  var n = 0;
  for (final t in tables.values) {
    if (t is List) n += t.length;
  }
  return n;
}

class _BackupFile {
  const _BackupFile({required this.path, required this.name, required this.bytes, required this.written});

  final String path;
  final String name;
  final int bytes;
  final DateTime written;

  File get asFile => File(path);

  String get readable => bytes > 1024 * 1024 ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB' : '${(bytes / 1024).ceil()} KB';

  String get writtenText {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(written.day)}/${two(written.month)} ${two(written.hour)}:${two(written.minute)}';
  }
}
