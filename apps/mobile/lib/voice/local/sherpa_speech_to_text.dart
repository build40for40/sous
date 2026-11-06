import 'dart:async';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../model_downloader.dart';
import '../speech_to_text.dart';
import 'sherpa_bindings.dart';
import 'sherpa_models.dart';

/// Silero VAD decides when the cook starts and stops talking, then Moonshine
/// transcribes each utterance, all on the phone.
class SherpaSpeechToText implements SpeechToText {
  SherpaSpeechToText({
    required this._models,
    VoiceModel? recognizer,
    this.minSilence = const Duration(milliseconds: 600),
    this.minSpeech = const Duration(milliseconds: 250),
    this.threads = 2,
  }) : recognizerModel = recognizer ?? SherpaModels.moonshineBase;

  final ModelDownloader _models;
  final VoiceModel recognizerModel;

  /// Silence that ends the cook's turn.
  final Duration minSilence;

  /// Speech shorter than this is ignored.
  final Duration minSpeech;
  final int threads;

  static const _window = 512;

  final _events = StreamController<SpeechEvent>.broadcast();
  sherpa.VoiceActivityDetector? _vad;
  sherpa.OfflineRecognizer? _recognizer;
  Future<void>? _loading;
  final _buffer = <double>[];
  var _talking = false;

  List<VoiceModel> get requiredModels => [
    SherpaModels.sileroVad,
    recognizerModel,
  ];

  @override
  int get sampleRate => 16000;

  @override
  Stream<SpeechEvent> get events => _events.stream;

  @override
  Future<void> init() => _loading ??= _load();

  Future<void> _load() async {
    bindSherpa();
    final vadPath = await _models.pathOf(
      SherpaModels.sileroVad,
      'silero_vad.onnx',
    );
    final asr = recognizerModel;
    _vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadPath,
          minSilenceDuration: minSilence.inMilliseconds / 1000,
          minSpeechDuration: minSpeech.inMilliseconds / 1000,
          maxSpeechDuration: 15,
          windowSize: _window,
        ),
        sampleRate: sampleRate,
        debug: false,
      ),
      bufferSizeInSeconds: 30,
    );
    _recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          moonshine: sherpa.OfflineMoonshineModelConfig(
            encoder: await _models.pathOf(asr, 'encoder_model.ort'),
            mergedDecoder: await _models.pathOf(
              asr,
              'decoder_model_merged.ort',
            ),
          ),
          tokens: await _models.pathOf(asr, 'tokens.txt'),
          numThreads: threads,
          debug: false,
        ),
      ),
    );
  }

  @override
  void accept(Float32List samples) {
    final vad = _vad;
    if (vad == null) return;
    _buffer.addAll(samples);
    while (_buffer.length >= _window) {
      vad.acceptWaveform(Float32List.fromList(_buffer.sublist(0, _window)));
      _buffer.removeRange(0, _window);
      if (!_talking && vad.isDetected()) {
        _talking = true;
        _events.add(const SpeechStarted());
      }
      while (!vad.isEmpty()) {
        final segment = vad.front();
        vad.pop();
        _talking = false;
        _events.add(FinalTranscript(_transcribe(segment.samples)));
      }
    }
  }

  String _transcribe(Float32List samples) {
    final recognizer = _recognizer!;
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      recognizer.decode(stream);
      return recognizer.getResult(stream).text.trim();
    } finally {
      stream.free();
    }
  }

  @override
  void reset() {
    _buffer.clear();
    _vad?.reset();
    if (_talking) {
      _talking = false;
      _events.add(const FinalTranscript(''));
    }
  }

  @override
  Future<void> dispose() async {
    await _loading;
    _vad?.free();
    _recognizer?.free();
    _vad = null;
    _recognizer = null;
    await _events.close();
  }
}
