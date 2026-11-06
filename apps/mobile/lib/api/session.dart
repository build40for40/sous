import 'json.dart';

/// Rough stages of a cook. Any stage can follow any other.
enum Stage { decide, prep, cook, present, feedback }

/// What `show` puts on screen.
enum ShowView { step, ingredients, doneCue }

Stage stageFromJson(Object? value) =>
    Stage.values.firstWhere((s) => s.name == value);

ShowView showViewFromJson(Object? value) => switch (value) {
  'step' => ShowView.step,
  'ingredients' => ShowView.ingredients,
  'done_cue' => ShowView.doneCue,
  _ => throw FormatException('Unknown view $value'),
};

String showViewToJson(ShowView view) => switch (view) {
  ShowView.step => 'step',
  ShowView.ingredients => 'ingredients',
  ShowView.doneCue => 'done_cue',
};

/// A tool Sou called. The first five run on the phone; [NoteCall] runs in the
/// brain and only shows up in transcripts.
sealed class ToolCall {
  const ToolCall(this.id);

  factory ToolCall.fromJson(Json json) {
    final id = json['id'] as String;
    final input = json['input'] as Json;
    return switch (json['name']) {
      'start_timer' => StartTimerCall(
        id,
        label: input['label'] as String,
        seconds: input['seconds'] as int,
      ),
      'cancel_timer' => CancelTimerCall(
        id,
        timerId: input['timer_id'] as String,
      ),
      'go_to_step' => GoToStepCall(id, index: input['index'] as int),
      'set_stage' => SetStageCall(id, stage: stageFromJson(input['stage'])),
      'show' => ShowCall(id, view: showViewFromJson(input['view'])),
      'note' => NoteCall(id, fact: input['fact'] as String),
      final name => throw FormatException('Unknown tool $name'),
    };
  }

  /// Claude's tool_use id. The result goes back with it.
  final String id;

  String get name;
  Json get input;

  Json toJson() => {'id': id, 'name': name, 'input': input};
}

class StartTimerCall extends ToolCall {
  const StartTimerCall(super.id, {required this.label, required this.seconds});

  final String label;
  final int seconds;

  @override
  String get name => 'start_timer';
  @override
  Json get input => {'label': label, 'seconds': seconds};
}

class CancelTimerCall extends ToolCall {
  const CancelTimerCall(super.id, {required this.timerId});

  /// The id the phone returned from `start_timer`.
  final String timerId;

  @override
  String get name => 'cancel_timer';
  @override
  Json get input => {'timer_id': timerId};
}

class GoToStepCall extends ToolCall {
  const GoToStepCall(super.id, {required this.index});

  /// Zero-based into the recipe's steps.
  final int index;

  @override
  String get name => 'go_to_step';
  @override
  Json get input => {'index': index};
}

class SetStageCall extends ToolCall {
  const SetStageCall(super.id, {required this.stage});

  final Stage stage;

  @override
  String get name => 'set_stage';
  @override
  Json get input => {'stage': stage.name};
}

class ShowCall extends ToolCall {
  const ShowCall(super.id, {required this.view});

  final ShowView view;

  @override
  String get name => 'show';
  @override
  Json get input => {'view': showViewToJson(view)};
}

class NoteCall extends ToolCall {
  const NoteCall(super.id, {required this.fact});

  final String fact;

  @override
  String get name => 'note';
  @override
  Json get input => {'fact': fact};
}

class ToolResult {
  const ToolResult({
    required this.toolCallId,
    required this.content,
    this.isError = false,
  });

  factory ToolResult.fromJson(Json json) => ToolResult(
    toolCallId: json['tool_call_id'] as String,
    content: json['content'] as String,
    isError: json['is_error'] as bool? ?? false,
  );

  final String toolCallId;

  /// For `start_timer`, the new timer's id.
  final String content;
  final bool isError;

  Json toJson() => {
    'tool_call_id': toolCallId,
    'content': content,
    if (isError) 'is_error': true,
  };
}

/// The body of `POST /sessions/:id/turns`: what the cook said, the results
/// owed for the last reply's tool calls, or both.
class TurnRequest {
  TurnRequest({this.text, this.toolResults = const []})
    : assert(
        (text != null && text.isNotEmpty) || toolResults.isNotEmpty,
        'A turn needs text, tool results or both',
      );

  final String? text;
  final List<ToolResult> toolResults;

  Json toJson() => {
    if (text != null && text!.isNotEmpty) 'text': text,
    if (toolResults.isNotEmpty)
      'tool_results': [for (final r in toolResults) r.toJson()],
  };
}

enum StopReason { endTurn, toolUse }

/// One server-sent event from `/turns`.
sealed class StreamEvent {
  const StreamEvent();

  /// Null for an event type this app doesn't know yet.
  static StreamEvent? fromJson(Json json) => switch (json['type']) {
    'text' => TextEvent(json['delta'] as String),
    'tool_call' => ToolCallEvent(ToolCall.fromJson(json['tool_call'] as Json)),
    'done' => DoneEvent(
      json['stop_reason'] == 'tool_use'
          ? StopReason.toolUse
          : StopReason.endTurn,
    ),
    'error' => ErrorEvent(json['message'] as String),
    _ => null,
  };
}

/// The next chunk of Sou's reply.
class TextEvent extends StreamEvent {
  const TextEvent(this.delta);

  final String delta;
}

/// A client tool for the phone to run.
class ToolCallEvent extends StreamEvent {
  const ToolCallEvent(this.toolCall);

  final ToolCall toolCall;
}

/// The reply is finished. [StopReason.toolUse] means results are owed.
class DoneEvent extends StreamEvent {
  const DoneEvent(this.stopReason);

  final StopReason stopReason;
}

/// The turn failed and nothing was saved, so it can be sent again.
class ErrorEvent extends StreamEvent {
  const ErrorEvent(this.message);

  final String message;
}

/// One entry in a session transcript.
sealed class Turn {
  const Turn(this.at);

  factory Turn.fromJson(Json json) {
    final at = DateTime.parse(json['at'] as String);
    return switch (json['role']) {
      'cook' => CookTurn(at, json['text'] as String),
      'sous' => SousTurn(
        at,
        text: json['text'] as String?,
        toolCalls: listOf(json['tool_calls'], ToolCall.fromJson),
      ),
      'tool' => ToolTurn(at, listOf(json['tool_results'], ToolResult.fromJson)),
      final role => throw FormatException('Unknown role $role'),
    };
  }

  final DateTime at;
}

class CookTurn extends Turn {
  const CookTurn(super.at, this.text);

  final String text;
}

class SousTurn extends Turn {
  const SousTurn(super.at, {this.text, this.toolCalls = const []});

  final String? text;
  final List<ToolCall> toolCalls;
}

class ToolTurn extends Turn {
  const ToolTurn(super.at, this.toolResults);

  final List<ToolResult> toolResults;
}

/// What `POST /sessions` returns. Sou's opening line comes straight back.
class StartedSession {
  const StartedSession({
    required this.id,
    required this.recipeId,
    required this.stage,
    required this.startedAt,
    required this.openingLine,
  });

  factory StartedSession.fromJson(Json json) => StartedSession(
    id: json['id'] as String,
    recipeId: json['recipe_id'] as String,
    stage: stageFromJson(json['stage']),
    startedAt: DateTime.parse(json['started_at'] as String),
    openingLine: json['opening_line'] as String,
  );

  final String id;
  final String recipeId;
  final Stage stage;
  final DateTime startedAt;
  final String openingLine;
}

/// What `POST /sessions/:id/end` returns. The reflection runs later.
class EndedSession {
  const EndedSession({
    required this.id,
    required this.endedAt,
    this.rating,
    this.notes,
  });

  factory EndedSession.fromJson(Json json) => EndedSession(
    id: json['id'] as String,
    endedAt: DateTime.parse(json['ended_at'] as String),
    rating: json['rating'] as int?,
    notes: json['notes'] as String?,
  );

  final String id;
  final DateTime endedAt;
  final int? rating;
  final String? notes;
}

/// A contract `Session`: the transcript and what came out of it.
class Session {
  const Session({
    required this.id,
    required this.recipeId,
    required this.stage,
    required this.startedAt,
    this.endedAt,
    required this.turns,
    this.facts = const [],
    this.rating,
    this.notes,
  });

  factory Session.fromJson(Json json) => Session(
    id: json['id'] as String,
    recipeId: json['recipe_id'] as String,
    stage: stageFromJson(json['stage']),
    startedAt: DateTime.parse(json['started_at'] as String),
    endedAt: dateOrNull(json['ended_at']),
    turns: listOf(json['turns'], Turn.fromJson),
    facts: stringsOf(json['facts']),
    rating: json['rating'] as int?,
    notes: json['notes'] as String?,
  );

  final String id;
  final String recipeId;
  final Stage stage;
  final DateTime startedAt;
  final DateTime? endedAt;
  final List<Turn> turns;

  /// Everything Sou saved with `note`.
  final List<String> facts;
  final int? rating;
  final String? notes;
}

enum ReflectionStatus { notEnded, pending, done, failed }

ReflectionStatus reflectionStatusFromJson(Object? value) => switch (value) {
  'not_ended' => ReflectionStatus.notEnded,
  'pending' => ReflectionStatus.pending,
  'done' => ReflectionStatus.done,
  'failed' => ReflectionStatus.failed,
  _ => throw FormatException('Unknown reflection status $value'),
};

/// What Sou learned from one cook.
class Reflection {
  const Reflection({
    this.rating,
    required this.summary,
    this.worked = const [],
    this.failed = const [],
    this.substitutions = const [],
    this.preferences = const [],
    this.ingredients = const [],
    this.techniques = const [],
    this.cuisine,
  });

  factory Reflection.fromJson(Json json) => Reflection(
    rating: json['rating'] as int?,
    summary: json['summary'] as String,
    worked: stringsOf(json['worked']),
    failed: stringsOf(json['failed']),
    substitutions: listOf(json['substitutions'], Substitution.fromJson),
    preferences: stringsOf(json['preferences']),
    ingredients: stringsOf(json['ingredients']),
    techniques: stringsOf(json['techniques']),
    cuisine: json['cuisine'] as String?,
  );

  final int? rating;
  final String summary;
  final List<String> worked;
  final List<String> failed;
  final List<Substitution> substitutions;

  /// New things Sou learned about the cook.
  final List<String> preferences;
  final List<String> ingredients;
  final List<String> techniques;
  final String? cuisine;
}

class Substitution {
  const Substitution({
    required this.original,
    required this.replacement,
    required this.outcome,
  });

  factory Substitution.fromJson(Json json) => Substitution(
    original: json['original'] as String,
    replacement: json['replacement'] as String,
    outcome: json['outcome'] as String,
  );

  final String original;
  final String replacement;
  final String outcome;
}

/// What `GET /sessions/:id` returns.
class SessionView {
  const SessionView({
    required this.session,
    this.reflection,
    required this.reflectionStatus,
    this.reflectedAt,
  });

  factory SessionView.fromJson(Json json) => SessionView(
    session: Session.fromJson(json['session'] as Json),
    reflection: json['reflection'] == null
        ? null
        : Reflection.fromJson(json['reflection'] as Json),
    reflectionStatus: reflectionStatusFromJson(json['reflection_status']),
    reflectedAt: dateOrNull(json['reflected_at']),
  );

  final Session session;

  /// Null until the reflection is done.
  final Reflection? reflection;
  final ReflectionStatus reflectionStatus;
  final DateTime? reflectedAt;
}
