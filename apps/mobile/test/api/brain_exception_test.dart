import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sous/api/brain_exception.dart';

void main() {
  BrainError map(int status, [String? code]) => BrainException.fromResponse(
    status,
    code == null ? '' : jsonEncode({'error': code}),
  ).error;

  test('maps the brain responses to clear states', () {
    expect(map(401, 'sign_in_required'), BrainError.signedOut);
    expect(map(409, 'session_ended'), BrainError.sessionEnded);
    expect(map(409, 'turn_in_progress'), BrainError.turnInProgress);
    expect(map(409, 'tool_results_required'), BrainError.toolResultsRequired);
    expect(map(404, 'recipe_not_found'), BrainError.notFound);
    expect(map(400, 'invalid_recipe'), BrainError.invalid);
    expect(map(413, 'body_too_large'), BrainError.invalid);
    expect(map(503, 'live_sessions_unavailable'), BrainError.unavailable);
    expect(map(502, 'suggestions_failed'), BrainError.retryable);
    expect(map(500), BrainError.retryable);
  });

  test('keeps the code, owed tool call ids and details', () {
    final e = BrainException.fromResponse(
      409,
      jsonEncode({
        'error': 'tool_results_required',
        'tool_call_ids': ['a', 'b'],
      }),
    );
    expect(e.code, 'tool_results_required');
    expect(e.toolCallIds, ['a', 'b']);
    expect(e.status, 409);

    final invalid = BrainException.fromResponse(
      400,
      jsonEncode({
        'error': 'invalid_recipe',
        'issues': [
          {'path': '/title', 'message': 'required'},
        ],
      }),
    );
    expect(invalid.details!['issues'], hasLength(1));
  });

  test('copes with a body that is not JSON', () {
    final e = BrainException.fromResponse(502, '<html>Bad gateway</html>');
    expect(e.error, BrainError.retryable);
    expect(e.code, isNull);
  });
}
