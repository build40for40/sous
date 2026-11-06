import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sous/cooking/cooking_session.dart';
import 'package:sous/voice/audio_io.dart';
import 'package:sous/voice/local/platform_audio_io.dart';
import 'package:sous/voice/local/platform_text_to_speech.dart';
import 'package:sous/voice/voice_loop.dart';

import '../../support/fake_brain.dart';
import '../voice_loop_test.dart' show FakeAudio, FakeStt;

const _channel = MethodChannel('flutter_tts');

/// Google's or Apple's text to speech, as flutter_tts's channel sees it:
/// writes a WAV of [samplesFor] each sentence to the path it's given.
class FakePlatformTts {
  FakePlatformTts({this.voices = const []});

  final List<Map<String, String>> voices;
  final calls = <MethodCall>[];
  final rendered = <String>[];
  var inFlight = 0;
  var maxInFlight = 0;

  /// Completes each render when set, instead of straight away.
  Completer<void> Function(String text)? hold;

  /// Fails the sentence through `synth.onError` and never returns.
  bool Function(String text) fails = (_) => false;

  static int samplesFor(String text) => text.length * 10;

  Iterable<String> methods() => calls.map((c) => c.method);

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'getVoices':
        return voices;
      case 'synthesizeToFile':
        final args = call.arguments as Map<Object?, Object?>;
        final text = args['text']! as String;
        expect(args['isFullPath'], isTrue);
        if (fails(text)) {
          await _fromPlatform('synth.onError', 'synthesis failed');
          return Completer<Object?>().future;
        }
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        try {
          await hold?.call(text).future;
          final samples = Float32List(samplesFor(text));
          samples.fillRange(0, samples.length, 0.25);
          await File(args['fileName']! as String)
              .writeAsBytes(wav(AudioChunk(samples, 24000)));
          rendered.add(text);
          return 1;
        } finally {
          inFlight--;
        }
    }
    return 1;
  }

  Future<void> _fromPlatform(String method, Object? arguments) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            _channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, arguments),
            ),
            (_) {},
          );
}

/// Real file IO finishes outside the microtask queue, so wait on it.
Future<void> until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

void main() {
  late Directory dir;
  late FakePlatformTts platform;

  PlatformTextToSpeech engine({
    Duration timeout = const Duration(seconds: 10),
  }) => PlatformTextToSpeech(directory: () async => dir, timeout: timeout);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sous-tts');
    platform = FakePlatformTts(
      voices: const [
        {
          'name': 'en-us-x-iol-local',
          'locale': 'en-US',
          'quality': 'very high',
        },
        {
          'name': 'en-gb-x-gba-network',
          'locale': 'en-GB',
          'quality': 'very high',
          'network_required': '1',
        },
        {
          'name': 'en-gb-x-gbc-local',
          'locale': 'en-GB',
          'quality': 'very high',
          'network_required': '0',
          'features': 'networkTimeoutMs\tnotInstalled',
        },
        {
          'name': 'en-gb-x-rjs-local',
          'locale': 'en-GB',
          'quality': 'very high',
          'network_required': '0',
        },
        {'name': 'en-gb-x-gbb-local', 'locale': 'en-GB', 'quality': 'normal'},
      ],
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, platform.handle);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await dir.delete(recursive: true);
  });

  test('picks an installed UK voice at a normal pace and waits for each '
      'render', () async {
    final tts = engine();
    await tts.init();

    expect(tts.voice, {'name': 'en-gb-x-rjs-local', 'locale': 'en-GB'});
    expect(platform.methods(), [
      'awaitSynthCompletion',
      'getVoices',
      'setVoice',
      'setSpeechRate',
    ]);
    expect(platform.calls[0].arguments, isTrue);
    expect(platform.calls[2].arguments, tts.voice);
    expect(platform.calls[3].arguments, 0.5);
  });

  test('prefers Apple\'s enhanced UK voices and skips the novelty ones', () {
    expect(
      pickVoice([
        {
          'name': 'Albert',
          'locale': 'en-GB',
          'quality': 'enhanced',
          'identifier': 'com.apple.speech.synthesis.voice.Albert',
        },
        {
          'name': 'Daniel',
          'locale': 'en-GB',
          'quality': 'default',
          'identifier': 'com.apple.voice.compact.en-GB.Daniel',
        },
        {
          'name': 'Serena',
          'locale': 'en-GB',
          'quality': 'enhanced',
          'identifier': 'com.apple.voice.enhanced.en-GB.Serena',
        },
        {
          'name': 'Ava',
          'locale': 'en-US',
          'quality': 'premium',
          'identifier': 'com.apple.voice.premium.en-US.Ava',
        },
      ]),
      {
        'name': 'Serena',
        'locale': 'en-GB',
        'identifier': 'com.apple.voice.enhanced.en-GB.Serena',
      },
    );
    expect(pickVoice([]), isNull);
    expect(
      pickVoice([
        {'name': 'fr-fr-x-frd-local', 'locale': 'fr-FR'},
      ]),
      isNull,
    );
  });

  test(
    'falls back to the UK language when there\'s no English voice',
    () async {
      platform = FakePlatformTts();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, platform.handle);
      await engine().init();
      expect(
        platform.calls.map((c) => (c.method, c.arguments)),
        contains(('setLanguage', 'en-GB')),
      );
    },
  );

  test('speaks a sentence: renders it to a file and returns its audio once '
      'the platform is done', () async {
    final tts = engine();
    final audio = await tts.synthesize('Heat the pan.');

    expect(platform.rendered, ['Heat the pan.']);
    expect(audio.sampleRate, 24000);
    expect(
      audio.samples,
      hasLength(FakePlatformTts.samplesFor('Heat the pan.')),
    );
    expect(audio.samples.first, closeTo(0.25, 0.001));
  });

  test('queued sentences render one at a time, in order', () async {
    final holds = <String, Completer<void>>{};
    platform.hold = (text) => holds[text] = Completer<void>();
    final tts = engine();

    final first = tts.synthesize('One.');
    final second = tts.synthesize('Two.');
    final third = tts.synthesize('Three.');
    await until(() => holds.containsKey('One.'));
    expect(holds.keys, ['One.']);

    holds['One.']!.complete();
    await until(() => holds.containsKey('Two.'));
    holds['Two.']!.complete();
    await until(() => holds.containsKey('Three.'));
    holds['Three.']!.complete();

    final lengths = [
      for (final audio in await Future.wait([first, second, third]))
        audio.samples.length,
    ];
    expect(lengths, [40, 40, 60]);
    expect(platform.rendered, ['One.', 'Two.', 'Three.']);
    expect(platform.maxInFlight, 1);
  });

  test('a platform error fails that sentence straight away and the next one '
      'still speaks', () async {
    platform.fails = (text) => text == 'Broken.';
    final tts = engine();

    await expectLater(
      tts.synthesize('Broken.'),
      throwsA(isA<TextToSpeechException>()),
    );
    final audio = await tts.synthesize('Fine.');
    expect(audio.samples, isNotEmpty);
  });

  test('a render that never finishes times out and stops the engine', () async {
    platform.hold = (_) => Completer<void>();
    final tts = engine(timeout: const Duration(milliseconds: 50));

    await expectLater(
      tts.synthesize('Stuck.'),
      throwsA(isA<TextToSpeechException>()),
    );
    expect(platform.methods(), contains('stop'));
  });

  test('dispose stops the engine', () async {
    final tts = engine();
    await tts.synthesize('Hi.');
    await tts.dispose();
    expect(platform.methods().last, 'stop');
  });

  test('reads Apple\'s 32-bit float WAVs', () {
    final bytes = BytesBuilder();
    void u32(int v) => bytes.add(
      (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List(),
    );
    void u16(int v) => bytes.add(
      (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List(),
    );
    bytes.add('RIFF'.codeUnits);
    u32(0);
    bytes.add('WAVE'.codeUnits);
    bytes.add('fmt '.codeUnits);
    u32(40);
    u16(0xFFFE);
    u16(1);
    u32(22050);
    u32(22050 * 4);
    u16(4);
    u16(32);
    u16(22);
    u16(32);
    u32(0);
    u16(3);
    bytes.add(List.filled(14, 0));
    bytes.add('FLLR'.codeUnits);
    u32(3);
    bytes.add([0, 0, 0, 0]);
    bytes.add('data'.codeUnits);
    u32(0);
    bytes.add(Float32List.fromList([0.5, -0.5]).buffer.asUint8List());

    final audio = decodeWav(bytes.toBytes());
    expect(audio.sampleRate, 22050);
    expect(audio.samples, [0.5, -0.5]);
  });

  group('in the voice loop', () {
    late FakeBrain brain;
    late CookingSession session;
    late FakeAudio audio;
    late PlatformTextToSpeech tts;
    late VoiceLoop loop;

    setUp(() async {
      brain = FakeBrain();
      session = CookingSession(
        brain: brain.brainClient,
        tools: FakeKitchen(),
        busyRetryDelays: const [Duration.zero, Duration.zero],
      );
      audio = FakeAudio();
      tts = engine();
      await session.start('recipe-example-1');
      loop = VoiceLoop(
        audio: audio,
        speechToText: FakeStt(),
        textToSpeech: tts,
        session: session,
      );
    });

    tearDown(() async {
      await loop.dispose();
      await session.dispose();
      await tts.dispose();
    });

    test('speaks each sentence after the last one, with no gaps or '
        'overlaps, then listens', () async {
      await loop.start();
      await until(() => audio.played == 1);
      expect(loop.state.status, VoiceStatus.speaking);
      expect(
        audio.clips.single.samples,
        hasLength(FakePlatformTts.samplesFor('Right, fake beans on toast.')),
      );
      await until(() => platform.rendered.length == 2);
      expect(audio.played, 1, reason: 'the next sentence waits its turn');

      audio.finish();
      await until(() => audio.played == 2);
      audio.finish();
      await until(() => loop.state.status == VoiceStatus.listening);
      expect(platform.rendered, [
        'Right, fake beans on toast.',
        'Got everything out?',
      ]);
    });

    test(
      'a tap stops Sous mid-sentence and the rest is never spoken',
      () async {
        await loop.start();
        await until(() => audio.played == 1);

        await loop.silence();
        expect(audio.isPlaying, isFalse);
        expect(loop.state.status, VoiceStatus.listening);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(audio.played, 1);
      },
    );
  });
}
