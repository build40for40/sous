import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sous/api/brain_client.dart';
import 'package:sous/api/session.dart';
import 'package:sous/cooking/cooking_tools.dart';

import 'fakes.dart';

/// A brain that plays scripted replies and enforces the turn rules: results
/// for every owed tool call come back together, and only those.
class FakeBrain {
  final replies = <Object>[];
  final turns = <Map<String, Object?>>[];
  Map<String, Object?>? endBody;
  List<String> owed = [];
  bool ended = false;

  /// How many more turns to turn away as still in progress.
  int busy = 0;
  http.StreamedResponse Function()? startResponse;

  BrainClient get brainClient => BrainClient(
    baseUri: Uri.parse('https://brain.test/sous/api/v1'),
    httpClient: client,
    tokens: FakeTokenSource(),
  );

  late final client = MockClient.streaming((request, bodyStream) async {
    final text = await bodyStream.bytesToString();
    final body = text.isEmpty
        ? <String, Object?>{}
        : jsonDecode(text) as Map<String, Object?>;
    final path = request.url.path.replaceFirst('/sous/api/v1', '');
    expect(request.headers['Authorization'], startsWith('Bearer token-'));

    if (path == '/sessions') {
      return startResponse?.call() ??
          json({
            'id': 'session-fake-1',
            'recipe_id': body['recipe_id'],
            'stage': 'decide',
            'started_at': '2026-11-06T18:00:00Z',
            'opening_line': 'Right, fake beans on toast. Got everything out?',
          }, 201);
    }
    if (path == '/sessions/session-fake-1/end') {
      if (ended) return json({'error': 'session_ended'}, 409);
      ended = true;
      endBody = body;
      return json({
        'id': 'session-fake-1',
        'ended_at': '2026-11-06T18:12:00Z',
        ...body,
        'reflection_status': 'pending',
      }, 202);
    }
    if (path == '/sessions/session-fake-1/turns') {
      if (ended) return json({'error': 'session_ended'}, 409);
      if (busy > 0) {
        busy--;
        return json({'error': 'turn_in_progress'}, 409);
      }
      final sent = [
        for (final r in (body['tool_results'] as List? ?? const []))
          (r as Map)['tool_call_id'] as String,
      ];
      if (owed.isNotEmpty &&
          (sent.length != owed.length || !owed.every(sent.contains))) {
        return json({
          'error': 'tool_results_required',
          'tool_call_ids': owed,
        }, 409);
      }
      turns.add(body);
      final reply = replies.removeAt(0);
      if (reply is http.StreamedResponse) return reply;
      final events = reply as List<Map<String, Object?>>;
      final done = events.last;
      if (done['type'] == 'done') {
        owed = done['stop_reason'] == 'tool_use'
            ? [
                for (final e in events)
                  if (e['type'] == 'tool_call')
                    (e['tool_call'] as Map)['id'] as String,
              ]
            : [];
      }
      return http.StreamedResponse(
        Stream.fromIterable([
          for (final e in events) ...utf8.encode(sse(e)).map((b) => [b]),
        ]),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    fail('Unexpected ${request.method} $path');
  });

  static http.StreamedResponse json(Object body, int status) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(body))),
        status,
      );
}

class FakeKitchen implements CookingTools {
  final log = <String>[];
  var _timers = 0;

  /// When set, timers wait for it before starting.
  Completer<void>? gate;

  @override
  Future<String> startTimer(String label, int seconds) async {
    await gate?.future;
    log.add('start $label $seconds');
    return 'timer-${++_timers}';
  }

  @override
  Future<void> cancelTimer(String timerId) async => log.add('cancel $timerId');

  @override
  Future<void> goToStep(int index) async => log.add('step $index');

  @override
  Future<void> setStage(Stage stage) async => log.add('stage ${stage.name}');

  @override
  Future<void> show(ShowView view) async => log.add('show ${view.name}');
}

Map<String, Object?> text(String delta) => {'type': 'text', 'delta': delta};

Map<String, Object?> tool(String id, String name, Map<String, Object?> input) =>
    {
      'type': 'tool_call',
      'tool_call': {'id': id, 'name': name, 'input': input},
    };

Map<String, Object?> done(String stopReason) => {
  'type': 'done',
  'stop_reason': stopReason,
};

/// A turn reply the test feeds by hand, for replies still streaming.
class SlowReply {
  final _bytes = StreamController<List<int>>();

  http.StreamedResponse get response => http.StreamedResponse(
    _bytes.stream,
    200,
    headers: {'content-type': 'text/event-stream'},
  );

  void send(Map<String, Object?> event) => _bytes.add(utf8.encode(sse(event)));

  Future<void> close() => _bytes.close();
}
