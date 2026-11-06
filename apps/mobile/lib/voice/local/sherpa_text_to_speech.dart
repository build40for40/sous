import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../audio_io.dart';
import '../model_downloader.dart';
import '../text_to_speech.dart';
import 'sherpa_bindings.dart';
import 'sherpa_models.dart';

enum SherpaVoice { kokoro, kitten }

/// Kokoro or Kitten through sherpa-onnx, synthesising in a background isolate
/// so the screen and the mic keep going while a sentence renders.
class SherpaTextToSpeech implements TextToSpeech {
  SherpaTextToSpeech({
    required this._models,
    required this.voice,
    this.speakerId = 0,
    this.speed = 1.0,
    this.threads = 2,
  });

  final ModelDownloader _models;
  final SherpaVoice voice;
  final int speakerId;
  final double speed;
  final int threads;

  Future<void>? _loading;
  SendPort? _worker;
  ReceivePort? _replies;
  final _waiting = Queue<Completer<AudioChunk>>();

  VoiceModel get model => switch (voice) {
    SherpaVoice.kokoro => SherpaModels.kokoro,
    SherpaVoice.kitten => SherpaModels.kittenNano,
  };

  List<VoiceModel> get requiredModels => [model];

  @override
  Future<void> init() => _loading ??= _load();

  Future<void> _load() async {
    final m = model;
    Future<String> file(String name) => _models.pathOf(m, name);
    final modelFile = voice == SherpaVoice.kokoro
        ? 'model.onnx'
        : 'model.int8.onnx';
    final paths = (
      model: await file(modelFile),
      voices: await file('voices.bin'),
      tokens: await file('tokens.txt'),
      dataDir: await file('espeak-ng-data'),
    );
    final config = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        kokoro: voice == SherpaVoice.kokoro
            ? sherpa.OfflineTtsKokoroModelConfig(
                model: paths.model,
                voices: paths.voices,
                tokens: paths.tokens,
                dataDir: paths.dataDir,
              )
            : const sherpa.OfflineTtsKokoroModelConfig(),
        kitten: voice == SherpaVoice.kitten
            ? sherpa.OfflineTtsKittenModelConfig(
                model: paths.model,
                voices: paths.voices,
                tokens: paths.tokens,
                dataDir: paths.dataDir,
              )
            : const sherpa.OfflineTtsKittenModelConfig(),
        numThreads: threads,
      ),
    );

    final replies = ReceivePort();
    _replies = replies;
    final ready = Completer<void>();
    replies.listen((message) {
      if (message is SendPort) {
        _worker = message;
        ready.complete();
      } else if (!ready.isCompleted) {
        ready.completeError(StateError('$message'));
      } else if (_waiting.isNotEmpty) {
        final waiting = _waiting.removeFirst();
        if (message case (TransferableTypedData data, int rate)) {
          waiting.complete(
            AudioChunk(data.materialize().asFloat32List(), rate),
          );
        } else {
          waiting.completeError(StateError('$message'));
        }
      }
    });
    await Isolate.spawn(_ttsWorker, (
      replies.sendPort,
      config,
      speakerId,
      speed,
    ));
    await ready.future;
  }

  @override
  Future<AudioChunk> synthesize(String text) async {
    await init();
    final done = Completer<AudioChunk>();
    _waiting.add(done);
    _worker!.send(text);
    return done.future;
  }

  @override
  Future<void> dispose() async {
    try {
      await _loading;
    } on Object {
      // Nothing to free if it never loaded.
    }
    _worker?.send(null);
    _replies?.close();
    _worker = null;
    for (final waiting in _waiting) {
      waiting.completeError(StateError('Text to speech was disposed'));
    }
    _waiting.clear();
  }
}

void _ttsWorker((SendPort, sherpa.OfflineTtsConfig, int, double) args) {
  final (reply, config, speakerId, speed) = args;
  final sherpa.OfflineTts tts;
  try {
    bindSherpa();
    tts = sherpa.OfflineTts(config);
  } on Object catch (e) {
    reply.send('Couldn\'t load the voice: $e');
    return;
  }
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  inbox.listen((message) {
    if (message is! String) {
      tts.free();
      inbox.close();
      return;
    }
    try {
      final audio = tts.generate(text: message, sid: speakerId, speed: speed);
      reply.send((
        TransferableTypedData.fromList([audio.samples]),
        audio.sampleRate,
      ));
    } on Object catch (e) {
      reply.send('$e');
    }
  });
}
