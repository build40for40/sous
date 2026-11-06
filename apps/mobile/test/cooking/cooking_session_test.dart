import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sous/api/brain_client.dart';
import 'package:sous/api/brain_exception.dart';
import 'package:sous/api/session.dart';
import 'package:sous/cooking/cooking_session.dart';
import 'package:sous/cooking/cooking_tools.dart';

import '../support/fakes.dart';

/// A brain that plays scripted replies and enforces the turn rules: results
/// for every owed tool call come back together, and only those.
class FakeBrain {
  final replies = <Object>[];
  final turns = <Map<String, Object?>>[];
  Map<String, Object?>? endBody;
  List<String> owed = [];
  bool ended = false;
  http.StreamedResponse Function()? startResponse;

  late final client = MockClient.streaming((request, bodyStream) async {
    final text = await bodyStream.bytesToString();
    final body = text.isEmpty
        ? <String, Object?>{}
        : jsonDecode(text) as Map<String, Object?>;
    final path = request.url.path.replaceFirst('/sous/api/v1', '');
    expect(request.headers['Authorization'], startsWith('Bearer token-'));

    if (path == '/sessions') {
      return startResponse?.call() ??
          _json({
            'id': 'session-fake-1',
            'recipe_id': body['recipe_id'],
            'stage': 'decide',
            'started_at': '2026-11-06T18:00:00Z',
            'opening_line': 'Right, fake beans on toast. Got everything out?',
          }, 201);
    }
    if (path == '/sessions/session-fake-1/end') {
      if (ended) return _json({'error': 'session_ended'}, 409);
      ended = true;
      endBody = body;
      return _json({
        'id': 'session-fake-1',
        'ended_at': '2026-11-06T18:12:00Z',
        ...body,
        'reflection_status': 'pending',
      }, 202);
    }
    if (path == '/sessions/session-fake-1/turns') {
      if (ended) return _json({'error': 'session_ended'}, 409);
      final sent = [
        for (final r in (body['tool_results'] as List? ?? const []))
          (r as Map)['tool_call_id'] as String,
      ];
      if (owed.isNotEmpty &&
          (sent.length != owed.length || !owed.every(sent.contains))) {
        return _json({
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

  static http.StreamedResponse _json(Object body, int status) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(body))),
        status,
      );
}

class FakeKitchen implements CookingTools {
  final log = <String>[];
  var _timers = 0;

  @override
  Future<String> startTimer(String label, int seconds) async {
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

void main() {
  late FakeBrain brain;
  late FakeKitchen kitchen;
  late CookingSession session;
  late List<CookingState> states;
  late List<String> spoken;

  setUp(() {
    brain = FakeBrain();
    kitchen = FakeKitchen();
    session = CookingSession(
      brain: BrainClient(
        baseUri: Uri.parse('https://brain.test/sous/api/v1'),
        httpClient: brain.client,
        tokens: FakeTokenSource(),
      ),
      tools: kitchen,
    );
    states = [];
    spoken = [];
    session.states.listen(states.add);
    session.replyText.listen(spoken.add);
  });

  tearDown(() => session.dispose());

  test(
    'a full cook: talk, tools, results together, a dropped turn, end',
    () async {
      await session.start('recipe-example-1');
      expect(session.state.phase, CookingPhase.ready);
      expect(session.state.sessionId, 'session-fake-1');
      expect(session.state.reply, startsWith('Right, fake beans'));

      brain.replies
        ..add([
          text('Lovely. '),
          text("I'll start a timer."),
          tool('t1', 'set_stage', {'stage': 'cook'}),
          tool('t2', 'go_to_step', {'index': 0}),
          tool('t3', 'start_timer', {'label': 'beans', 'seconds': 300}),
          tool('t4', 'show', {'view': 'step'}),
          done('tool_use'),
        ])
        ..add([text("Timer's on for five minutes."), done('end_turn')]);
      await session.say('Beans are in the pan.');

      expect(kitchen.log, [
        'stage cook',
        'step 0',
        'start beans 300',
        'show step',
      ]);
      expect(brain.turns[0], {'text': 'Beans are in the pan.'});
      expect(brain.turns[1], {
        'tool_results': [
          {'tool_call_id': 't1', 'content': 'ok'},
          {'tool_call_id': 't2', 'content': 'ok'},
          {'tool_call_id': 't3', 'content': 'timer-1'},
          {'tool_call_id': 't4', 'content': 'ok'},
        ],
      });
      expect(session.state.phase, CookingPhase.ready);
      expect(session.state.stage, Stage.cook);
      expect(session.state.stepIndex, 0);
      expect(session.state.view, ShowView.step);
      expect(
        session.state.reply,
        "Lovely. I'll start a timer. Timer's on for five minutes.",
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        states.map((s) => s.phase),
        containsAllInOrder([
          CookingPhase.thinking,
          CookingPhase.replying,
          CookingPhase.runningTools,
          CookingPhase.thinking,
          CookingPhase.replying,
          CookingPhase.ready,
        ]),
      );

      brain.replies
        ..add([
          text('Cancelled.'),
          tool('t5', 'cancel_timer', {'timer_id': 'timer-1'}),
          done('tool_use'),
        ])
        ..add([
          text('Toast'),
          {'type': 'error', 'message': 'Sou lost the thread there.'},
        ]);
      await session.say("They're bubbling, cancel the timer.");

      expect(kitchen.log.last, 'cancel timer-1');
      expect(session.state.phase, CookingPhase.interrupted);
      expect(session.state.error!.code, 'turn_failed');
      expect(session.state.canSpeak, isTrue);

      brain.replies.add([text('Toast on now.'), done('end_turn')]);
      await session.say('Did you get that?');

      expect(brain.turns.last, {
        'text': 'Did you get that?',
        'tool_results': [
          {'tool_call_id': 't5', 'content': 'ok'},
        ],
      });
      expect(session.state.phase, CookingPhase.ready);
      expect(session.state.error, isNull);
      expect(session.state.reply, 'Toast on now.');

      await session.end(rating: 5, notes: 'More cheese next time.');
      expect(brain.endBody, {'rating': 5, 'notes': 'More cheese next time.'});
      expect(session.state.phase, CookingPhase.ended);
      expect(session.state.ended!.rating, 5);

      expect(spoken.first, startsWith('Right, fake beans'));
      expect(spoken, containsAllInOrder(['Lovely. ', "I'll start a timer."]));

      final transcript = session.state.transcript;
      expect(transcript.map((t) => t.runtimeType), [
        SousTurn,
        CookTurn,
        SousTurn,
        ToolTurn,
        SousTurn,
        CookTurn,
        SousTurn,
        ToolTurn,
        CookTurn,
        SousTurn,
      ]);
      expect((transcript[2] as SousTurn).toolCalls, hasLength(4));
    },
  );

  test('owed results the phone lost go back as errors', () async {
    await session.start('recipe-example-1');
    brain.owed = ['t-old'];
    brain.replies.add([text('Where were we?'), done('end_turn')]);

    await session.say('Hello?');
    expect(session.state.phase, CookingPhase.interrupted);
    expect(session.state.error!.error, BrainError.toolResultsRequired);

    await session.say('Hello?');
    expect(brain.turns.single['tool_results'], [
      {
        'tool_call_id': 't-old',
        'content': 'The phone lost track of this one.',
        'is_error': true,
      },
    ]);
    expect(session.state.phase, CookingPhase.ready);
  });

  test('a reply cut off mid-stream is interrupted, not finished', () async {
    await session.start('recipe-example-1');
    brain.replies.add([text('Half a sente')]);

    await session.say('Next?');
    expect(session.state.phase, CookingPhase.interrupted);
    expect(session.state.error!.error, BrainError.network);
  });

  test('stops after too many tool rounds', () async {
    session = CookingSession(
      brain: BrainClient(
        baseUri: Uri.parse('https://brain.test/sous/api/v1'),
        httpClient: brain.client,
        tokens: FakeTokenSource(),
      ),
      tools: kitchen,
      maxToolRounds: 1,
    );
    await session.start('recipe-example-1');
    brain.replies
      ..add([
        tool('a', 'show', {'view': 'ingredients'}),
        done('tool_use'),
      ])
      ..add([
        tool('b', 'show', {'view': 'step'}),
        done('tool_use'),
      ]);

    await session.say('Show me everything.');
    expect(brain.turns, hasLength(2));
    expect(session.state.phase, CookingPhase.ready);
  });

  test('refuses to talk over Sou', () async {
    await session.start('recipe-example-1');
    final slow = StreamController<List<int>>();
    brain.replies.add(http.StreamedResponse(slow.stream, 200));

    final first = session.say('One');
    await Future<void>.delayed(Duration.zero);
    expect(() => session.say('Two'), throwsStateError);
    expect(() => session.end(), throwsStateError);

    slow.add(utf8.encode(sse(done('end_turn'))));
    await slow.close();
    await first;
    expect(session.state.phase, CookingPhase.ready);
  });

  test('a session the brain already ended fails', () async {
    await session.start('recipe-example-1');
    brain.ended = true;

    await session.say('Still there?');
    expect(session.state.phase, CookingPhase.failed);
    expect(session.state.error!.error, BrainError.sessionEnded);
  });

  test('a session that cannot start fails with the reason', () async {
    brain.startResponse = () =>
        FakeBrain._json({'error': 'live_sessions_unavailable'}, 503);

    await session.start('recipe-example-1');
    expect(session.state.phase, CookingPhase.failed);
    expect(session.state.error!.error, BrainError.unavailable);
  });
}
