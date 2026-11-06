import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../cooking/cooking_session.dart';
import 'audio_io.dart';
import 'local/platform_audio_io.dart';
import 'local/sherpa_models.dart';
import 'local/sherpa_speech_to_text.dart';
import 'local/sherpa_text_to_speech.dart';
import 'local/sherpa_wake_word.dart';
import 'model_downloader.dart';
import 'speech_to_text.dart';
import 'text_to_speech.dart';
import 'voice_loop.dart';
import 'wake_word.dart';

/// Which speech engines Sous uses. Only the on-device ones exist so far; a
/// cloud engine plugs in here without touching [VoiceLoop].
enum VoiceEngine { local }

class VoiceConfig {
  const VoiceConfig({
    this.engine = VoiceEngine.local,
    this.duplex = DuplexMode.half,
    this.lightModels = false,
    this.keywordSpotting = true,
  });

  /// Reads `--dart-define=SOUS_VOICE_ENGINE=local`,
  /// `--dart-define=SOUS_FULL_DUPLEX=true`,
  /// `--dart-define=SOUS_LIGHT_VOICE_MODELS=true` and
  /// `--dart-define=SOUS_WAKE_WORD=false`.
  factory VoiceConfig.fromEnvironment() => VoiceConfig(
    engine: VoiceEngine.values.byName(
      const String.fromEnvironment('SOUS_VOICE_ENGINE', defaultValue: 'local'),
    ),
    duplex: const bool.fromEnvironment('SOUS_FULL_DUPLEX')
        ? DuplexMode.full
        : DuplexMode.half,
    lightModels: const bool.fromEnvironment('SOUS_LIGHT_VOICE_MODELS'),
    keywordSpotting: const bool.fromEnvironment(
      'SOUS_WAKE_WORD',
      defaultValue: true,
    ),
  );

  final VoiceEngine engine;
  final DuplexMode duplex;

  /// Moonshine tiny instead of base, for phones that struggle.
  final bool lightModels;

  /// Spots "Hey Sous" with a small always-on model, which also catches it
  /// while Sous is talking. Without it, "Hey Sous" still works when the
  /// speech recogniser hears it at the start of what the chef says, and a
  /// tap always works.
  final bool keywordSpotting;
}

/// Sous's ears and mouth: the engines picked by [VoiceConfig], the models
/// they need, and a [VoiceLoop] for each cook.
class Voice {
  Voice({
    required this.audio,
    required this.speechToText,
    required this.textToSpeech,
    this.wakeWord,
    this.settings = const VoiceLoopSettings(),
    this.models = const [],
    this.downloader,
  });

  /// The one place engines are chosen.
  factory Voice.fromConfig(VoiceConfig config, {http.Client? httpClient}) {
    switch (config.engine) {
      case VoiceEngine.local:
        final downloader = ModelDownloader(
          root: _modelRoot,
          httpClient: httpClient,
        );
        final stt = SherpaSpeechToText(
          models: downloader,
          recognizer: config.lightModels
              ? SherpaModels.moonshineTiny
              : SherpaModels.moonshineBase,
        );
        final tts = SherpaTextToSpeech(
          models: downloader,
          voice: Platform.isIOS ? SherpaVoice.kokoro : SherpaVoice.kitten,
        );
        final wake = config.keywordSpotting
            ? SherpaWakeWord(models: downloader)
            : null;
        return Voice(
          audio: PlatformAudioIO(),
          speechToText: stt,
          textToSpeech: tts,
          wakeWord: wake,
          settings: VoiceLoopSettings(
            duplex: config.duplex,
            // iOS voice processing ducks Sous's own playback, so it only
            // goes on when full duplex needs it.
            echoCancel: config.duplex == DuplexMode.full || Platform.isAndroid,
          ),
          models: [
            ...stt.requiredModels,
            ...tts.requiredModels,
            ...?wake?.requiredModels,
          ],
          downloader: downloader,
        );
    }
  }

  final AudioIO audio;
  final SpeechToText speechToText;
  final TextToSpeech textToSpeech;

  /// Null when only the speech recogniser and a tap open turns.
  final WakeWord? wakeWord;
  final VoiceLoopSettings settings;

  /// What has to be downloaded before the first [VoiceLoop.start].
  final List<VoiceModel> models;
  final ModelDownloader? downloader;

  int get downloadBytes => models.fold(0, (sum, m) => sum + m.bytes);

  /// Whether the models are all on the phone already.
  Future<bool> isReady() async =>
      downloader == null || await downloader!.allReady(models);

  /// Downloads the models with progress. Safe to call when they're there.
  Stream<DownloadProgress> prepare() =>
      downloader?.download(models) ??
      Stream.value(const DownloadProgress(received: 0, total: 0));

  /// A voice loop for [session]. Start it once [isReady].
  VoiceLoop loopFor(CookingSession session) => VoiceLoop(
    audio: audio,
    speechToText: speechToText,
    textToSpeech: textToSpeech,
    session: session,
    wakeWord: wakeWord,
    settings: settings,
  );

  Future<void> dispose() async {
    await audio.dispose();
    await speechToText.dispose();
    await textToSpeech.dispose();
    await wakeWord?.dispose();
  }
}

Future<Directory> _modelRoot() async {
  final base = Platform.isIOS
      ? await getApplicationCacheDirectory()
      : await getApplicationSupportDirectory();
  return Directory('${base.path}/voice-models');
}
