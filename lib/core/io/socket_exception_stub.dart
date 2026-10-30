/// Stand-in for `dart:io`'s `SocketException` on platforms without `dart:io`
/// (web). Nothing throws it there — the `is SocketException` checks in the
/// error mappers just evaluate to false.
class SocketException implements Exception {
  const SocketException(this.message, {this.osError, this.address, this.port});

  final String message;
  final Object? osError;
  final Object? address;
  final int? port;

  @override
  String toString() => 'SocketException: $message';
}
