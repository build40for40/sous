import 'json.dart';

/// A recipe, as `packages/contracts/schemas/recipe.schema.json` defines it.
class Recipe {
  const Recipe({
    this.id,
    this.slug,
    required this.title,
    this.sourceUrl,
    this.servings,
    this.times,
    required this.ingredients,
    required this.steps,
    this.createdAt,
    this.updatedAt,
  });

  factory Recipe.fromJson(Json json) => Recipe(
    id: json['id'] as String?,
    slug: json['slug'] as String?,
    title: json['title'] as String,
    sourceUrl: json['source_url'] as String?,
    servings: json['servings'] as int?,
    times: json['times'] == null
        ? null
        : RecipeTimes.fromJson(json['times'] as Json),
    ingredients: listOf(json['ingredients'], Ingredient.fromJson),
    steps: listOf(json['steps'], RecipeStep.fromJson),
    createdAt: dateOrNull(json['created_at']),
    updatedAt: dateOrNull(json['updated_at']),
  );

  /// Set by the brain when the recipe is saved.
  final String? id;
  final String? slug;
  final String title;

  /// Usually the Instagram post.
  final String? sourceUrl;
  final int? servings;
  final RecipeTimes? times;
  final List<Ingredient> ingredients;

  /// In cooking order. `go_to_step` indexes into this list from zero.
  final List<RecipeStep> steps;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// The body for `POST /recipes`: the brain sets the id, slug and dates.
  Json toJson() => {
    'title': title,
    'source_url': ?sourceUrl,
    'servings': ?servings,
    'times': ?times?.toJson(),
    'ingredients': [for (final i in ingredients) i.toJson()],
    'steps': [for (final s in steps) s.toJson()],
  };
}

class RecipeTimes {
  const RecipeTimes({this.prepMinutes, this.cookMinutes, this.totalMinutes});

  factory RecipeTimes.fromJson(Json json) => RecipeTimes(
    prepMinutes: json['prep_minutes'] as int?,
    cookMinutes: json['cook_minutes'] as int?,
    totalMinutes: json['total_minutes'] as int?,
  );

  final int? prepMinutes;
  final int? cookMinutes;
  final int? totalMinutes;

  Json toJson() => {
    'prep_minutes': ?prepMinutes,
    'cook_minutes': ?cookMinutes,
    'total_minutes': ?totalMinutes,
  };
}

class Ingredient {
  const Ingredient({required this.name, this.quantity, this.unit, this.note});

  factory Ingredient.fromJson(Json json) => Ingredient(
    name: json['name'] as String,
    quantity: (json['quantity'] as num?)?.toDouble(),
    unit: json['unit'] as String?,
    note: json['note'] as String?,
  );

  final String name;

  /// 0.5 for half. Null for "to taste" or "a pinch".
  final double? quantity;
  final String? unit;

  /// e.g. "finely sliced".
  final String? note;

  Json toJson() => {
    'name': name,
    'quantity': ?quantity,
    'unit': ?unit,
    'note': ?note,
  };
}

class RecipeStep {
  const RecipeStep({required this.text, this.doneCue, this.durationSeconds});

  factory RecipeStep.fromJson(Json json) => RecipeStep(
    text: json['text'] as String,
    doneCue: json['done_cue'] as String?,
    durationSeconds: json['duration_seconds'] as int?,
  );

  /// Written to be read aloud.
  final String text;

  /// What done looks, smells or sounds like.
  final String? doneCue;
  final int? durationSeconds;

  Json toJson() => {
    'text': text,
    'done_cue': ?doneCue,
    'duration_seconds': ?durationSeconds,
  };
}
