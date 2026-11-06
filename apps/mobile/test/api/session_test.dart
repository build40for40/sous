import 'package:flutter_test/flutter_test.dart';
import 'package:sous/api/session.dart';

import '../support/fakes.dart';

void main() {
  test('reads the contract example session transcript', () {
    final session = Session.fromJson(contractExample('session.json'));

    expect(session.stage, Stage.feedback);
    expect(session.rating, 5);
    expect(session.facts, ['Likes lots of black pepper']);
    expect(session.turns.first, isA<CookTurn>());

    final calls = session.turns
        .whereType<SousTurn>()
        .expand((t) => t.toolCalls)
        .toList();
    expect(calls.map((c) => c.runtimeType).toSet(), {
      SetStageCall,
      ShowCall,
      GoToStepCall,
      StartTimerCall,
      NoteCall,
      CancelTimerCall,
    });
    final timer = calls.whereType<StartTimerCall>().single;
    expect((timer.label, timer.seconds), ('beans', 300));
    expect(calls.whereType<ShowCall>().single.view, ShowView.ingredients);

    final results = session.turns.whereType<ToolTurn>().first.toolResults;
    expect(results.map((r) => r.toolCallId), [
      'toolu_fake_01',
      'toolu_fake_02',
    ]);
  });

  test('tool calls round-trip to the contract JSON', () {
    for (final json in [
      {
        'id': 'a',
        'name': 'start_timer',
        'input': {'label': 'pasta', 'seconds': 540},
      },
      {
        'id': 'b',
        'name': 'cancel_timer',
        'input': {'timer_id': 'timer-1'},
      },
      {
        'id': 'c',
        'name': 'go_to_step',
        'input': {'index': 2},
      },
      {
        'id': 'd',
        'name': 'set_stage',
        'input': {'stage': 'present'},
      },
      {
        'id': 'e',
        'name': 'show',
        'input': {'view': 'done_cue'},
      },
      {
        'id': 'f',
        'name': 'note',
        'input': {'fact': 'hates coriander'},
      },
    ]) {
      expect(ToolCall.fromJson(json).toJson(), json);
    }
  });

  test('turn requests carry text, results or both', () {
    expect(TurnRequest(text: 'next step').toJson(), {'text': 'next step'});
    expect(
      TurnRequest(
        text: 'done',
        toolResults: const [
          ToolResult(toolCallId: 'a', content: 'timer-1'),
          ToolResult(toolCallId: 'b', content: 'no timer', isError: true),
        ],
      ).toJson(),
      {
        'text': 'done',
        'tool_results': [
          {'tool_call_id': 'a', 'content': 'timer-1'},
          {'tool_call_id': 'b', 'content': 'no timer', 'is_error': true},
        ],
      },
    );
  });

  test('reads every stream event and skips unknown ones', () {
    expect(
      (StreamEvent.fromJson({
        'type': 'text',
        'delta': 'Hi',
      }) as TextEvent).delta,
      'Hi',
    );
    final call = StreamEvent.fromJson({
      'type': 'tool_call',
      'tool_call': {
        'id': 'a',
        'name': 'show',
        'input': {'view': 'step'},
      },
    }) as ToolCallEvent;
    expect((call.toolCall as ShowCall).view, ShowView.step);
    expect(
      (StreamEvent.fromJson({
        'type': 'done',
        'stop_reason': 'tool_use',
      }) as DoneEvent).stopReason,
      StopReason.toolUse,
    );
    expect(
      (StreamEvent.fromJson({
        'type': 'error',
        'message': 'Oops',
      }) as ErrorEvent).message,
      'Oops',
    );
    expect(StreamEvent.fromJson({'type': 'ping'}), isNull);
  });

  test('reads a session view with its reflection', () {
    final view = SessionView.fromJson({
      'session': contractExample('session.json'),
      'reflection': {
        'rating': 5,
        'summary': 'Quick beans, loved it.',
        'worked': ['timing'],
        'failed': [],
        'substitutions': [
          {'original': 'butter', 'replacement': 'olive oil', 'outcome': 'fine'},
        ],
        'preferences': ['likes pepper'],
        'ingredients': ['baked beans'],
        'techniques': ['toasting'],
        'cuisine': 'british',
        'note': 'sessions/2026-11-06-fake.md',
      },
      'reflection_status': 'done',
      'reflected_at': '2026-11-06T18:20:00Z',
    });

    expect(view.reflectionStatus, ReflectionStatus.done);
    expect(view.reflection!.substitutions.single.replacement, 'olive oil');
    expect(view.reflection!.cuisine, 'british');
  });

  test('reads started and ended sessions', () {
    final started = StartedSession.fromJson({
      'id': 's1',
      'recipe_id': 'r1',
      'stage': 'decide',
      'started_at': '2026-11-06T18:00:00Z',
      'opening_line': 'Right, beans on toast.',
    });
    expect(started.stage, Stage.decide);

    final ended = EndedSession.fromJson({
      'id': 's1',
      'ended_at': '2026-11-06T18:12:00Z',
      'rating': 4,
      'reflection_status': 'pending',
    });
    expect(ended.rating, 4);
    expect(ended.notes, isNull);
  });
}
