import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sous/api/session.dart';
import 'package:sous/cooking/cooking_session.dart';
import 'package:sous/voice/audio_io.dart';
import 'package:sous/voice/speech_to_text.dart';
import 'package:sous/voice/text_to_speech.dart';
import 'package:sous/voice/voice_loop.dart';
import 'package:sous/voice/wake_word.dart';

import '../support/fake_brain.dart';

/// Plays each clip until the test calls [finish], like a real speaker.
class FakeAudio implements AudioIO {
  bool permitted = true;
  bool? echoCancel;
  final mic = StreamController<Float32List>();
  final playing = <Completer<void>>[];
  final clips = <AudioChunk>[];
  var played = 0;
  var stops = 0;

  /// The chime is the only clip at 24 kHz; Sous's voice here is 16 kHz.
  int get chimes => clips.where((c) => c.sampleRate == 24000).length;

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
    clips.add(chunk);
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

class FakeWakeWord implements WakeWord {
  final _heard = StreamController<void>.broadcast(sync: true);
  var samples = 0;
  var resets = 0;

  void fire() => _heard.add(null);

  @override
  int get sampleRate => 16000;

  @override
  Future<void> init() async {}

  @override
  Stream<void> get heard => _heard.stream;

  @override
  void accept(Float32List samples) => this.samples += samples.length;

  @override
  void reset() => resets++;

  @override
  Future<void> dispose() => _heard.close();
}

/// A timer that only fires when the test moves the clock on.
class FakeTimer implements Timer {
  FakeTimer(this.due, this.callback);

  final DateTime due;
  final void Function() callback;
  var active = true;

  @override
  void cancel() => active = false;

  @override
  bool get isActive => active;

  @override
  int get tick => 0;
}

Map<String, Object?> doneAwaiting(String short) => {
  'type': 'done',
  'stop_reason': 'end_turn',
  'awaiting_ack': {'short': short},
};

void main() {
  late FakeBrain brain;
  late CookingSession session;
  late FakeAudio audio;
  late FakeStt stt;
  late FakeTts tts;
  late VoiceLoop loop;
  late DateTime now;
  late List<FakeTimer> timers;

  VoiceLoop build([
    VoiceLoopSettings settings = const VoiceLoopSettings(),
    WakeWord? wakeWord,
  ]) => VoiceLoop(
    audio: audio,
    speechToText: stt,
    textToSpeech: tts,
    session: session,
    wakeWord: wakeWord,
    settings: settings,
    clock: () => now,
    startTimer: (after, then) {
      final timer = FakeTimer(now.add(after), then);
      timers.add(timer);
      return timer;
    },
  );

  /// Moves the clock on by [time], firing timers as they come due.
  Future<void> elapse(Duration time) async {
    final end = now.add(time);
    while (true) {
      final due = timers.where((t) => t.active && !t.due.isAfter(end)).toList()
        ..sort((a, b) => a.due.compareTo(b.due));
      if (due.isEmpty) break;
      final timer = due.first..active = false;
      now = timer.due;
      timer.callback();
      await pumpEventQueue();
    }
    now = end;
  }

  int repeatsOf(String short) => tts.said.where((s) => s == short).length;

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
    timers = [];
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
    await loop.openTurn();
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

      await loop.openTurn();
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
      await loop.openTurn();
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
      await loop.openTurn();
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
      await loop.openTurn();
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
    await loop.openTurn();
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

  group('opening a turn', () {
    test('only "Hey Sous" opens one: the room is ignored', () async {
      await loop.start();
      await playOut();
      await elapse(const Duration(seconds: 9));

      stt.hear('What is on the telly tonight?');
      await pumpEventQueue();
      expect(brain.turns, isEmpty);
      expect(loop.state.flame, FlameState.waiting);

      brain.replies.add([text('Heat the pan.'), done('end_turn')]);
      stt.hear('Hey Sue Chef, what next?');
      await pumpEventQueue();
      expect(brain.turns.single, {'text': 'what next?'});
      expect(tts.said.last, 'Heat the pan.');
      await playOut();
    });

    test('"Hey Sous" on its own opens a turn for the next words', () async {
      await loop.start();
      await playOut();
      await elapse(const Duration(seconds: 9));

      stt.hear('Hey Sous.');
      await pumpEventQueue();
      expect(brain.turns, isEmpty);

      brain.replies.add([text('Twelve minutes.'), done('end_turn')]);
      stt.hear('How long for the rice?');
      await pumpEventQueue();
      expect(brain.turns.single, {'text': 'How long for the rice?'});
      await playOut();
    });

    test('a tap opens a turn', () async {
      await loop.start();
      await playOut();
      await elapse(const Duration(seconds: 9));

      await loop.openTurn();
      brain.replies.add([text('Twelve minutes.'), done('end_turn')]);
      stt.hear('How long for the rice?');
      await pumpEventQueue();
      expect(brain.turns.single, {'text': 'How long for the rice?'});
      await playOut();
    });

    test('Sous finishing a reply does not open a turn, so the room can '
        'never keep the conversation going', () async {
      await loop.start();
      await playOut();
      stt.hear('Yeah.');
      await pumpEventQueue();
      stt.hear('With the table.');
      await pumpEventQueue();
      expect(brain.turns, isEmpty);
      expect(loop.state.flame, FlameState.waiting);
    });

    test('the wake word engine opens a turn and silences Sous', () async {
      final wake = FakeWakeWord();
      loop = build(const VoiceLoopSettings(), wake);
      await loop.start();
      await pumpEventQueue();
      expect(audio.isPlaying, isTrue);
      audio.mic.add(Float32List(320));
      await pumpEventQueue();
      expect(wake.samples, 320);

      wake.fire();
      await pumpEventQueue();
      expect(audio.isPlaying, isFalse);
      now = now.add(const Duration(seconds: 1));

      brain.replies.add([text('Next, the onion.'), done('end_turn')]);
      stt.hear('Next step?');
      await pumpEventQueue();
      expect(brain.turns.single, {'text': 'Next step?'});
      await playOut();
    });
  });

  group('awaiting "Heard"', () {
    const short = 'Chef, rice, twelve minutes. Heard?';

    test('repeats after about ten seconds, thirty, then every minute, '
        'until the chef answers', () async {
      await loop.start();
      await playOut();
      brain.replies.add([
        text('Chef, the recipe says twelve minutes. Set it?'),
        doneAwaiting(short),
      ]);
      await loop.openTurn();
      stt.hear('Rice is in.');
      await pumpEventQueue();
      await playOut();
      expect(session.state.awaitingAck?.short, short);

      await elapse(const Duration(seconds: 8));
      expect(repeatsOf(short), 0);
      await elapse(const Duration(seconds: 2));
      expect(repeatsOf(short), 1);
      await playOut();

      await elapse(const Duration(seconds: 28));
      expect(repeatsOf(short), 1);
      await elapse(const Duration(seconds: 2));
      expect(repeatsOf(short), 2);
      await playOut();

      for (var n = 3; n <= 5; n++) {
        await elapse(const Duration(seconds: 58));
        expect(repeatsOf(short), n - 1);
        await elapse(const Duration(seconds: 2));
        expect(repeatsOf(short), n);
        await playOut();
      }

      await elapse(const Duration(seconds: 20));
      brain.replies.add([done('end_turn')]);
      stt.hear('Heard.');
      await pumpEventQueue();
      expect(brain.turns.last, {'text': 'Heard.'});
      expect(session.state.awaitingAck, isNull);
      await elapse(const Duration(minutes: 5));
      expect(repeatsOf(short), 5);
    });

    test('a tap stops the repeats', () async {
      await loop.start();
      await playOut();
      brain.replies.add([text('Set it?'), doneAwaiting(short)]);
      await loop.openTurn();
      stt.hear('Rice is in.');
      await pumpEventQueue();
      await playOut();

      await loop.openTurn();
      await elapse(const Duration(minutes: 3));
      expect(repeatsOf(short), 0);
    });

    test('an empty done means stay silent and wait', () async {
      await loop.start();
      await playOut();
      final said = tts.said.length;
      brain.replies.add([done('end_turn')]);
      await loop.openTurn();
      stt.hear('Heard, Chef.');
      await pumpEventQueue();
      await pumpEventQueue();

      expect(brain.turns.single, {'text': 'Heard, Chef.'});
      expect(tts.said, hasLength(said));
      expect(audio.isPlaying, isFalse);
      expect(loop.state.flame, FlameState.waiting);
      await elapse(const Duration(minutes: 3));
      expect(tts.said, hasLength(said));
    });
  });

  group('needs the chef', () {
    const rice = TimerFinished(timerId: 'timer-1', label: 'rice');
    final riceEvent = {
      'type': 'timer_finished',
      'timer_id': 'timer-1',
      'label': 'rice',
    };

    test('a finished timer turns the flame red and chimes without '
        'speaking, and goes with the next tap', () async {
      await loop.start();
      await playOut();
      final said = tts.said.length;

      session.notify(rice);
      await pumpEventQueue();
      expect(loop.state.flame, FlameState.needsChef);
      expect(audio.chimes, 1);
      await playOut();
      await elapse(const Duration(seconds: 8));
      expect(audio.chimes, 2);
      await playOut();
      expect(tts.said, hasLength(said));
      expect(brain.turns, isEmpty);

      brain.replies.add([
        text('Chef, the rice is done. Off the heat?'),
        doneAwaiting('Chef, rice off the heat. Heard?'),
      ]);
      await loop.openTurn();
      await pumpEventQueue();
      expect(brain.turns.single, {
        'events': [riceEvent],
      });
      expect(tts.said.last, 'Off the heat?');
      expect(loop.state.flame, isNot(FlameState.needsChef));
      await playOut();
      final chimes = audio.chimes;
      await elapse(const Duration(seconds: 30));
      expect(audio.chimes, chimes);
    });

    test('"Hey Sous" with words sends the words and the events '
        'together', () async {
      await loop.start();
      await playOut();
      session.notify(rice);
      await pumpEventQueue();
      await playOut();

      brain.replies.add([text('The rice is done, Chef.'), done('end_turn')]);
      stt.hear('Hey Sous, what was that?');
      await pumpEventQueue();
      expect(brain.turns.single, {
        'text': 'what was that?',
        'events': [riceEvent],
      });
      await playOut();
    });

    test('stop words silence Sous but never cancel timers, skip steps or '
        'drop what the chef still needs to hear', () async {
      final kitchen = FakeKitchen();
      await session.dispose();
      session = CookingSession(brain: brain.brainClient, tools: kitchen);
      await session.start('recipe-example-1');
      loop = build();
      await loop.start();
      await playOut();

      final slow = SlowReply();
      brain.replies
        ..add([
          tool('t1', 'start_timer', {'label': 'rice', 'seconds': 720}),
          tool('t2', 'go_to_step', {'index': 1}),
          done('tool_use'),
        ])
        ..add(slow.response);
      stt.hear('Hey Sous, start the rice.');
      await pumpEventQueue();
      slow.send(text('Rice is on for twelve minutes. Now chop the onion. '));
      await pumpEventQueue();
      expect(audio.isPlaying, isTrue);
      session.notify(rice);

      for (final word in ['Hold.', 'Wait.', 'Stop.']) {
        stt.hear(word);
        await pumpEventQueue();
        expect(audio.isPlaying, isFalse, reason: word);
      }
      slow.send(done('end_turn'));
      await slow.close();
      await pumpEventQueue();

      expect(kitchen.log, ['start rice 720', 'step 1']);
      expect(session.state.stepIndex, 1);
      expect(session.state.needsChef, isTrue);
      expect(brain.turns, hasLength(2));
      expect(loop.state.flame, FlameState.needsChef);
    });
  });

  test('knows the wake word and acknowledgements', () {
    expect(afterWakePhrase('Hey Sous, next step'), 'next step');
    expect(afterWakePhrase('hey sue chef'), '');
    expect(afterWakePhrase('Hey, Sue. How long?'), 'How long?');
    expect(afterWakePhrase('Sous, next step'), isNull);
    expect(afterWakePhrase('They sued the chef'), isNull);
    for (final phrase in [
      'Heard',
      'Heard, Chef.',
      'Yes, Chef',
      'Got it, Chef',
    ]) {
      expect(isAcknowledgement(phrase), isTrue, reason: phrase);
    }
    for (final phrase in ['Yeah.', 'Heard you were at the match today']) {
      expect(isAcknowledgement(phrase), isFalse, reason: phrase);
    }
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
