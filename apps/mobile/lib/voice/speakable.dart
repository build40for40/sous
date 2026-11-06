/// Rewrites numbers, fractions, times and units as words. sherpa_onnx's
/// Kokoro and Kitten voices skip digits and symbols they can't read, so
/// "bake at 200°C for 25 mins" would come out as "bake at for". The brain
/// already writes speech-ready text; this catches what slips through.
String speakable(String text) {
  var s = text.replaceAllMapped(
    RegExp(r'(\d),(\d{3})\b'),
    (m) => '${m[1]}${m[2]}',
  );

  s = s.replaceAllMapped(
    RegExp('(\\d+)\\s*([${_vulgar.keys.join()}])'),
    (m) => '${m[1]} and ${_vulgar[m[2]]}',
  );
  s = s.replaceAllMapped(
    RegExp('[${_vulgar.keys.join()}]'),
    (m) => _vulgar[m[0]]!,
  );
  s = s.replaceAllMapped(
    RegExp(r'\b(\d+)\s+(\d+)/(\d+)\b'),
    (m) => '${m[1]} and ${_fraction(int.parse(m[2]!), int.parse(m[3]!))}',
  );
  s = s.replaceAllMapped(
    RegExp(r'\b(\d+)/(\d+)\b'),
    (m) => _fraction(int.parse(m[1]!), int.parse(m[2]!)),
  );

  s = s.replaceAllMapped(
    RegExp(r'\b(\d{1,2}):(\d{2})\b'),
    (m) => _clock(int.parse(m[1]!), int.parse(m[2]!)),
  );

  s = s.replaceAllMapped(
    RegExp(r'(\d)\s*°\s*([CF])\b'),
    (m) => '${m[1]} degrees ${m[2] == 'C' ? 'Celsius' : 'Fahrenheit'}',
  );
  s = s.replaceAll('°', ' degrees');

  s = s.replaceAllMapped(
    RegExp(r'(\d+(?:\.\d+)?)\s*(?:-|–|—|to)\s*(\d+(?:\.\d+)?)'),
    (m) => '${m[1]} to ${m[2]}',
  );

  s = s.replaceAllMapped(
    RegExp(r'\b(\d+)(st|nd|rd|th)\b'),
    (m) => _ordinal(int.parse(m[1]!)),
  );

  s = s.replaceAllMapped(RegExp(r'(\d+(?:\.\d+)?)\s*(%|[A-Za-z]+\b)'), (m) {
    final unit = _units[m[2]] ?? _units[m[2]!.toLowerCase()];
    if (unit == null) return m[0]!;
    final one = m[1] == '1';
    return '${m[1]} ${one ? unit.$1 : unit.$2}';
  });

  s = s.replaceAllMapped(RegExp(r'(\d+)\.(\d+)'), (m) {
    final digits = m[2]!.split('').map((d) => _ones[int.parse(d)]).join(' ');
    return '${numberWords(int.parse(m[1]!))} point $digits';
  });
  s = s.replaceAllMapped(RegExp(r'\d+'), (m) => numberWords(int.parse(m[0]!)));
  s = s.replaceAll('&', ' and ');
  return s.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
}

/// British English words for [n]: 105 is "one hundred and five".
String numberWords(int n) {
  if (n < 0) return 'minus ${numberWords(-n)}';
  if (n < 20) return _ones[n];
  if (n < 100) {
    final tens = _tens[n ~/ 10];
    return n % 10 == 0 ? tens : '$tens ${_ones[n % 10]}';
  }
  if (n < 1000) {
    final head = '${_ones[n ~/ 100]} hundred';
    return n % 100 == 0 ? head : '$head and ${numberWords(n % 100)}';
  }
  for (final (size, name) in const [
    (1000000000, 'billion'),
    (1000000, 'million'),
    (1000, 'thousand'),
  ]) {
    if (n >= size) {
      final head = '${numberWords(n ~/ size)} $name';
      final rest = n % size;
      if (rest == 0) return head;
      return rest < 100
          ? '$head and ${numberWords(rest)}'
          : '$head ${numberWords(rest)}';
    }
  }
  return '$n';
}

String _ordinal(int n) {
  final words = numberWords(n);
  for (final (cardinal, ordinal) in const [
    ('one', 'first'),
    ('two', 'second'),
    ('three', 'third'),
    ('five', 'fifth'),
    ('eight', 'eighth'),
    ('nine', 'ninth'),
    ('twelve', 'twelfth'),
  ]) {
    if (words.endsWith(cardinal)) {
      return words.substring(0, words.length - cardinal.length) + ordinal;
    }
  }
  if (words.endsWith('y')) return '${words.substring(0, words.length - 1)}ieth';
  return '${words}th';
}

String _fraction(int top, int bottom) {
  if (bottom == 0) return '${numberWords(top)} over zero';
  final name = switch (bottom) {
    2 => top == 1 ? 'half' : 'halves',
    4 => top == 1 ? 'quarter' : 'quarters',
    _ when bottom <= 12 => top == 1 ? _ordinal(bottom) : '${_ordinal(bottom)}s',
    _ => null,
  };
  if (name == null) return '${numberWords(top)} over ${numberWords(bottom)}';
  return top == 1 ? 'a $name' : '${numberWords(top)} $name';
}

String _clock(int hours, int minutes) {
  if (minutes == 0) return "${numberWords(hours)} o'clock";
  if (minutes < 10) return '${numberWords(hours)} oh ${numberWords(minutes)}';
  return '${numberWords(hours)} ${numberWords(minutes)}';
}

const _vulgar = {
  '½': 'a half',
  '⅓': 'a third',
  '⅔': 'two thirds',
  '¼': 'a quarter',
  '¾': 'three quarters',
  '⅛': 'an eighth',
};

const _ones = [
  'zero',
  'one',
  'two',
  'three',
  'four',
  'five',
  'six',
  'seven',
  'eight',
  'nine',
  'ten',
  'eleven',
  'twelve',
  'thirteen',
  'fourteen',
  'fifteen',
  'sixteen',
  'seventeen',
  'eighteen',
  'nineteen',
];

const _tens = [
  '',
  '',
  'twenty',
  'thirty',
  'forty',
  'fifty',
  'sixty',
  'seventy',
  'eighty',
  'ninety',
];

/// Unit spellings, singular and plural. Case-sensitive keys are tried first,
/// so "T" can stay out and "L" means litres.
const _units = {
  '%': ('percent', 'percent'),
  'g': ('gram', 'grams'),
  'gr': ('gram', 'grams'),
  'kg': ('kilogram', 'kilograms'),
  'kgs': ('kilogram', 'kilograms'),
  'mg': ('milligram', 'milligrams'),
  'ml': ('millilitre', 'millilitres'),
  'cl': ('centilitre', 'centilitres'),
  'dl': ('decilitre', 'decilitres'),
  'l': ('litre', 'litres'),
  'ltr': ('litre', 'litres'),
  'tbsp': ('tablespoon', 'tablespoons'),
  'tbsps': ('tablespoon', 'tablespoons'),
  'tbs': ('tablespoon', 'tablespoons'),
  'tsp': ('teaspoon', 'teaspoons'),
  'tsps': ('teaspoon', 'teaspoons'),
  'oz': ('ounce', 'ounces'),
  'lb': ('pound', 'pounds'),
  'lbs': ('pound', 'pounds'),
  'cm': ('centimetre', 'centimetres'),
  'mm': ('millimetre', 'millimetres'),
  'min': ('minute', 'minutes'),
  'mins': ('minute', 'minutes'),
  'hr': ('hour', 'hours'),
  'hrs': ('hour', 'hours'),
  'sec': ('second', 'seconds'),
  'secs': ('second', 'seconds'),
  'pt': ('pint', 'pints'),
  'qt': ('quart', 'quarts'),
};
