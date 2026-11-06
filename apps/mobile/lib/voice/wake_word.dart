import 'dart:typed_data';

/// Listens to the mic for "Hey Sous" and its close variants ("Hey Sue",
/// "Hey Sue Chef"). Nothing else opens a turn.
abstract interface class WakeWord {
  /// The sample rate [accept] expects.
  int get sampleRate;

  /// Loads models. Call once before [accept].
  Future<void> init();

  /// Fires each time the wake word is heard.
  Stream<void> get heard;

  /// Feeds mic audio at [sampleRate].
  void accept(Float32List samples);

  /// Forgets any half-heard audio.
  void reset();

  Future<void> dispose();
}

final _wakePhrase = RegExp(
  r"\b(?:hey|hay)[\s,.!?]+(?:sous|sioux|suze|sue|soo|sou|su|zoo)"
  r"(?:[\s,.!?-]+chef)?\b[\s,.!?]*",
  caseSensitive: false,
);

/// What the chef said after "Hey Sous" in [transcript]: the words, an empty
/// string when they said only the wake word, or null when it isn't there.
String? afterWakePhrase(String transcript) {
  final match = _wakePhrase.firstMatch(transcript);
  return match == null ? null : transcript.substring(match.end).trim();
}
