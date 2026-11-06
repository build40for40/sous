import 'package:flutter_test/flutter_test.dart';
import 'package:sous/api/session.dart';
import 'package:sous/cooking/cooking_tools.dart';

class RecordingTools implements CookingTools {
  final log = <String>[];

  @override
  Future<String> startTimer(String label, int seconds) async {
    log.add('start $label $seconds');
    return 'timer-1';
  }

  @override
  Future<void> cancelTimer(String timerId) async {
    if (timerId != 'timer-1') throw StateError('No timer $timerId');
    log.add('cancel $timerId');
  }

  @override
  Future<void> goToStep(int index) async => log.add('step $index');

  @override
  Future<void> setStage(Stage stage) async => log.add('stage ${stage.name}');

  @override
  Future<void> show(ShowView view) async => log.add('show ${view.name}');
}

void main() {
  test('runs each client tool and reports its result', () async {
    final tools = RecordingTools();
    final results = [
      for (final call in const [
        StartTimerCall('a', label: 'pasta', seconds: 540),
        CancelTimerCall('b', timerId: 'timer-1'),
        GoToStepCall('c', index: 2),
        SetStageCall('d', stage: Stage.cook),
        ShowCall('e', view: ShowView.doneCue),
      ])
        await runToolCall(tools, call),
    ];

    expect(tools.log, [
      'start pasta 540',
      'cancel timer-1',
      'step 2',
      'stage cook',
      'show doneCue',
    ]);
    expect(results.map((r) => (r.toolCallId, r.content, r.isError)), [
      ('a', 'timer-1', false),
      ('b', 'ok', false),
      ('c', 'ok', false),
      ('d', 'ok', false),
      ('e', 'ok', false),
    ]);
  });

  test('a tool that throws becomes an error result for Sou', () async {
    final result = await runToolCall(
      RecordingTools(),
      const CancelTimerCall('b', timerId: 'timer-9'),
    );

    expect(result.isError, isTrue);
    expect(result.content, contains('No timer timer-9'));
  });
}
