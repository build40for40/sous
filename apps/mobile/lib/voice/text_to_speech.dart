import 'audio_io.dart';

/// Turns one sentence of Sous's reply into audio. Playback and stopping go
/// through [AudioIO], so every engine gets the same echo cancellation.
abstract interface class TextToSpeech {
  /// Loads models or opens connections. Call once before [synthesize].
  Future<void> init();

  /// Renders [text], which is already speech-ready (see `speakable`).
  Future<AudioChunk> synthesize(String text);

  Future<void> dispose();
}
