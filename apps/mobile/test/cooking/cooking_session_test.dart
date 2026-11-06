import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sous/api/brain_client.dart';
import 'package:sous/api/brain_exception.dart';
import 'package:sous/api/session.dart';
import 'package:sous/cooking/cooking_session.dart';

import '../support/fake_brain.dart';
import '../support/fakes.dart';

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
    expect(brain.turns.single['text'], 'Hello?');
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
        FakeBrain.json({'error': 'live_sessions_unavailable'}, 503);

    await session.start('recipe-example-1');
    expect(session.state.phase, CookingPhase.failed);
    expect(session.state.error!.error, BrainError.unavailable);
  });

  group('interrupt', () {
    setUp(() {
      session = CookingSession(
        brain: brain.brainClient,
        tools: kitchen,
        busyRetryDelays: const [Duration.zero, Duration.zero, Duration.zero],
      );
    });

    test('cuts a streaming reply off and the next turn waits for the brain '
        'to finish it', () async {
      await session.start('recipe-example-1');
      final slow = SlowReply();
      brain.replies.add(slow.response);

      final first = session.say('What next?');
      slow.send(text('First, chop the onions. Then'));
      await pumpEventQueue();
      expect(session.state.phase, CookingPhase.replying);

      session.interrupt();
      expect(session.state.phase, CookingPhase.ready);
      expect(session.state.canSpeak, isTrue);
      await first;
      slow.send(text(' never heard.'));
      await pumpEventQueue();
      expect(session.state.reply, 'First, chop the onions. Then');

      brain.busy = 2;
      brain.replies.add([text('Sure, garlic instead.'), done('end_turn')]);
      await session.say('Actually, garlic first.');

      expect(brain.turns.last, {'text': 'Actually, garlic first.'});
      expect(session.state.phase, CookingPhase.ready);
      expect(session.state.reply, 'Sure, garlic instead.');
      await slow.close();
    });

    test('tool calls cut off before they ran go back as skipped', () async {
      await session.start('recipe-example-1');
      final slow = SlowReply();
      brain.replies.add(slow.response);

      final first = session.say('Set a timer.');
      slow.send(text('Timer on.'));
      slow.send(tool('t1', 'start_timer', {'label': 'rice', 'seconds': 600}));
      await pumpEventQueue();
      session.interrupt();
      await first;
      expect(kitchen.log, isEmpty);

      brain.owed = ['t1'];
      brain.replies.add([text('No timer then.'), done('end_turn')]);
      await session.say('Never mind.');

      expect(brain.turns.last, {
        'text': 'Never mind.',
        'tool_results': [
          {
            'tool_call_id': 't1',
            'content': 'Skipped: the cook interrupted before this ran.',
            'is_error': true,
          },
        ],
      });
      await slow.close();
    });

    test(
      'while tools run, they finish and their results wait for the cook',
      () async {
        await session.start('recipe-example-1');
        kitchen.gate = Completer<void>();
        brain.replies.add([
          tool('t1', 'start_timer', {'label': 'rice', 'seconds': 600}),
          done('tool_use'),
        ]);

        final first = session.say('Rice timer please.');
        await pumpEventQueue();
        expect(session.state.phase, CookingPhase.runningTools);

        session.interrupt();
        kitchen.gate!.complete();
        await first;
        expect(kitchen.log, ['start rice 600']);
        expect(brain.turns, hasLength(1));
        expect(session.state.phase, CookingPhase.ready);

        brain.replies.add([text('Ten minutes, rice.'), done('end_turn')]);
        await session.say('Thanks.');
        expect(brain.turns.last, {
          'text': 'Thanks.',
          'tool_results': [
            {'tool_call_id': 't1', 'content': 'timer-1'},
          ],
        });
      },
    );

    test('does nothing when Sou is not replying', () async {
      await session.start('recipe-example-1');
      session.interrupt();
      expect(session.state.phase, CookingPhase.ready);
    });

    test('gives up when the brain stays busy', () async {
      await session.start('recipe-example-1');
      brain.busy = 10;
      await session.say('Hello?');
      expect(session.state.phase, CookingPhase.interrupted);
      expect(session.state.error!.error, BrainError.turnInProgress);
    });
  });

  group('kitchen protocol', () {
    test('keeps what is awaiting "Heard" until the chef speaks', () async {
      await session.start('recipe-example-1');
      brain.replies
        ..add([
          text('Chef, twelve minutes. Set it?'),
          {
            'type': 'done',
            'stop_reason': 'end_turn',
            'awaiting_ack': {'short': 'Chef, rice timer. Heard?'},
          },
        ])
        ..add([done('end_turn')]);
      await session.say('Rice is in.');
      expect(session.state.awaitingAck?.short, 'Chef, rice timer. Heard?');

      await session.say('Heard.');
      expect(session.state.awaitingAck, isNull);
      expect(session.state.reply, isEmpty);
      expect(spoken.skip(1).join(), 'Chef, twelve minutes. Set it?');
    });

    test('queues kitchen events and sends them with the next turn, even '
        'without words', () async {
      await session.start('recipe-example-1');
      session
        ..notify(const TimerFinished(timerId: 'timer-1', label: 'rice'))
        ..notify(const TimerFinished(timerId: 'timer-2', label: 'dahl'));
      expect(session.state.needsChef, isTrue);

      brain.replies.add([text('Chef, the rice is done.'), done('end_turn')]);
      await session.send();
      expect(brain.turns.single, {
        'events': [
          {'type': 'timer_finished', 'timer_id': 'timer-1', 'label': 'rice'},
          {'type': 'timer_finished', 'timer_id': 'timer-2', 'label': 'dahl'},
        ],
      });
      expect(session.state.needsChef, isFalse);
      expect(() => session.send(), throwsArgumentError);
    });

    test('keeps the events when the turn does not get through', () async {
      await session.start('recipe-example-1');
      session.notify(const TimerFinished(timerId: 'timer-1', label: 'rice'));
      brain.replies.add([
        {'type': 'error', 'message': 'Fake outage.'},
      ]);
      await session.send(text: 'What now?');
      expect(session.state.needsChef, isTrue);
    });
  });
}
