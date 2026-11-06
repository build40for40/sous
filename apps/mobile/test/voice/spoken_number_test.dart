import 'package:flutter_test/flutter_test.dart';
import 'package:sous/api/cooks.dart';
import 'package:sous/voice/spoken_number.dart';

void main() {
  test('hears the number the chef picked', () {
    expect(spokenNumber('Number three'), 3);
    expect(spokenNumber('number two please'), 2);
    expect(spokenNumber('Number 3.'), 3);
    expect(spokenNumber('The first one'), 1);
    expect(spokenNumber('Go for number four'), 4);
    expect(spokenNumber('I want to cook'), isNull);
  });

  test('picks a suggestion by its number, not its place', () {
    const suggestions = [
      Suggestion(number: 1, recipeId: 'r1', title: 'Fake Dahl', reason: 'a'),
      Suggestion(number: 3, recipeId: 'r3', title: 'Fake Orzo', reason: 'c'),
      Suggestion(number: 2, recipeId: 'r2', title: 'Fake Salmon', reason: 'b'),
    ];
    expect(pickSuggestion(suggestions, 'number three')?.recipeId, 'r3');
    expect(pickSuggestion(suggestions, 'number nine'), isNull);
    expect(pickSuggestion(suggestions, 'what is there'), isNull);
  });
}
