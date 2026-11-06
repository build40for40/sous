import 'dart:typed_data';

/// Mono audio as floats between -1 and 1.
class AudioChunk {
  const AudioChunk(this.samples, this.sampleRate);

  final Float32List samples;
  final int sampleRate;

  Duration get duration =>
      Duration(microseconds: samples.length * 1000000 ~/ sampleRate);
}

/// The phone's mic and speaker, shared by every speech engine.
abstract interface class AudioIO {
  /// Asks for the microphone if needed. False when the cook said no.
  Future<bool> requestPermission();

  /// Starts the mic and streams mono samples at [sampleRate]. With
  /// [echoCancel], capture goes through the platform's voice-processing path
  /// so Sous's own voice is taken out of what the mic hears.
  Future<Stream<Float32List>> startCapture({
    required int sampleRate,
    required bool echoCancel,
  });

  Future<void> stopCapture();

  /// Plays [chunk] and completes when it has finished or [stopPlayback] cut
  /// it off.
  Future<void> play(AudioChunk chunk);

  /// Stops whatever is playing straight away.
  Future<void> stopPlayback();

  Future<void> dispose();
}
