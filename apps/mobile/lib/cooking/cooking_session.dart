import 'dart:async';

import '../api/brain_client.dart';
import '../api/brain_exception.dart';
import '../api/session.dart';
import 'cooking_tools.dart';

enum CookingPhase {
  notStarted,
  starting,

  /// Waiting for the cook to say something.
  ready,

  /// The turn is sent and Sou hasn't started replying.
  thinking,

  /// Sou's reply is streaming in.
  replying,

  /// Running Sou's tool calls and sending the results back.
  runningTools,

  /// The last turn didn't get through. Nothing was lost: the cook can just
  /// say it again. [CookingState.error] says why.
  interrupted,
  ending,
  ended,

  /// The session can't go on: it never started, or the brain says it's over.
  failed,
}

class CookingState {
  const CookingState({
    this.phase = CookingPhase.notStarted,
    this.sessionId,
    this.recipeId,
    this.stage = Stage.decide,
    this.stepIndex,
    this.view,
    this.reply = '',
    this.transcript = const [],
    this.error,
    this.ended,
  });

  final CookingPhase phase;
  final String? sessionId;
  final String? recipeId;
  final Stage stage;

  /// The step Sou last moved to, zero-based. Null until it does.
  final int? stepIndex;

  /// What Sou last asked to show. Null until it does.
  final ShowView? view;

  /// Sou's current reply so far, or the last finished one. Speech-ready, so
  /// show amounts from the recipe rather than from here.
  final String reply;

  /// Everything said and done in this session, including the opening line.
  final List<Turn> transcript;
  final BrainException? error;

  /// Set once [CookingSession.end] succeeds.
  final EndedSession? ended;

  bool get canSpeak =>
      phase == CookingPhase.ready || phase == CookingPhase.interrupted;

  CookingState copyWith({
    CookingPhase? phase,
    String? sessionId,
    String? recipeId,
    Stage? stage,
    int? stepIndex,
    ShowView? view,
    String? reply,
    List<Turn>? transcript,
    BrainException? error,
    bool clearError = false,
    EndedSession? ended,
  }) => CookingState(
    phase: phase ?? this.phase,
    sessionId: sessionId ?? this.sessionId,
    recipeId: recipeId ?? this.recipeId,
    stage: stage ?? this.stage,
    stepIndex: stepIndex ?? this.stepIndex,
    view: view ?? this.view,
    reply: reply ?? this.reply,
    transcript: transcript ?? this.transcript,
    error: clearError ? null : error ?? this.error,
    ended: ended ?? this.ended,
  );
}

/// One live cook, headless: starts the session, sends what the cook says,
/// streams Sou's reply, runs Sou's tools through [CookingTools] and sends all
/// their results back together, then ends it.
class CookingSession {
  CookingSession({
    required this._brain,
    required this._tools,
    DateTime Function()? clock,
    this.maxToolRounds = 8,
  }) : _clock = clock ?? DateTime.now;

  final BrainClient _brain;
  final CookingTools _tools;
  final DateTime Function() _clock;

  /// Stops a reply that keeps asking for tools from looping forever.
  final int maxToolRounds;

  final _states = StreamController<CookingState>.broadcast();
  final _replyText = StreamController<String>.broadcast();
  CookingState _state = const CookingState();
  List<ToolResult> _owed = const [];

  CookingState get state => _state;

  /// Every change to [state], starting after the current one.
  Stream<CookingState> get states => _states.stream;

  /// Sou's words as they arrive, opening line included, for speaking aloud.
  Stream<String> get replyText => _replyText.stream;

  /// Starts cooking [recipeId]. Sou's opening line arrives straight away.
  Future<void> start(String recipeId) async {
    if (_state.phase != CookingPhase.notStarted &&
        _state.phase != CookingPhase.failed) {
      throw StateError('This session has already started');
    }
    _emit(CookingState(phase: CookingPhase.starting, recipeId: recipeId));
    try {
      final started = await _brain.startSession(recipeId);
      _emit(
        _state.copyWith(
          phase: CookingPhase.ready,
          sessionId: started.id,
          stage: started.stage,
          reply: started.openingLine,
          transcript: [SousTurn(started.startedAt, text: started.openingLine)],
        ),
      );
      if (!_replyText.isClosed) _replyText.add(started.openingLine);
    } on BrainException catch (e) {
      _emit(_state.copyWith(phase: CookingPhase.failed, error: e));
    }
  }

  /// Sends what the cook said, plus any tool results still owed from a turn
  /// that didn't get through, and plays out Sou's whole reply.
  Future<void> say(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(text, 'text', 'is empty');
    if (!_state.canSpeak) {
      throw StateError('Sou is busy (${_state.phase.name})');
    }
    return _converse(TurnRequest(text: trimmed, toolResults: _owed));
  }

  /// Ends the cook with an optional rating (1 to 5) and notes. Sou reflects on
  /// it in the background.
  Future<void> end({int? rating, String? notes}) async {
    if (!_state.canSpeak) {
      throw StateError('Can\'t end now (${_state.phase.name})');
    }
    final before = _state.phase;
    _emit(_state.copyWith(phase: CookingPhase.ending, clearError: true));
    try {
      final ended = await _brain.endSession(
        _state.sessionId!,
        rating: rating,
        notes: notes,
      );
      _emit(_state.copyWith(phase: CookingPhase.ended, ended: ended));
    } on BrainException catch (e) {
      _emit(
        _state.copyWith(
          phase: e.error == BrainError.sessionEnded
              ? CookingPhase.ended
              : before,
          error: e,
        ),
      );
    }
  }

  Future<void> _converse(TurnRequest first) async {
    var request = first;
    for (var round = 0; ; round++) {
      final calls = await _turn(request);
      if (calls == null) return;
      if (calls.isEmpty || round >= maxToolRounds) {
        _emit(_state.copyWith(phase: CookingPhase.ready));
        return;
      }

      _emit(_state.copyWith(phase: CookingPhase.runningTools));
      final results = <ToolResult>[];
      for (final call in calls) {
        final result = await runToolCall(_tools, call);
        results.add(result);
        if (!result.isError) _reflect(call);
      }
      _owed = results;
      request = TurnRequest(toolResults: results);
    }
  }

  /// Streams one turn. Returns the client tool calls owed when the reply
  /// stopped for tools, an empty list when it simply finished, or null when
  /// the turn didn't get through.
  Future<List<ToolCall>?> _turn(TurnRequest request) async {
    _emit(
      _state.copyWith(
        phase: CookingPhase.thinking,
        reply: request.text == null ? null : '',
        clearError: true,
      ),
    );
    final sentAt = _clock().toUtc();
    final calls = <ToolCall>[];
    final text = StringBuffer(request.text == null ? _state.reply : '');
    final replyStart = text.length;
    var needsSpace = text.isNotEmpty && !_state.reply.endsWith(' ');

    try {
      await for (final event in _brain.takeTurn(_state.sessionId!, request)) {
        switch (event) {
          case TextEvent(:final delta):
            if (needsSpace && delta.isNotEmpty) {
              text.write(' ');
              needsSpace = false;
            }
            text.write(delta);
            if (!_replyText.isClosed) _replyText.add(delta);
            _emit(
              _state.copyWith(
                phase: CookingPhase.replying,
                reply: text.toString(),
              ),
            );
          case ToolCallEvent(:final toolCall):
            calls.add(toolCall);
          case DoneEvent(:final stopReason):
            _owed = const [];
            final said = text.toString().substring(replyStart).trimLeft();
            _emit(
              _state.copyWith(
                transcript: [
                  ..._state.transcript,
                  if (request.toolResults.isNotEmpty)
                    ToolTurn(sentAt, request.toolResults),
                  if (request.text != null) CookTurn(sentAt, request.text!),
                  if (said.isNotEmpty || calls.isNotEmpty)
                    SousTurn(
                      _clock().toUtc(),
                      text: said.isEmpty ? null : said,
                      toolCalls: List.unmodifiable(calls),
                    ),
                ],
              ),
            );
            return stopReason == StopReason.toolUse ? calls : const [];
          case ErrorEvent(:final message):
            return _interrupted(
              BrainException(
                BrainError.retryable,
                code: 'turn_failed',
                details: {'message': message},
              ),
            );
        }
      }
      return _interrupted(
        const BrainException(BrainError.network, code: 'stream_ended'),
      );
    } on BrainException catch (e) {
      return _interrupted(e);
    }
  }

  Null _interrupted(BrainException e) {
    if (e.error == BrainError.toolResultsRequired) {
      final have = {for (final r in _owed) r.toolCallId: r};
      _owed = [
        for (final id in e.toolCallIds)
          have[id] ??
              ToolResult(
                toolCallId: id,
                content: 'The phone lost track of this one.',
                isError: true,
              ),
      ];
    }
    final over = e.error == BrainError.sessionEnded;
    _emit(
      _state.copyWith(
        phase: over ? CookingPhase.failed : CookingPhase.interrupted,
        error: e,
      ),
    );
    return null;
  }

  void _reflect(ToolCall call) {
    switch (call) {
      case GoToStepCall(:final index):
        _emit(_state.copyWith(stepIndex: index));
      case SetStageCall(:final stage):
        _emit(_state.copyWith(stage: stage));
      case ShowCall(:final view):
        _emit(_state.copyWith(view: view));
      case StartTimerCall() || CancelTimerCall() || NoteCall():
        break;
    }
  }

  void _emit(CookingState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }

  Future<void> dispose() async {
    await _states.close();
    await _replyText.close();
  }
}
