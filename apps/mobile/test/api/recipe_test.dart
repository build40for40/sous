import 'package:flutter_test/flutter_test.dart';
import 'package:sous/api/recipe.dart';

import '../support/fakes.dart';

void main() {
  test('reads the contract example recipe', () {
    final recipe = Recipe.fromJson(contractExample('recipe.json'));

    expect(recipe.id, 'recipe-example-1');
    expect(recipe.slug, 'fake-example-beans-on-toast');
    expect(recipe.servings, 2);
    expect(recipe.times!.totalMinutes, 8);
    expect(recipe.ingredients.first.quantity, 400);
    expect(recipe.ingredients.last.quantity, isNull);
    expect(recipe.ingredients.last.note, 'to taste');
    expect(recipe.steps.first.durationSeconds, 300);
    expect(recipe.steps[1].doneCue, 'Golden brown and crisp all over.');
  });

  test('writes a new recipe without the fields the brain sets', () {
    final json = Recipe.fromJson(
      contractExample('recipe.json')..addAll({
        'created_at': '2026-11-06T18:00:00Z',
        'updated_at': '2026-11-06T18:00:00Z',
      }),
    ).toJson();

    expect(
      json.keys,
      unorderedEquals([
        'title',
        'source_url',
        'servings',
        'times',
        'ingredients',
        'steps',
      ]),
    );
    expect((json['ingredients'] as List).last, {
      'name': 'black pepper',
      'note': 'to taste',
    });
  });
}
