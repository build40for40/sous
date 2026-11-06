import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sous/api/sse.dart';

Stream<List<int>> chunks(List<String> parts) =>
    Stream.fromIterable(parts.map(utf8.encode));

Future<List<(String, String)>> parse(Stream<List<int>> bytes) async => [
  await for (final m in parseSse(bytes)) (m.event, m.data),
];

void main() {
  test('reads events split across chunks at any point', () async {
    const body =
        'event: text\ndata: {"type":"text","delta":"Hi"}\n\n'
        'event: done\ndata: {"type":"done","stop_reason":"end_turn"}\n\n';
    final bytes = utf8.encode(body);
    final oneByteAtATime = Stream.fromIterable([
      for (final b in bytes) [b],
    ]);

    expect(await parse(oneByteAtATime), [
      ('text', '{"type":"text","delta":"Hi"}'),
      ('done', '{"type":"done","stop_reason":"end_turn"}'),
    ]);
  });

  test('keeps multi-byte characters split between chunks', () async {
    final bytes = utf8.encode('data: crème fraîche 🍳\n\n');
    expect(
      await parse(Stream.fromIterable([bytes.sublist(0, 9), bytes.sublist(9)])),
      [('message', 'crème fraîche 🍳')],
    );
  });

  test('joins data lines, skips comments, handles CRLF and no space', () async {
    expect(
      await parse(
        chunks([
          ': keep-alive\r\n',
          'event:text\r\ndata:one\r\ndata: two\r\n\r\n',
          'retry: 1000\n\n',
        ]),
      ),
      [('text', 'one\ntwo')],
    );
  });

  test('drops an event cut off before its blank line', () async {
    expect(
      await parse(chunks(['event: text\ndata: a\n\n', 'event: text\ndata: b'])),
      [('text', 'a')],
    );
  });
}
