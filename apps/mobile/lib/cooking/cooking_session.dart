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

  /// The turn is sent and Sous hasn't started replying.
  thinking,

  /// Sous's reply is streaming in.
  replying,

  /// Running Sous's tool calls and sending the results back.
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
    this.awaitingAck,
    this.events = const [],
  });

  final CookingPhase phase;
  final String? sessionId;
  final String? recipeId;
  final Stage stage;

  /// The step Sous last moved to, zero-based. Null until it does.
  final int? stepIndex;

  /// What Sous last asked to show. Null until it does.
  final ShowView? view;

  /// Sous's current reply so far, or the last finished one. Speech-ready, so
  /// show amounts from the recipe rather than from here.
  final String reply;

  /// Everything said and done in this session, including the opening line.
  final List<Turn> transcript;
  final BrainException? error;

  /// Set once [CookingSession.end] succeeds.
  final EndedSession? ended;

  /// The instruction from Sous's last reply still waiting for "Heard". Null
  /// when nothing is waiting, and cleared as soon as the cook's next turn
  /// goes.
  final AwaitingAck? awaitingAck;

  /// What happened on the phone since the cook's last turn, such as a timer
  /// finishing. It goes to Sous with the cook's next turn.
  final List<KitchenEvent> events;

  /// Sous has something for the cook and is waiting to be asked.
  bool get needsChef => events.isNotEmpty;

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
    AwaitingAck? awaitingAck,
    bool clearAwaitingAck = false,
    List<KitchenEvent>? events,
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
    awaitingAck: clearAwaitingAck ? null : awaitingAck ?? this.awaitingAck,
    events: events ?? this.events,
  );
}

/// One live cook, headless: starts the session, sends what the cook says,
/// streams Sous's reply, runs Sous's tools through [CookingTools] and sends all
/// their results back together, then ends it.
class CookingSession {
  CookingSession({
    required this._brain,
    required this._tools,
    DateTime Function()? clock,
    this.maxToolRounds = 8,
    this.busyRetryDelays = const [
      Duration(milliseconds: 250),
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 2),
      Duration(seconds: 3),
    ],
  }) : _clock = clock ?? DateTime.now;

  final BrainClient _brain;
  final CookingTools _tools;
  final DateTime Function() _clock;

  /// Stops a reply that keeps asking for tools from looping forever.
  final int maxToolRounds;

  /// How long to wait between tries while the brain is still finishing a
  /// reply that [interrupt] cut off.
  final List<Duration> busyRetryDelays;

  final _states = StreamController<CookingState>.broadcast();
  final _replyText = StreamController<String>.broadcast();
  CookingState _state = const CookingState();
  List<ToolResult> _owed = const [];
  final List<KitchenEvent> _events = [];
  StreamSubscription<StreamEvent>? _reply;
  Completer<Object?>? _replyDone;
  List<ToolCall> _heldCalls = const [];
  var _generation = 0;
  var _stopAfterTools = false;

  CookingState get state => _state;

  /// Every change to [state], starting after the current one.
  Stream<CookingState> get states => _states.stream;

  /// Sous's words as they arrive, opening line included, for speaking aloud.
  Stream<String> get replyText => _replyText.stream;

  /// Starts cooking [recipeId]. Sous's opening line arrives straight away.
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
  /// that didn't get through, and plays out Sous's whole reply.
  ///
  /// When the brain is still finishing a reply that [interrupt] cut off, or
  /// disagrees about which tool results are owed, this waits or fixes the
  /// results and tries again, so the cook's words aren't lost.
  Future<void> say(String text) {
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'is empty');
    }
    return send(text: text);
  }

  /// Opens a turn for the cook: [text] if they said anything, with every
  /// [KitchenEvent] since their last turn. A tap on the flame with nothing
  /// said sends just the events.
  Future<void> send({String? text}) {
    final trimmed = text?.trim();
    final words = trimmed == null || trimmed.isEmpty ? null : trimmed;
    if (words == null && _events.isEmpty) {
      throw ArgumentError('A turn needs words or kitchen events');
    }
    if (!_state.canSpeak) {
      throw StateError('Sous is busy (${_state.phase.name})');
    }
    return _converse(
      TurnRequest(text: words, toolResults: _owed, events: List.of(_events)),
    );
  }

  /// Something on the phone needs the cook, like a timer finishing. Sous
  /// doesn't speak first: it goes with the cook's next turn, and
  /// [CookingState.needsChef] is true until then.
  void notify(KitchenEvent event) {
    _events.add(event);
    if (_events.length > TurnRequest.maxEvents) _events.removeAt(0);
    _emit(_state.copyWith(events: List.unmodifiable(_events)));
  }

  /// Cuts Sous's reply off, for when the cook talks over Sous or taps to stop.
  ///
  /// A reply still streaming stops at once and the session is ready for the
  /// cook again. Tool calls in it that never ran go back to Sous as skipped. If
  /// Sous's tools are already running they finish first, and their results go
  /// with whatever the cook says next. Does nothing when Sous isn't replying.
  void interrupt() {
    switch (_state.phase) {
      case CookingPhase.thinking || CookingPhase.replying:
        _generation++;
        unawaited(_reply?.cancel());
        _reply = null;
        final cut = _replyDone;
        _replyDone = null;
        if (cut != null && !cut.isCompleted) cut.complete(null);
        _owed = [
          for (final call in _heldCalls)
            ToolResult(
              toolCallId: call.id,
              content: 'Skipped: the cook interrupted before this ran.',
              isError: true,
            ),
        ];
        _heldCalls = const [];
        _emit(_state.copyWith(phase: CookingPhase.ready, clearError: true));
      case CookingPhase.runningTools:
        _stopAfterTools = true;
      default:
        break;
    }
  }

  /// Ends the cook with an optional rating (1 to 5) and notes. Sous reflects on
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
    final generation = _generation;
    _stopAfterTools = false;
    var request = first;
    for (var round = 0; ; round++) {
      final calls = await _send(request, generation);
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
      if (_stopAfterTools) {
        _stopAfterTools = false;
        _emit(_state.copyWith(phase: CookingPhase.ready));
        return;
      }
      request = TurnRequest(toolResults: results);
    }
  }

  /// [_turn], retried when the brain turns the request away before replying:
  /// still busy with a reply the cook cut off, or owed different tool results.
  Future<List<ToolCall>?> _send(TurnRequest first, int generation) async {
    var request = first;
    var busyTries = 0;
    var fixedResults = false;
    while (true) {
      final outcome = await _turn(request, generation);
      if (outcome is! _Rejected) return outcome as List<ToolCall>?;
      final e = outcome.error;
      if (e.error == BrainError.turnInProgress &&
          busyTries < busyRetryDelays.length) {
        await Future<void>.delayed(busyRetryDelays[busyTries++]);
        if (generation != _generation) return null;
        continue;
      }
      if (!fixedResults && request.fromChef) {
        if (e.error == BrainError.toolResultsRequired) {
          fixedResults = true;
          _owe(e.toolCallIds);
          request = TurnRequest(
            text: request.text,
            toolResults: _owed,
            events: request.events,
          );
          continue;
        }
        if (e.code == 'unexpected_tool_results') {
          fixedResults = true;
          _owed = const [];
          request = TurnRequest(text: request.text, events: request.events);
          continue;
        }
      }
      return _interrupted(e);
    }
  }

  /// Streams one turn. Returns the client tool calls owed when the reply
  /// stopped for tools, an empty list when it simply finished, null when the
  /// turn didn't get through or was interrupted, or [_Rejected] when the brain
  /// refused it before replying.
  Future<Object?> _turn(TurnRequest request, int generation) async {
    _emit(
      _state.copyWith(
        phase: CookingPhase.thinking,
        reply: request.fromChef ? '' : null,
        clearError: true,
        clearAwaitingAck: true,
      ),
    );
    final sentAt = _clock().toUtc();
    final calls = <ToolCall>[];
    _heldCalls = calls;
    final text = StringBuffer(request.fromChef ? '' : _state.reply);
    final replyStart = text.length;
    var needsSpace = text.isNotEmpty && !_state.reply.endsWith(' ');
    var heard = false;
    final done = Completer<Object?>();
    _replyDone = done;

    void finish(Object? outcome) {
      if (done.isCompleted) return;
      done.complete(outcome);
      unawaited(_reply?.cancel());
    }

    _reply = _brain
        .takeTurn(_state.sessionId!, request)
        .listen(
          (event) {
            if (done.isCompleted) return;
            heard = true;
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
              case DoneEvent(:final stopReason, :final awaitingAck):
                _owed = const [];
                _events.removeWhere(request.events.contains);
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
                    awaitingAck: stopReason == StopReason.endTurn
                        ? awaitingAck
                        : null,
                    events: List.unmodifiable(_events),
                  ),
                );
                finish(
                  stopReason == StopReason.toolUse ? calls : const <ToolCall>[],
                );
              case ErrorEvent(:final message):
                finish(
                  _interrupted(
                    BrainException(
                      BrainError.retryable,
                      code: 'turn_failed',
                      details: {'message': message},
                    ),
                  ),
                );
            }
          },
          onError: (Object e, StackTrace stack) {
            if (done.isCompleted) return;
            if (e is BrainException) {
              finish(heard ? _interrupted(e) : _Rejected(e));
            } else {
              done.completeError(e, stack);
            }
          },
          onDone: () {
            if (done.isCompleted) return;
            finish(
              _interrupted(
                const BrainException(BrainError.network, code: 'stream_ended'),
              ),
            );
          },
        );

    final outcome = await done.future;
    if (generation == _generation) {
      _reply = null;
      _replyDone = null;
      _heldCalls = const [];
    }
    return outcome;
  }

  void _owe(List<String> ids) {
    final have = {for (final r in _owed) r.toolCallId: r};
    _owed = [
      for (final id in ids)
        have[id] ??
            ToolResult(
              toolCallId: id,
              content: 'The phone lost track of this one.',
              isError: true,
            ),
    ];
  }

  Null _interrupted(BrainException e) {
    if (e.error == BrainError.toolResultsRequired) _owe(e.toolCallIds);
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

/// The brain turned a request away before replying to it.
class _Rejected {
  const _Rejected(this.error);

  final BrainException error;
}
