import 'package:flutter_test/flutter_test.dart';
import 'package:sous/api/cooks.dart';
import 'package:sous/api/session.dart';

void main() {
  test('reads a history entry, including a deleted recipe', () {
    final cook = Cook.fromJson({
      'session_id': 's1',
      'recipe_id': null,
      'recipe_title': null,
      'started_at': '2026-11-06T18:00:00Z',
      'ended_at': '2026-11-06T18:12:00Z',
      'date': '2026-11-06',
      'rating': null,
      'summary': null,
      'reflection_status': 'pending',
    });

    expect(cook.recipeTitle, isNull);
    expect(cook.date, '2026-11-06');
    expect(cook.reflectionStatus, ReflectionStatus.pending);
  });

  test('reads a suggestion', () {
    final suggestion = Suggestion.fromJson({
      'recipe_id': 'r1',
      'title': 'Fake Example Beans on Toast',
      'reason': 'You loved it last time.',
    });

    expect(suggestion.reason, 'You loved it last time.');
  });
}
