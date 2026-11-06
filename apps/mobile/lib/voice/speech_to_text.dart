import 'dart:typed_data';

sealed class SpeechEvent {
  const SpeechEvent();
}

/// The cook has started talking. Engines only report it once the speech has
/// lasted long enough not to be a clatter or a cough (about 250 ms).
class SpeechStarted extends SpeechEvent {
  const SpeechStarted();
}

/// What the cook has said so far, from engines that can tell mid-sentence.
class PartialTranscript extends SpeechEvent {
  const PartialTranscript(this.text);

  final String text;
}

/// The cook has stopped talking and this is what they said. Empty when the
/// engine heard speech but couldn't make out words.
class FinalTranscript extends SpeechEvent {
  const FinalTranscript(this.text);

  final String text;
}

/// Turns mic audio into finished utterances, and decides when the cook has
/// stopped talking.
abstract interface class SpeechToText {
  /// The sample rate [accept] expects.
  int get sampleRate;

  /// Loads models or opens connections. Call once before [accept].
  Future<void> init();

  Stream<SpeechEvent> get events;

  /// Feeds mic audio at [sampleRate].
  void accept(Float32List samples);

  /// Forgets any half-heard speech.
  void reset();

  Future<void> dispose();
}
