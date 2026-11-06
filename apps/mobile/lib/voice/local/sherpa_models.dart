import '../model_downloader.dart';

Uri _release(String tag, String file) => Uri.parse(
  'https://github.com/k2-fsa/sherpa-onnx/releases/download/$tag/$file',
);

/// The models the local engines use, from the sherpa-onnx GitHub releases.
abstract final class SherpaModels {
  static final sileroVad = VoiceModel(
    id: 'silero-vad',
    url: _release('asr-models', 'silero_vad.onnx'),
    bytes: 643854,
  );

  /// Moonshine v2 base, quantised. English.
  static final moonshineBase = VoiceModel(
    id: 'moonshine-base-en-quantized-2026-02-27',
    url: _release(
      'asr-models',
      'sherpa-onnx-moonshine-base-en-quantized-2026-02-27.tar.bz2',
    ),
    bytes: 111266225,
    folder: 'sherpa-onnx-moonshine-base-en-quantized-2026-02-27',
  );

  /// Moonshine v2 tiny, the lighter option.
  static final moonshineTiny = VoiceModel(
    id: 'moonshine-tiny-en-quantized-2026-02-27',
    url: _release(
      'asr-models',
      'sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2',
    ),
    bytes: 29858559,
    folder: 'sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27',
  );

  /// Kokoro fp32, for iPhone (int8 is slower on Apple chips).
  static final kokoro = VoiceModel(
    id: 'kokoro-en-v0_19',
    url: _release('tts-models', 'kokoro-en-v0_19.tar.bz2'),
    bytes: 319625534,
    folder: 'kokoro-en-v0_19',
  );

  /// Kitten nano int8, for mid-range Android where Kokoro is too slow.
  static final kittenNano = VoiceModel(
    id: 'kitten-nano-en-v0_8-int8',
    url: _release('tts-models', 'kitten-nano-en-v0_8-int8.tar.bz2'),
    bytes: 31220690,
    folder: 'kitten-nano-en-v0_8-int8',
  );
}
