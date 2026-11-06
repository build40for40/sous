import '../api/json.dart';

/// Where a share is up to, as `workers/extract` reports it.
enum ShareStatus {
  /// Being read and turned into a recipe (usually under a minute).
  reading,

  /// The recipe is in the cook's brain; [Share.recipeId] points at it.
  saved,

  /// The recipe is somewhere Sous can't read ([Share.reason] says where).
  /// The cook can send a screenshot, or share the post again to retry.
  needsScreenshot,

  /// The post has no recipe.
  noRecipe,

  /// A meal-prep plan or several recipes in one post.
  skipped,

  /// A status this version of the app doesn't know.
  unknown;

  static ShareStatus parse(Object? value) => switch (value) {
    'reading' => reading,
    'saved' => saved,
    'needs_screenshot' => needsScreenshot,
    'no_recipe' => noRecipe,
    'skipped' => skipped,
    _ => unknown,
  };

  /// Whether the server will still change it without the cook doing anything.
  bool get isPending => this == reading;
}

/// One thing the cook shared into Sous.
class Share {
  const Share({
    required this.id,
    required this.kind,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.url,
    this.reason,
    this.title,
    this.creator,
    this.recipeId,
    this.sourceUsed,
    this.completeness,
    this.missing = const [],
    this.duplicate = false,
  });

  factory Share.fromJson(Json json) => Share(
    id: json['id'] as String,
    kind: json['kind'] as String? ?? 'link',
    url: json['url'] as String?,
    status: ShareStatus.parse(json['status']),
    reason: json['reason'] as String?,
    title: json['title'] as String?,
    creator: json['creator'] as String?,
    recipeId: json['recipe_id'] as String?,
    sourceUsed: json['source_used'] as String?,
    completeness: json['completeness'] as String?,
    missing: stringsOf(json['missing']),
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
    duplicate: json['duplicate'] == true,
  );

  final String id;

  /// `link` or `screenshot`.
  final String kind;

  /// The post or page, cleaned of tracking. Null for a screenshot on its own.
  final String? url;
  final ShareStatus status;

  /// One short sentence for the cook, e.g. "The recipe is in the comments."
  final String? reason;
  final String? title;

  /// The Instagram account that posted it, without the @.
  final String? creator;

  /// The recipe in the brain, once [status] is [ShareStatus.saved].
  final String? recipeId;

  /// `recipe_page`, `caption` or `screenshot` for a saved recipe.
  final String? sourceUsed;

  /// `complete` or `partial` for a saved recipe.
  final String? completeness;

  /// What the post didn't say, e.g. "quantities for the sauce".
  final List<String> missing;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The cook had already shared this post; nothing new was read.
  final bool duplicate;

  /// Only a link that came back [ShareStatus.needsScreenshot] can be retried
  /// by sharing it again.
  bool get canRetry =>
      status == ShareStatus.needsScreenshot && kind == 'link' && url != null;

  /// The server only takes a screenshot for a share that needs one.
  bool get canAddScreenshot => status == ShareStatus.needsScreenshot;
}
