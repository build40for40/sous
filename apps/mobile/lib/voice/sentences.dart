/// Cuts Sous's reply into sentences as it streams in, so the first one can be
/// spoken while the rest is still arriving.
class SentenceSplitter {
  SentenceSplitter({this.maxLength = 220});

  /// A sentence longer than this is cut at a comma, or failing that a space,
  /// so a run-on reply doesn't hold up speech.
  final int maxLength;

  static final _end = RegExp(r'''[.!?…]+["')\]]*\s+|\n+''');
  static final _clause = RegExp(r'[,;:]\s+');

  var _pending = '';

  /// Adds [delta] and returns the sentences it completed.
  List<String> add(String delta) {
    _pending += delta;
    final out = <String>[];
    while (true) {
      final match = _end.firstMatch(_pending);
      if (match != null) {
        _take(match.end, out);
        continue;
      }
      if (_pending.length <= maxLength) break;
      final head = _pending.substring(0, maxLength);
      final clauses = _clause.allMatches(head).toList();
      final space = head.lastIndexOf(' ');
      final cut = clauses.isNotEmpty
          ? clauses.last.end
          : space > 0
          ? space + 1
          : maxLength;
      _take(cut, out);
    }
    return out;
  }

  /// Whatever is left once the reply has finished, or null if nothing is.
  String? flush() {
    final rest = _pending.trim();
    _pending = '';
    return rest.isEmpty ? null : rest;
  }

  void clear() => _pending = '';

  void _take(int end, List<String> out) {
    final sentence = _pending.substring(0, end).trim();
    _pending = _pending.substring(end);
    if (sentence.isNotEmpty) out.add(sentence);
  }
}
