/// Sign-in + first-run manager setup (Task S1/S2).
///
/// A shared tablet, four staff, a 4-6 digit PIN, no usernames: that is what the
/// counter asked for. Three rules this screen keeps:
///  * a PIN the model would reject cannot be typed here at all — `DigitBuffer`
///    is digits-only and `validatePin` decides what is acceptable, so the two
///    rules can never disagree about what "valid" means;
///  * the "wait 60 s" message comes from `lockInfo`, i.e. from the same row the
///    lockout is enforced against, not from a timer in this widget;
///  * a wrong PIN shows dots, never the digits that were typed (a shared tablet
///    faces the queue).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/widgets/number_pad.dart';
import '../../../core/providers.dart';
import '../../../data/models/staff.dart';
import '../../staff_auth/domain/pin_hasher.dart';

/// The PIN pad used by sign-in, first-run and any future "confirm with PIN"
/// dialog. Shared so the lockout message and the digit rules are identical in
/// all three (a per-screen pad is how one of them forgets the max length).
class PinPad extends StatelessWidget {
  const PinPad({
    super.key,
    required this.title,
    required this.pin,
    required this.message,
    required this.busy,
    required this.onSubmit,
    this.onBack,
    this.backLabel = 'Back',
    this.submitLabel = 'Start',
    this.hint = 'Enter PIN (4-6 digits)',
    this.minDigits = PinHasher.pinLengthMin,
  });

  final String title;
  final String hint;
  final String submitLabel;
  final String backLabel;
  final int minDigits;
  final DigitBuffer pin;
  final String? message;
  final bool busy;
  final VoidCallback onSubmit;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              SizedBox(
                width: 100,
                child: onBack == null
                    ? null
                    : TextButton.icon(
                        onPressed: onBack,
                        icon: const Icon(Icons.arrow_back),
                        label: Text(backLabel),
                      ),
              ),
              Expanded(child: Text(title, textAlign: TextAlign.center, style: theme.textTheme.titleMedium)),
              const SizedBox(width: 100),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            pin.isEmpty ? hint : '●' * pin.length,
            style: theme.textTheme.headlineSmall?.copyWith(letterSpacing: 6),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          if (message != null && message!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.w600),
              ),
            ),
          const SizedBox(height: 12),
          NumberPad(
            onDigit: (d) => pin.append('$d'),
            onBackspace: pin.backspace,
            onClear: pin.clear,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: pin.length >= minDigits && !busy ? onSubmit : null,
              icon: busy
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: Text(submitLabel),
            ),
          ),
        ],
      ),
    );
  }
}

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  StaffUser? _picked;
  final DigitBuffer _pin = DigitBuffer(maxLength: PinHasher.pinLengthMax);
  String? _message;
  bool _busy = false;

  Future<void> _submit() async {
    final user = _picked;
    if (user == null) return;
    setState(() => _busy = true);
    String? message;
    try {
      final ok = await ref.read(staffRepositoryProvider).authenticate(userId: user.id, pin: _pin.text);
      if (ok == null) {
        final lock = await ref.read(staffRepositoryProvider).lockInfo(user.id);
        message = lock.message.isEmpty ? 'Wrong PIN for ${user.name}' : lock.message;
      } else {
        // S3: a shift is opened implicitly at sign-in. An explicit "start shift"
        // button on a till is a button nobody presses, and a shift-less cash day
        // has no baseline to count against — worse than a zero float.
        final opened = await ref.read(staffRepositoryProvider).openShift(user.id);
        ref.read(currentSessionProvider.notifier).state = PosSession(
          userId: user.id,
          name: user.name,
          roleName: user.role.label,
          since: opened.openedAt,
        );
      }
    } catch (e) {
      // A repository rejection (locked row, unknown user) is a *message*, not a
      // crash: the cashier must still be able to try the next person.
      message = '$e';
    }
    if (!mounted) return;
    _pin.clear();
    setState(() {
      _busy = false;
      _message = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(staffUsersProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: users.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not read the staff list:\n$e'),
              ),
              data: (list) {
                final active = [for (final u in list) if (u.active) u];
                final picked = _picked;
                if (picked == null || !active.any((u) => u.id == picked.id)) {
                  return _UserPicker(
                    users: active,
                    onPick: (u) => setState(() {
                      _picked = u;
                      _message = null;
                      _pin.clear();
                    }),
                  );
                }
                return PinPad(
                  title: '${picked.name} - ${picked.role.label}',
                  pin: _pin,
                  message: _message,
                  busy: _busy,
                  onBack: () => setState(() => _picked = null),
                  onSubmit: _submit,
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _UserPicker extends StatelessWidget {
  const _UserPicker({required this.users, required this.onPick});

  final List<StaffUser> users;
  final ValueChanged<StaffUser> onPick;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Who is on the till?', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 16),
        for (final u in users)
          Card(
            child: ListTile(
              leading: CircleAvatar(child: Text(u.name.characters.first.toUpperCase())),
              title: Text(u.name),
              subtitle: Text(u.role.label),
              trailing: u.isLocked ? const Icon(Icons.lock_outline) : const Icon(Icons.chevron_right),
              onTap: () => onPick(u),
            ),
          ),
        if (users.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No active staff. Every user is disabled - enable one from a '
              'manager account, or restore a backup.',
            ),
          ),
      ],
    );
  }
}

/// First launch only: the manager who can then add everyone else (S1).
class FirstRunScreen extends ConsumerStatefulWidget {
  const FirstRunScreen({super.key, this.onDone});

  final VoidCallback? onDone;

  @override
  ConsumerState<FirstRunScreen> createState() => _FirstRunScreenState();
}

class _FirstRunScreenState extends ConsumerState<FirstRunScreen> {
  final TextEditingController _name = TextEditingController();
  final DigitBuffer _pin = DigitBuffer(maxLength: PinHasher.pinLengthMax);
  String? _message;
  bool _busy = false;

  Future<void> _create() async {
    final problem = PinHasher.validatePin(_pin.text);
    if (problem != null) {
      setState(() => _message = problem);
      return;
    }
    if (_name.text.trim().isEmpty) {
      setState(() => _message = 'The shop needs a manager name');
      return;
    }
    setState(() => _busy = true);
    String? message;
    try {
      await ref.read(staffRepositoryProvider).createManager(name: _name.text.trim(), pin: _pin.text);
    } catch (e) {
      message = '$e';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = message;
    });
    if (message == null) widget.onDone?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Set up the manager',
                    style: Theme.of(context).textTheme.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'This PIN unlocks the till and everything sensitive: voids, '
                    'reports, menu prices and the backup. Only this account can '
                    'add staff later.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Name'),
                    textCapitalization: TextCapitalization.words,
                  ),
                  const SizedBox(height: 16),
                  PinPad(
                    title: 'Manager PIN',
                    hint: 'Choose a PIN (4-6 digits)',
                    submitLabel: 'Create manager',
                    minDigits: PinHasher.pinLengthMin,
                    pin: _pin,
                    message: _message,
                    busy: _busy,
                    onSubmit: _create,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
