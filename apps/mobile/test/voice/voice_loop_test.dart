import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sous/cooking/cooking_session.dart';
import 'package:sous/voice/audio_io.dart';
import 'package:sous/voice/speech_to_text.dart';
import 'package:sous/voice/text_to_speech.dart';
import 'package:sous/voice/voice_loop.dart';

import '../support/fake_brain.dart';

/// Plays each clip until the test calls [finish], like a real speaker.
class FakeAudio implements AudioIO {
  bool permitted = true;
  bool? echoCancel;
  final mic = StreamController<Float32List>();
  final playing = <Completer<void>>[];
  var played = 0;
  var stops = 0;

  bool get isPlaying => playing.isNotEmpty;

  void finish() => playing.removeAt(0).complete();

  @override
  Future<bool> requestPermission() async => permitted;

  @override
  Future<Stream<Float32List>> startCapture({
    required int sampleRate,
    required bool echoCancel,
  }) async {
    this.echoCancel = echoCancel;
    return mic.stream;
  }

  @override
  Future<void> stopCapture() async {}

  @override
  Future<void> play(AudioChunk chunk) {
    played++;
    final done = Completer<void>();
    playing.add(done);
    return done.future;
  }

  @override
  Future<void> stopPlayback() async {
    stops++;
    for (final clip in playing) {
      clip.complete();
    }
    playing.clear();
  }

  @override
  Future<void> dispose() async {}
}

class FakeStt implements SpeechToText {
  final _events = StreamController<SpeechEvent>.broadcast();
  var samples = 0;

  void hear(String text) {
    _events
      ..add(const SpeechStarted())
      ..add(FinalTranscript(text));
  }

  void startTalking() => _events.add(const SpeechStarted());

  void finishTalking(String text) => _events.add(FinalTranscript(text));

  @override
  int get sampleRate => 16000;

  @override
  Stream<SpeechEvent> get events => _events.stream;

  @override
  Future<void> init() async {}

  @override
  void accept(Float32List samples) => this.samples += samples.length;

  @override
  void reset() {}

  @override
  Future<void> dispose() => _events.close();
}

class FakeTts implements TextToSpeech {
  final said = <String>[];

  @override
  Future<void> init() async {}

  @override
  Future<AudioChunk> synthesize(String text) async {
    said.add(text);
    return AudioChunk(Float32List(160), 16000);
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  late FakeBrain brain;
  late CookingSession session;
  late FakeAudio audio;
  late FakeStt stt;
  late FakeTts tts;
  late VoiceLoop loop;
  late DateTime now;

  VoiceLoop build([VoiceLoopSettings settings = const VoiceLoopSettings()]) =>
      VoiceLoop(
        audio: audio,
        speechToText: stt,
        textToSpeech: tts,
        session: session,
        settings: settings,
        clock: () => now,
      );

  /// Lets Sous finish speaking everything queued.
  Future<void> playOut() async {
    for (var i = 0; i < 20; i++) {
      await pumpEventQueue();
      if (!audio.isPlaying) break;
      audio.finish();
    }
    now = now.add(const Duration(seconds: 1));
  }

  setUp(() async {
    now = DateTime.utc(2026, 11, 6, 16);
    brain = FakeBrain();
    session = CookingSession(
      brain: brain.brainClient,
      tools: FakeKitchen(),
      busyRetryDelays: const [Duration.zero, Duration.zero],
    );
    audio = FakeAudio();
    stt = FakeStt();
    tts = FakeTts();
    await session.start('recipe-example-1');
    loop = build();
  });

  tearDown(() async {
    await loop.dispose();
    await session.dispose();
  });

  test('takes turns: speaks the opening line, hears the cook, speaks the '
      'reply', () async {
    await loop.start();
    await pumpEventQueue();
    expect(tts.said, ['Right, fake beans on toast.', 'Got everything out?']);
    expect(loop.state.status, VoiceStatus.speaking);
    await playOut();
    expect(loop.state.status, VoiceStatus.listening);

    brain.replies.add([
      text('Lovely. Simmer for 5 mins'),
      text(' at 180°C.'),
      done('end_turn'),
    ]);
    stt.hear('Yes, all out.');
    await pumpEventQueue();

    expect(brain.turns.single, {'text': 'Yes, all out.'});
    expect(loop.state.heard, 'Yes, all out.');
    expect(tts.said.skip(2), [
      'Lovely.',
      'Simmer for five minutes at one hundred and eighty degrees Celsius.',
    ]);
    await playOut();
    expect(audio.played, 4);
    expect(loop.state.status, VoiceStatus.listening);
  });

  test(
    'speaks sentence by sentence while the reply is still streaming',
    () async {
      await loop.start();
      await playOut();
      final slow = SlowReply();
      brain.replies.add(slow.response);

      stt.hear('What now?');
      await pumpEventQueue();
      expect(loop.state.status, VoiceStatus.thinking);

      slow.send(text('Heat the pan. Add 200g'));
      await pumpEventQueue();
      expect(tts.said.last, 'Heat the pan.');
      expect(audio.isPlaying, isTrue);
      expect(loop.state.status, VoiceStatus.speaking);

      slow.send(text(' of rice'));
      await pumpEventQueue();
      expect(tts.said.last, 'Heat the pan.');

      slow.send(done('end_turn'));
      await slow.close();
      await pumpEventQueue();
      expect(tts.said.last, 'Add two hundred grams of rice');
      await playOut();
    },
  );

  group('half duplex', () {
    test(
      'is the default and ignores what it hears while Sous speaks',
      () async {
        expect(loop.settings.duplex, DuplexMode.half);
        await loop.start();
        await pumpEventQueue();
        expect(audio.isPlaying, isTrue);

        stt.hear('Right fake beans on toast');
        await pumpEventQueue();
        expect(brain.turns, isEmpty);
        expect(audio.isPlaying, isTrue);
        expect(stt.samples, 0);
        audio.mic.add(Float32List(512));
        await pumpEventQueue();
        expect(stt.samples, 512, reason: 'still listening for stop words');
      },
    );

    test('"Hold" silences Sous and the reply still finishes', () async {
      await loop.start();
      await playOut();
      final slow = SlowReply();
      brain.replies.add(slow.response);
      stt.hear('Next step?');
      await pumpEventQueue();
      slow.send(text('Now drain the pasta. Keep a mug of the water. '));
      await pumpEventQueue();
      expect(audio.isPlaying, isTrue);

      stt.hear('Hold, Chef!');
      await pumpEventQueue();

      expect(audio.isPlaying, isFalse);
      expect(audio.stops, greaterThan(0));
      expect(session.state.phase, CookingPhase.replying);

      slow.send(text('Never spoken.'));
      slow.send(done('end_turn'));
      await slow.close();
      await pumpEventQueue();
      expect(tts.said, isNot(contains('Never spoken.')));
      expect(session.state.phase, CookingPhase.ready);
      expect(session.state.reply, endsWith('Never spoken.'));
      expect(brain.turns, hasLength(1));
      expect(loop.state.status, VoiceStatus.listening);
    });

    test('a tap on the flame silences Sous', () async {
      await loop.start();
      await pumpEventQueue();
      expect(audio.isPlaying, isTrue);
      await loop.silence();
      expect(audio.isPlaying, isFalse);
      expect(loop.state.status, VoiceStatus.listening);
    });

    test('interrupt also cancels the reply that is streaming', () async {
      await loop.start();
      await playOut();
      final slow = SlowReply();
      brain.replies.add(slow.response);
      stt.hear('Next step?');
      await pumpEventQueue();
      slow.send(text('Now drain the pasta. Keep a mug of the water. '));
      await pumpEventQueue();

      await loop.interrupt();
      expect(audio.isPlaying, isFalse);
      expect(session.state.phase, CookingPhase.ready);
      await slow.close();
    });

    test('can stop listening altogether while Sous speaks', () async {
      loop = build(const VoiceLoopSettings(stopWordsWhileSpeaking: false));
      await loop.start();
      await pumpEventQueue();
      audio.mic.add(Float32List(512));
      await pumpEventQueue();
      expect(stt.samples, 0);
      await playOut();
      audio.mic.add(Float32List(512));
      await pumpEventQueue();
      expect(stt.samples, 512, reason: 'listening again once Sous is done');
    });
  });

  group('full duplex', () {
    setUp(() => loop = build(const VoiceLoopSettings(duplex: DuplexMode.full)));

    test('the chef talking over Sous cuts in, and is heard once the reply '
        'is done', () async {
      await loop.start();
      await playOut();
      final slow = SlowReply();
      brain.replies.add(slow.response);
      stt.hear('Next step?');
      await pumpEventQueue();
      slow.send(text('Now drain the pasta. Keep a mug of the water. '));
      await pumpEventQueue();
      expect(audio.isPlaying, isTrue);

      stt.startTalking();
      await pumpEventQueue();
      expect(audio.isPlaying, isFalse);
      expect(loop.state.status, VoiceStatus.hearing);

      stt.finishTalking('Which pan?');
      await pumpEventQueue();
      expect(brain.turns, hasLength(1));
      expect(loop.state.status, VoiceStatus.thinking);

      brain.replies.add([text('The big pan.'), done('end_turn')]);
      slow.send(done('end_turn'));
      await slow.close();
      await pumpEventQueue();
      await pumpEventQueue();

      expect(brain.turns.last, {'text': 'Which pan?'});
      expect(tts.said.last, 'The big pan.');
      await playOut();
    });
  });

  test('talking while Sous is still thinking waits for the reply', () async {
    await loop.start();
    await playOut();
    final slow = SlowReply();
    brain.replies.add(slow.response);
    stt.hear('How long for the rice?');
    await pumpEventQueue();
    expect(session.state.phase, CookingPhase.thinking);

    stt.hear('Basmati, I mean.');
    await pumpEventQueue();
    expect(brain.turns, hasLength(1));

    brain.replies.add([text('Twelve minutes for basmati.'), done('end_turn')]);
    slow.send(text('About fifteen minutes.'));
    slow.send(done('end_turn'));
    await slow.close();
    await pumpEventQueue();
    await pumpEventQueue();

    expect(brain.turns.map((t) => t['text']), [
      'How long for the rice?',
      'Basmati, I mean.',
    ]);
    expect(tts.said, contains('About fifteen minutes.'));
    expect(tts.said.last, 'Twelve minutes for basmati.');
    await playOut();
  });

  test('knows the stop words', () {
    for (final phrase in [
      'Stop.',
      'Hold',
      'Wait, Chef',
      'Hey Sous',
      'hang on',
    ]) {
      expect(isStopCommand(phrase), isTrue, reason: phrase);
    }
    for (final phrase in [
      'Stop the timer',
      'Yes, Chef',
      'Heard',
      'Wait for it to boil',
    ]) {
      expect(isStopCommand(phrase), isFalse, reason: phrase);
    }
  });

  test('empty transcripts are ignored', () async {
    await loop.start();
    await playOut();
    stt.hear('');
    await pumpEventQueue();
    expect(brain.turns, isEmpty);
  });

  test('fails to start without the microphone', () async {
    audio.permitted = false;
    await loop.start();
    expect(loop.state.status, VoiceStatus.failed);
    expect(loop.state.error, isA<VoiceException>());
    expect(loop.running, isFalse);
  });

  test('stop goes quiet and the session carries on', () async {
    await loop.start();
    await pumpEventQueue();
    await loop.stop();
    expect(audio.isPlaying, isFalse);
    expect(loop.state.status, VoiceStatus.off);
    expect(session.state.phase, CookingPhase.ready);
  });
}
