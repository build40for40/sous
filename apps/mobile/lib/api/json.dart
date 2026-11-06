typedef Json = Map<String, Object?>;

List<T> listOf<T>(Object? value, T Function(Json) parse) => [
  for (final item in (value as List? ?? const [])) parse(item as Json),
];

List<String> stringsOf(Object? value) => [
  for (final item in (value as List? ?? const [])) item as String,
];

DateTime? dateOrNull(Object? value) =>
    value is String ? DateTime.parse(value) : null;
