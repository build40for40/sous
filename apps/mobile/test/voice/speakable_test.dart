import 'package:flutter_test/flutter_test.dart';
import 'package:sous/voice/speakable.dart';

void main() {
  test('numbers and units become words', () {
    expect(
      speakable('Bake at 200°C for 25 mins.'),
      'Bake at two hundred degrees Celsius for twenty five minutes.',
    );
    expect(
      speakable('Add 1 tbsp oil and 2 tsp salt.'),
      'Add one tablespoon oil and two teaspoons salt.',
    );
    expect(
      speakable('400g tins, 1.5 kg flour, 250ml milk'),
      'four hundred grams tins, one point five kilograms flour, '
      'two hundred and fifty millilitres milk',
    );
  });

  test('fractions, ranges, times and ordinals', () {
    expect(speakable('Use ½ an onion'), 'Use a half an onion');
    expect(speakable('1½ cups'), 'one and a half cups');
    expect(
      speakable('1 1/2 cups and 3/4 cup'),
      'one and a half cups and three quarters cup',
    );
    expect(speakable('Simmer 2-3 hrs'), 'Simmer two to three hours');
    expect(
      speakable('Ready at 6:30, or 7:05, by 8:00'),
      "Ready at six thirty, or seven oh five, by eight o'clock",
    );
    expect(
      speakable('The 2nd step, then the 21st'),
      'The second step, then the twenty first',
    );
  });

  test('big numbers and plain text', () {
    expect(speakable('1,250 g'), 'one thousand two hundred and fifty grams');
    expect(speakable('salt & pepper'), 'salt and pepper');
    expect(speakable('Stir it well.'), 'Stir it well.');
    expect(speakable('2 eggs'), 'two eggs');
    expect(numberWords(105), 'one hundred and five');
    expect(numberWords(2000005), 'two million and five');
  });
}
