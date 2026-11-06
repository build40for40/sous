import 'dart:convert';

class SseMessage {
  const SseMessage({required this.event, required this.data});

  /// `message` when the server named no event.
  final String event;
  final String data;
}

/// Splits a `text/event-stream` body into messages, following the HTML
/// spec's parsing rules. A message cut off before its blank line is dropped.
Stream<SseMessage> parseSse(Stream<List<int>> bytes) async* {
  var event = '';
  final data = StringBuffer();
  var hasData = false;

  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (hasData) {
        yield SseMessage(
          event: event.isEmpty ? 'message' : event,
          data: data.toString(),
        );
      }
      event = '';
      data.clear();
      hasData = false;
      continue;
    }
    if (line.startsWith(':')) continue;

    final colon = line.indexOf(':');
    final field = colon == -1 ? line : line.substring(0, colon);
    var value = colon == -1 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);

    switch (field) {
      case 'event':
        event = value;
      case 'data':
        if (hasData) data.write('\n');
        data.write(value);
        hasData = true;
    }
  }
}
