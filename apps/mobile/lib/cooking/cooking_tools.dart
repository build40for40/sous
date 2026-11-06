import '../api/session.dart';

/// Runs Sou's client tools on the phone. Throw to report a failure: the
/// message goes back to Sou as an error result.
abstract interface class CookingTools {
  /// Starts a countdown and returns its id, which [cancelTimer] gets later.
  Future<String> startTimer(String label, int seconds);

  Future<void> cancelTimer(String timerId);

  /// [index] is zero-based into the recipe's steps.
  Future<void> goToStep(int index);

  Future<void> setStage(Stage stage);

  Future<void> show(ShowView view);
}

/// Runs one call and turns the outcome into the result Sou gets back.
Future<ToolResult> runToolCall(CookingTools tools, ToolCall call) async {
  try {
    final content = switch (call) {
      StartTimerCall(:final label, :final seconds) => await tools.startTimer(
        label,
        seconds,
      ),
      CancelTimerCall(:final timerId) =>
        await tools.cancelTimer(timerId).then((_) => 'ok'),
      GoToStepCall(:final index) =>
        await tools.goToStep(index).then((_) => 'ok'),
      SetStageCall(:final stage) =>
        await tools.setStage(stage).then((_) => 'ok'),
      ShowCall(:final view) => await tools.show(view).then((_) => 'ok'),
      NoteCall() => throw UnsupportedError('note runs in the brain'),
    };
    return ToolResult(toolCallId: call.id, content: content);
  } on Object catch (e) {
    return ToolResult(toolCallId: call.id, content: '$e', isError: true);
  }
}
