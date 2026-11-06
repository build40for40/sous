import '../api/cooks.dart';

const _words = {
  'one': 1,
  'first': 1,
  'won': 1,
  'two': 2,
  'second': 2,
  'to': 2,
  'too': 2,
  'three': 3,
  'third': 3,
  'four': 4,
  'fourth': 4,
  'for': 4,
  'five': 5,
  'fifth': 5,
  'six': 6,
  'sixth': 6,
  'seven': 7,
  'seventh': 7,
  'eight': 8,
  'eighth': 8,
  'nine': 9,
  'ninth': 9,
  'ten': 10,
  'tenth': 10,
};

/// The choice in "number three", "the third one" or "3", or null when the
/// chef didn't pick a number.
int? spokenNumber(String said) {
  final words = said
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  final at = words.indexOf('number');
  final candidates = at >= 0 && at + 1 < words.length
      ? [words[at + 1]]
      : words.where((w) => w != 'to' && w != 'too' && w != 'for');
  for (final w in candidates) {
    final n = int.tryParse(w) ?? _words[w];
    if (n != null) return n;
  }
  return null;
}

/// The suggestion the chef picked by its `number`, like "Hey Sous, number
/// three".
Suggestion? pickSuggestion(List<Suggestion> suggestions, String said) {
  final n = spokenNumber(said);
  if (n == null) return null;
  for (final s in suggestions) {
    if (s.number == n) return s;
  }
  return null;
}
