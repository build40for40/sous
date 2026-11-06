import 'package:flutter_test/flutter_test.dart';
import 'package:sous/voice/local/platform_text_to_speech.dart';
import 'package:sous/voice/local/sherpa_models.dart';
import 'package:sous/voice/local/sherpa_text_to_speech.dart';
import 'package:sous/voice/voice.dart';

void main() {
  test('speaks with the phone\'s own voice by default, with nothing to '
      'download for it', () {
    final voice = Voice.fromConfig(const VoiceConfig());

    expect(const VoiceConfig().speechVoice, SpeechVoice.platform);
    expect(voice.textToSpeech, isA<PlatformTextToSpeech>());
    expect(voice.models, isNot(contains(SherpaModels.kittenNano)));
    expect(voice.models, isNot(contains(SherpaModels.kokoro)));
  });

  test('can still speak with Kitten through sherpa-onnx', () {
    final voice = Voice.fromConfig(
      const VoiceConfig(speechVoice: SpeechVoice.sherpa),
    );

    expect(voice.textToSpeech, isA<SherpaTextToSpeech>());
    expect(voice.models, contains(SherpaModels.kittenNano));
  });
}
