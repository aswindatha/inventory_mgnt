/// Failure types surfaced to the UI.
///
/// Every repository method returns one of these rather than letting a raw
/// `PostgrestException` or `SocketException` reach a widget. The `message` is
/// already user-facing — screens render it directly.
sealed class AppFailure implements Exception {
  const AppFailure(this.message, {this.cause});

  final String message;
  final Object? cause;

  String get userMessage => message;

  @override
  String toString() => '$runtimeType: $message${cause == null ? '' : ' ($cause)'}';
}

/// No network, DNS failure, timeout, or the vendor site refused the connection.
class NetworkFailure extends AppFailure {
  const NetworkFailure(super.message, {super.cause});
}

/// Sign-in / sign-up / session problems.
class AuthFailure extends AppFailure {
  const AuthFailure(super.message, {super.cause});
}

/// The database rejected the write via an RLS policy or a guard trigger.
class PermissionFailure extends AppFailure {
  const PermissionFailure(super.message, {super.cause});
}

class NotFoundFailure extends AppFailure {
  const NotFoundFailure(super.message, {super.cause});
}

/// Bad input caught before hitting the network.
class ValidationFailure extends AppFailure {
  const ValidationFailure(super.message, {super.cause});
}

/// `--dart-define=SUPABASE_URL/SUPABASE_ANON_KEY` were not supplied.
class BackendNotConfiguredFailure extends AppFailure {
  const BackendNotConfiguredFailure()
    : super(
        'Backend not configured. Launch with '
        '--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...',
      );
}

/// Anything we could not classify. Always keeps [cause] for the logs.
class UnexpectedFailure extends AppFailure {
  const UnexpectedFailure(super.message, {super.cause});
}
