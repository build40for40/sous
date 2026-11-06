import 'dart:convert';

/// The states a failed brain call lands in, for the screens to show.
enum BrainError {
  /// 401: the cook has to sign in again.
  signedOut,

  /// 409 `session_ended`.
  sessionEnded,

  /// 409 `turn_in_progress`: Sou is still answering the last thing.
  turnInProgress,

  /// 409 `tool_results_required`: [BrainException.toolCallIds] are owed.
  toolResultsRequired,

  /// 404.
  notFound,

  /// 400 or 413: the request itself was wrong. Retrying won't help.
  invalid,

  /// 503: switched off on the server (e.g. no model key yet).
  unavailable,

  /// 502 or another 5xx: worth trying again.
  retryable,

  /// No connection, a timeout, or a stream that broke off.
  network,
}

class BrainException implements Exception {
  const BrainException(
    this.error, {
    this.status,
    this.code,
    this.toolCallIds = const [],
    this.details,
  });

  /// Reads the brain's `{"error": code, ...}` body.
  factory BrainException.fromResponse(int status, String body) {
    Map<String, Object?>? json;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, Object?>) json = decoded;
    } on FormatException {
      json = null;
    }
    final code = json?['error'] as String?;
    final error = switch ((status, code)) {
      (401, _) => BrainError.signedOut,
      (409, 'session_ended') => BrainError.sessionEnded,
      (409, 'turn_in_progress') => BrainError.turnInProgress,
      (409, 'tool_results_required') => BrainError.toolResultsRequired,
      (404, _) => BrainError.notFound,
      (503, _) => BrainError.unavailable,
      (>= 500, _) => BrainError.retryable,
      _ => BrainError.invalid,
    };
    final ids = json?['tool_call_ids'];
    return BrainException(
      error,
      status: status,
      code: code,
      toolCallIds: ids is List ? ids.whereType<String>().toList() : const [],
      details: json,
    );
  }

  final BrainError error;
  final int? status;

  /// The brain's error code, e.g. `recipe_not_found` or `invalid_recipe`.
  final String? code;
  final List<String> toolCallIds;

  /// The whole error body, e.g. with `issues` for an invalid recipe.
  final Map<String, Object?>? details;

  @override
  String toString() => 'BrainException(${error.name}, $status, $code)';
}
