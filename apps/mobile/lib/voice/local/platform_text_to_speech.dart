import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';

import '../audio_io.dart';
import '../text_to_speech.dart';

/// The phone's own voice: Google's text to speech on Android, Apple's on
/// iOS. Each sentence is rendered to a WAV file and handed back as audio, so
/// it plays through [AudioIO] like every other engine, on the loudspeaker
/// and with the mic's echo cancellation.
class PlatformTextToSpeech implements TextToSpeech {
  PlatformTextToSpeech({
    FlutterTts? tts,
    Future<Directory> Function()? directory,
    this.language = 'en-GB',
    this.rate = 0.5,
    this.timeout = const Duration(seconds: 10),
  }) : _ttsOverride = tts,
       _directory = directory ?? getTemporaryDirectory;

  final FlutterTts? _ttsOverride;
  late final FlutterTts _tts = _ttsOverride ?? FlutterTts();
  final Future<Directory> Function() _directory;

  /// The accent Sous prefers, falling back to any English voice.
  final String language;

  /// flutter_tts's scale, where 0.5 is each platform's normal pace.
  final double rate;

  /// How long one sentence may take to render before it's given up on.
  final Duration timeout;

  Future<void>? _loading;
  late File _file;
  Future<Object?> _previous = Future.value();
  Completer<Object?>? _failed;

  /// The voice picked by [init], or null when the platform had no English
  /// voice to choose and its default is used.
  Map<String, String>? voice;

  @override
  Future<void> init() => _loading ??= _load();

  Future<void> _load() async {
    _file = File('${(await _directory()).path}/sous-speech.wav');
    _tts.setErrorHandler((message) {
      final failed = _failed;
      if (failed != null && !failed.isCompleted) {
        failed.completeError(TextToSpeechException('$message'));
      }
    });
    await _tts.awaitSynthCompletion(true);
    final voices = await _tts.getVoices;
    voice = pickVoice(
      voices is List ? voices.whereType<Map<Object?, Object?>>() : const [],
      language: language,
    );
    if (voice case final picked?) {
      await _tts.setVoice(picked);
    } else {
      await _tts.setLanguage(language);
    }
    await _tts.setSpeechRate(rate);
    debugPrint('Sous voice: ${voice ?? 'platform default'}');
  }

  @override
  Future<AudioChunk> synthesize(String text) {
    final audio = _previous.then((_) => _render(text));
    _previous = audio.then<Object?>((_) => null, onError: (_) => null);
    return audio;
  }

  Future<AudioChunk> _render(String text) async {
    await init();
    if (await _file.exists()) await _file.delete();
    final failed = _failed = Completer<Object?>();
    try {
      final result = await Future.any<Object?>([
        _tts.synthesizeToFile(text, _file.path, true),
        failed.future,
      ]).timeout(timeout);
      if (result != 1) {
        throw TextToSpeechException('Couldn\'t render "$text" ($result)');
      }
    } on TimeoutException {
      await _tts.stop();
      throw TextToSpeechException('Rendering "$text" took over $timeout');
    } finally {
      _failed = null;
    }
    return decodeWav(await _file.readAsBytes());
  }

  @override
  Future<void> dispose() async {
    if (_loading == null) return;
    await _tts.stop();
  }
}

class TextToSpeechException implements Exception {
  const TextToSpeechException(this.message);

  final String message;

  @override
  String toString() => 'TextToSpeechException: $message';
}

/// The most natural installed voice for [language] from flutter_tts's voice
/// list, or another English one if it has none. Voices that need the
/// network or haven't downloaded are skipped, and so are Apple's novelty and
/// Eloquence voices.
Map<String, String>? pickVoice(
  Iterable<Map<Object?, Object?>> voices, {
  String language = 'en-GB',
}) {
  String norm(String locale) => locale.replaceAll('_', '-').toLowerCase();
  final wanted = norm(language);
  final candidates =
      [
        for (final raw in voices)
          {
            for (final MapEntry(:key, :value) in raw.entries)
              if (key != null && value != null) '$key': '$value',
          },
      ].where((v) {
        final locale = norm(v['locale'] ?? '');
        final id = v['identifier'] ?? '';
        return v['name'] != null &&
            locale.startsWith('en') &&
            v['network_required'] != '1' &&
            !(v['features'] ?? '').split('\t').contains('notInstalled') &&
            !id.contains('speech.synthesis.voice') &&
            !id.contains('eloquence');
      }).toList();
  if (candidates.isEmpty) return null;

  int rank(Map<String, String> v) {
    final accent = norm(v['locale']!) == wanted ? 0 : 1;
    final quality = switch (v['quality']) {
      'premium' || 'very high' => 0,
      'enhanced' || 'high' => 1,
      _ => 2,
    };
    return accent * 10 + quality;
  }

  candidates.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    return byRank != 0 ? byRank : a['name']!.compareTo(b['name']!);
  });
  final best = candidates.first;
  return {
    'name': best['name']!,
    'locale': best['locale']!,
    'identifier': ?best['identifier'],
  };
}

/// A WAV file as mono audio. Reads 16-bit PCM (Android) and 32-bit float
/// (iOS), keeping the first channel.
AudioChunk decodeWav(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  String tag(int at) => String.fromCharCodes(bytes, at, at + 4);
  if (bytes.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('Not a WAV file');
  }
  int? format, channels, rate, bits;
  var at = 12;
  while (at + 8 <= bytes.length) {
    final id = tag(at);
    final size = data.getUint32(at + 4, Endian.little);
    final body = at + 8;
    if (id == 'fmt ') {
      format = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      rate = data.getUint32(body + 4, Endian.little);
      bits = data.getUint16(body + 14, Endian.little);
      if (format == 0xFFFE) format = data.getUint16(body + 24, Endian.little);
    } else if (id == 'data') {
      if (format == null || channels == null || rate == null || bits == null) {
        throw const FormatException('WAV data before its format');
      }
      final end = size == 0 || body + size > bytes.length
          ? bytes.length
          : body + size;
      final frame = channels * bits ~/ 8;
      final out = Float32List((end - body) ~/ frame);
      for (var i = 0; i < out.length; i++) {
        final s = body + i * frame;
        out[i] = switch ((format, bits)) {
          (1, 16) => data.getInt16(s, Endian.little) / 32768,
          (3, 32) => data.getFloat32(s, Endian.little),
          _ => throw FormatException('Unsupported WAV format $format/$bits'),
        };
      }
      return AudioChunk(out, rate);
    }
    at = body + size + (size.isOdd ? 1 : 0);
  }
  return AudioChunk(Float32List(0), rate ?? 16000);
}
