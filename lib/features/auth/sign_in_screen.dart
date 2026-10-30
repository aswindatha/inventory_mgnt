import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/env.dart';
import '../../core/failures.dart';
import '../../providers/providers.dart';
import '../common/widgets.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _displayName = TextEditingController();

  bool _isSignUp = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _displayName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final auth = ref.read(authRepositoryProvider);
      if (_isSignUp) {
        final hasSession = await auth.signUp(
          _email.text,
          _password.text,
          displayName: _displayName.text.trim().isEmpty ? null : _displayName.text.trim(),
        );
        if (!hasSession && mounted) {
          setState(() {
            _isSignUp = false;
            _error = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Account created. Check your email to confirm, then sign in.'),
            ),
          );
        }
      } else {
        await auth.signIn(_email.text, _password.text);
      }
    } on AppFailure catch (e) {
      if (mounted) setState(() => _error = e.userMessage);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resetPassword() async {
    if (_email.text.trim().isEmpty) {
      setState(() => _error = 'Enter your email address first.');
      return;
    }
    final ok = await runGuarded(
      context,
      () => ref.read(authRepositoryProvider).sendPasswordReset(_email.text),
      successMessage: 'Password reset email sent.',
    );
    if (!ok && mounted) setState(() => _error = 'Could not send the reset email.');
  }

  @override
  Widget build(BuildContext context) {
    final configured = ref.watch(backendConfiguredProvider);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.memory,
                    size: 56,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Electronics Inventory',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Multi-site stock and project tracking for your team',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),

                  if (!configured) const _BackendNotConfiguredCard(),

                  if (configured) ...[
                    if (_error != null) ...[
                      InfoBanner(message: _error!, tone: BannerTone.danger),
                      const SizedBox(height: 8),
                    ],
                    Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          TextFormField(
                            controller: _email,
                            autofocus: true,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(
                              labelText: 'Email',
                              prefixIcon: Icon(Icons.mail_outline),
                            ),
                            validator: (v) {
                              final value = v?.trim() ?? '';
                              if (value.isEmpty) return 'Email is required';
                              if (!value.contains('@')) return 'Enter a valid email';
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),
                          if (_isSignUp) ...[
                            TextFormField(
                              controller: _displayName,
                              textInputAction: TextInputAction.next,
                              textCapitalization: TextCapitalization.words,
                              decoration: const InputDecoration(
                                labelText: 'Display name (optional)',
                                prefixIcon: Icon(Icons.person_outline),
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                          TextFormField(
                            controller: _password,
                            obscureText: _obscure,
                            autofillHints: const [AutofillHints.password],
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) => _submit(),
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock_outline),
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                ),
                                onPressed: () => setState(() => _obscure = !_obscure),
                                tooltip: _obscure ? 'Show password' : 'Hide password',
                              ),
                            ),
                            validator: (v) {
                              if ((v ?? '').isEmpty) return 'Password is required';
                              if (_isSignUp && (v ?? '').length < 6) {
                                return 'Use at least 6 characters';
                              }
                              return null;
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_isSignUp ? 'Create account' : 'Sign in'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _isSignUp = !_isSignUp;
                              _error = null;
                            }),
                      child: Text(
                        _isSignUp
                            ? 'Already have an account? Sign in'
                            : 'New here? Create an account',
                      ),
                    ),
                    if (!_isSignUp)
                      TextButton(
                        onPressed: _busy ? null : _resetPassword,
                        child: const Text('Forgot password?'),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BackendNotConfiguredCard extends StatelessWidget {
  const _BackendNotConfiguredCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud_off_outlined, size: 20),
                const SizedBox(width: 8),
                Text('Backend not configured', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              'The app is running on its local cache only. Point it at your '
              'Supabase project to sign in and share data with your team.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 14),
            Text('1. Run the migrations', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            SelectableText(
              'supabase/migrations/0001_schema.sql\n'
              'supabase/migrations/0002_rls.sql',
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
            const SizedBox(height: 12),
            Text('2. Relaunch with your project credentials', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            SelectableText(
              'flutter run \\\n'
              '  --dart-define=SUPABASE_URL=${AppConfig.supabaseUrl.isEmpty ? 'https://<ref>.supabase.co' : AppConfig.supabaseUrl} \\\n'
              '  --dart-define=SUPABASE_ANON_KEY=<anon-key>',
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }
}
