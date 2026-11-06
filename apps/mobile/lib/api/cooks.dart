import 'json.dart';
import 'session.dart';

/// One finished cook in `GET /history`.
class Cook {
  const Cook({
    required this.sessionId,
    this.recipeId,
    this.recipeTitle,
    required this.startedAt,
    required this.endedAt,
    required this.date,
    this.rating,
    this.summary,
    required this.reflectionStatus,
  });

  factory Cook.fromJson(Json json) => Cook(
    sessionId: json['session_id'] as String,
    recipeId: json['recipe_id'] as String?,
    recipeTitle: json['recipe_title'] as String?,
    startedAt: DateTime.parse(json['started_at'] as String),
    endedAt: DateTime.parse(json['ended_at'] as String),
    date: json['date'] as String,
    rating: json['rating'] as int?,
    summary: json['summary'] as String?,
    reflectionStatus: reflectionStatusFromJson(json['reflection_status']),
  );

  final String sessionId;
  final String? recipeId;

  /// Null if the recipe has been deleted since.
  final String? recipeTitle;
  final DateTime startedAt;
  final DateTime endedAt;

  /// The London day, `YYYY-MM-DD`.
  final String date;
  final int? rating;
  final String? summary;

  /// [ReflectionStatus.pending], [ReflectionStatus.done] or
  /// [ReflectionStatus.failed].
  final ReflectionStatus reflectionStatus;
}

/// One answer to "what should I cook?".
class Suggestion {
  const Suggestion({
    required this.recipeId,
    required this.title,
    required this.reason,
  });

  factory Suggestion.fromJson(Json json) => Suggestion(
    recipeId: json['recipe_id'] as String,
    title: json['title'] as String,
    reason: json['reason'] as String,
  );

  final String recipeId;
  final String title;

  /// One line on why.
  final String reason;
}
