import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../model_downloader.dart';
import '../wake_word.dart';
import 'sherpa_bindings.dart';
import 'sherpa_models.dart';

/// "Hey Sous" spotted on the phone by a small streaming zipformer, so only
/// the chef saying it opens a turn.
class SherpaWakeWord implements WakeWord {
  SherpaWakeWord({
    required this._models,
    this.score = 1.0,
    this.threshold = 0.15,
    this.threads = 1,
  });

  final ModelDownloader _models;

  /// Boosts the wake phrases while decoding. Higher spots more, and more
  /// wrongly.
  final double score;

  /// How sure the spotter must be. Lower spots more, and more wrongly.
  final double threshold;
  final int threads;

  /// The phrases in the model's word pieces, made with its `bpe.model`.
  static const phrases = [
    '▁HE Y ▁SO US @HEY_SOUS',
    '▁HE Y ▁SU E @HEY_SUE',
    '▁HE Y ▁SU E ▁C HE F @HEY_SUE_CHEF',
    '▁HE Y ▁SU @HEY_SU',
    '▁HE Y ▁SO O @HEY_SOO',
    '▁HE Y ▁SO O S @HEY_SOOS',
  ];

  static const _encoder = 'encoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx';
  static const _decoder = 'decoder-epoch-12-avg-2-chunk-16-left-64.int8.onnx';
  static const _joiner = 'joiner-epoch-12-avg-2-chunk-16-left-64.int8.onnx';

  final _heard = StreamController<void>.broadcast(sync: true);
  sherpa.KeywordSpotter? _spotter;
  sherpa.OnlineStream? _stream;
  Future<void>? _loading;

  List<VoiceModel> get requiredModels => [SherpaModels.kwsGigaspeech];

  @override
  int get sampleRate => 16000;

  @override
  Stream<void> get heard => _heard.stream;

  @override
  Future<void> init() => _loading ??= _load();

  Future<void> _load() async {
    bindSherpa();
    final model = SherpaModels.kwsGigaspeech;
    final tokens = await _models.pathOf(model, 'tokens.txt');
    final keywords = File('${File(tokens).parent.path}/sous-keywords.txt');
    await keywords.writeAsString('${phrases.join('\n')}\n');
    final spotter = sherpa.KeywordSpotter(
      sherpa.KeywordSpotterConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: await _models.pathOf(model, _encoder),
            decoder: await _models.pathOf(model, _decoder),
            joiner: await _models.pathOf(model, _joiner),
          ),
          tokens: tokens,
          numThreads: threads,
          debug: false,
        ),
        keywordsFile: keywords.path,
        keywordsScore: score,
        keywordsThreshold: threshold,
      ),
    );
    _spotter = spotter;
    _stream = spotter.createStream();
  }

  @override
  void accept(Float32List samples) {
    final spotter = _spotter;
    final stream = _stream;
    if (spotter == null || stream == null) return;
    stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
    while (spotter.isReady(stream)) {
      spotter.decode(stream);
      if (spotter.getResult(stream).keyword.isNotEmpty) {
        spotter.reset(stream);
        _heard.add(null);
      }
    }
  }

  @override
  void reset() {
    final spotter = _spotter;
    final stream = _stream;
    if (spotter != null && stream != null) spotter.reset(stream);
  }

  @override
  Future<void> dispose() async {
    await _loading;
    _stream?.free();
    _spotter?.free();
    _stream = null;
    _spotter = null;
    await _heard.close();
  }
}
