import 'json.dart';

/// The cook's `USER.md`: named preferences, free-text "about me", and what
/// Sou learned while cooking.
class Profile {
  const Profile({
    required this.id,
    required this.preferences,
    required this.about,
    this.learned = const [],
    required this.updatedAt,
  });

  factory Profile.fromJson(Json json) => Profile(
    id: json['id'] as String,
    preferences: Map.unmodifiable(json['preferences'] as Map? ?? const {}),
    about: json['about'] as String? ?? '',
    learned: stringsOf(json['learned']),
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );

  /// The WorkOS user id.
  final String id;

  /// Any JSON values, e.g. `{"diet": "vegetarian", "allergies": ["peanuts"]}`.
  final Map<String, Object?> preferences;

  /// The cook's own words. Saving it never touches [learned].
  final String about;

  /// Lessons from "Learned while cooking", as plain strings.
  final List<String> learned;
  final DateTime updatedAt;
}
