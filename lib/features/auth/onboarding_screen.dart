import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/failures.dart';
import '../../providers/providers.dart';
import '../common/widgets.dart';

/// Post-sign-up fork: create a company (becoming its owner) or join an existing
/// one with an invite code.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _createFormKey = GlobalKey<FormState>();
  final _joinFormKey = GlobalKey<FormState>();
  final _companyName = TextEditingController();
  final _inviteCode = TextEditingController();

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _companyName.dispose();
    _inviteCode.dispose();
    super.dispose();
  }

  Future<void> _createCompany() async {
    if (!(_createFormKey.currentState?.validate() ?? false)) return;
    await _run(() => ref.read(authRepositoryProvider).createCompany(_companyName.text));
  }

  Future<void> _joinCompany() async {
    if (!(_joinFormKey.currentState?.validate() ?? false)) return;
    await _run(() => ref.read(authRepositoryProvider).joinCompany(_inviteCode.text));
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      // The router redirects to the home shell as soon as the cached user row
      // carries a company_id.
    } on AppFailure catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    await runGuarded(context, () => ref.read(authRepositoryProvider).signOut());
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider).value;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Set up your workspace'),
        actions: [
          IconButton(
            onPressed: _busy ? null : _signOut,
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (user != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Signed in as ${user.label}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 12),

            if (_error != null) ...[
              InfoBanner(message: _error!, tone: BannerTone.danger),
              const SizedBox(height: 4),
            ],

            SectionCard(
              title: 'Create a company',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Start fresh. You become the owner and can invite your team '
                    'once it exists.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  Form(
                    key: _createFormKey,
                    child: TextFormField(
                      controller: _companyName,
                      textCapitalization: TextCapitalization.words,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: 'Company name',
                        prefixIcon: Icon(Icons.business_outlined),
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Enter a company name' : null,
                    ),
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _busy ? null : _createCompany,
                    icon: const Icon(Icons.add_business_outlined),
                    label: const Text('Create company'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text('or', style: Theme.of(context).textTheme.bodySmall),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 16),

            SectionCard(
              title: 'Join with an invite code',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Ask an owner or admin for your company\'s code. You will join '
                    'as a member.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 14),
                  Form(
                    key: _joinFormKey,
                    child: TextFormField(
                      controller: _inviteCode,
                      enabled: !_busy,
                      textCapitalization: TextCapitalization.characters,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]')),
                        LengthLimitingTextInputFormatter(8),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Invite code',
                        prefixIcon: Icon(Icons.vpn_key_outlined),
                        hintText: 'e.g. 4F9A2C1B',
                      ),
                      style: const TextStyle(letterSpacing: 2),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Enter the invite code' : null,
                    ),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _joinCompany,
                    icon: const Icon(Icons.login),
                    label: const Text('Join company'),
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
