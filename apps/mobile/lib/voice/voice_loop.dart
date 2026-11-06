import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../api/session.dart';
import '../cooking/cooking_session.dart';
import '../cooking/kitchen_timers.dart';
import 'audio_io.dart';
import 'chime.dart';
import 'sentences.dart';
import 'speakable.dart';
import 'speech_to_text.dart';
import 'text_to_speech.dart';
import 'wake_word.dart';

/// How long Sous waits before repeating an instruction the chef hasn't
/// answered: about ten seconds, then thirty, then every minute. The last gap
/// repeats until the chef opens a turn.
const ackRepeatGaps = [
  Duration(seconds: 10),
  Duration(seconds: 30),
  Duration(minutes: 1),
];

/// How Sous handles the cook talking while Sous is talking.
enum DuplexMode {
  /// Sous doesn't take what it hears while speaking as a new turn, since that
  /// is mostly its own voice coming back. A tap ([VoiceLoop.silence]) or
  /// "Hold", "Wait", "Stop" or "Hey Sous" cut Sous off.
  half,

  /// The mic stays open while Sous speaks and any speech cuts Sous off
  /// (barge-in), then goes to Sous once its reply is done. Needs echo cancellation that really takes Sous's voice out of
  /// the mic, or Sous keeps interrupting itself.
  full,
}

enum VoiceStatus {
  off,

  /// Loading engines and opening the mic.
  starting,

  /// Waiting for the cook.
  listening,

  /// The cook is talking.
  hearing,

  /// The cook's words are with the brain and Sous hasn't started speaking.
  thinking,
  speaking,

  /// The loop couldn't start. [VoiceState.error] says why.
  failed,
}

/// What the flame shows, in the kitchen protocol's words.
enum FlameState {
  waiting,
  chefSpeaking,
  thinking,
  sousTalking,

  /// Red: something on the phone, like a finished timer, is waiting for the
  /// chef to say "Hey Sous" or tap.
  needsChef,
}

class VoiceState {
  const VoiceState({
    this.status = VoiceStatus.off,
    this.partial = '',
    this.heard,
    this.error,
    this.needsChef = false,
  });

  final VoiceStatus status;

  /// Sous has kitchen events queued for the chef's next turn.
  final bool needsChef;

  FlameState get flame => switch (status) {
    VoiceStatus.hearing => FlameState.chefSpeaking,
    VoiceStatus.thinking => FlameState.thinking,
    VoiceStatus.speaking => FlameState.sousTalking,
    _ => needsChef ? FlameState.needsChef : FlameState.waiting,
  };

  /// What the cook is saying right now, from engines that report it.
  final String partial;

  /// The last thing the cook said that went to Sous.
  final String? heard;
  final Object? error;
}

class VoiceException implements Exception {
  const VoiceException(this.message);

  final String message;

  @override
  String toString() => 'VoiceException: $message';
}

class VoiceLoopSettings {
  const VoiceLoopSettings({
    this.duplex = DuplexMode.half,
    this.echoCancel = true,
    this.stopWordsWhileSpeaking = true,
    this.echoTail = const Duration(milliseconds: 400),
    this.listenFor = const Duration(seconds: 8),
    this.repeatGaps = ackRepeatGaps,
    this.chimeEvery = const Duration(seconds: 8),
  });

  final DuplexMode duplex;

  /// Captures through the platform's voice-processing path.
  final bool echoCancel;

  /// In half duplex, keeps listening while Sous speaks, but only for "stop",
  /// "wait" and the like.
  final bool stopWordsWhileSpeaking;

  /// How long after Sous stops that the mic may still be hearing Sous.
  final Duration echoTail;

  /// How long after "Hey Sous" or a tap the chef's words still go to Sous,
  /// so they can pause or add to what they said.
  final Duration listenFor;

  /// See [ackRepeatGaps].
  final List<Duration> repeatGaps;

  /// How often the chime plays while Sous needs the chef.
  final Duration chimeEvery;
}

/// The spoken conversation, following the kitchen protocol: a turn opens
/// only on "Hey Sous" or a tap, what the chef says goes to the
/// [CookingSession], Sous's reply is spoken sentence by sentence while it
/// streams, unanswered instructions repeat like an alarm clock, and when the
/// phone needs the chef the flame goes red and a chime plays instead of
/// speech. Works with any [AudioIO], [SpeechToText], [TextToSpeech] and
/// [WakeWord].
class VoiceLoop {
  VoiceLoop({
    required this._audio,
    required this._speechToText,
    required this._textToSpeech,
    required this._session,
    this._wakeWord,
    this.settings = const VoiceLoopSettings(),
    DateTime Function()? clock,
    StartTimer? startTimer,
  }) : _clock = clock ?? DateTime.now,
       _startTimer = startTimer ?? Timer.new;

  final AudioIO _audio;
  final SpeechToText _speechToText;
  final TextToSpeech _textToSpeech;
  final CookingSession _session;
  final WakeWord? _wakeWord;
  final DateTime Function() _clock;
  final StartTimer _startTimer;
  final VoiceLoopSettings settings;

  final _states = StreamController<VoiceState>.broadcast();
  var _state = const VoiceState();

  StreamSubscription<Float32List>? _mic;
  StreamSubscription<SpeechEvent>? _speech;
  StreamSubscription<CookingState>? _replies;
  StreamSubscription<void>? _wake;
  var _running = false;

  final _splitter = SentenceSplitter();
  var _consumed = 0;
  var _muted = false;

  final _queue = Queue<Future<AudioChunk?>>();
  Future<Object?> _synthesis = Future.value();
  var _speakGeneration = 0;
  var _pumping = false;
  var _playing = false;
  DateTime? _playedUntil;

  var _hearing = false;
  var _overlapsSous = false;
  String? _pending;

  DateTime? _openUntil;
  var _speechInTurn = false;
  var _wantsEvents = false;

  AwaitingAck? _ack;
  AwaitingAck? _ackAnswered;
  var _repeats = 0;
  Timer? _repeat;

  Timer? _chimer;
  late final _chime = chime();

  VoiceState get state => _state;

  /// Every change to [state], starting after the current one.
  Stream<VoiceState> get states => _states.stream;

  bool get running => _running;

  /// Opens the mic and starts the conversation. Speaks Sous's opening line if
  /// the session has only just started.
  Future<void> start() async {
    if (_running || _state.status == VoiceStatus.starting) return;
    _emit(const VoiceState(status: VoiceStatus.starting));
    try {
      if (!await _audio.requestPermission()) {
        throw const VoiceException('Microphone permission was refused');
      }
      await _speechToText.init();
      await _textToSpeech.init();
      final mic = await _audio.startCapture(
        sampleRate: _speechToText.sampleRate,
        echoCancel: settings.echoCancel,
      );
      final wakeWord = _wakeWord;
      if (wakeWord != null && wakeWord.sampleRate == _speechToText.sampleRate) {
        try {
          await wakeWord.init();
          _wake = wakeWord.heard.listen((_) => _onWake());
        } on Object catch (e) {
          _report(e);
        }
      }
      _running = true;
      final current = _session.state;
      _consumed = current.transcript.length <= 1 ? 0 : current.reply.length;
      _muted = false;
      _splitter.clear();
      _speech = _speechToText.events.listen(_onSpeech);
      _replies = _session.states.listen(_onSession);
      _mic = mic.listen(_onAudio);
      _onSession(current);
    } on Object catch (e) {
      _running = false;
      await _teardown();
      _emit(VoiceState(status: VoiceStatus.failed, error: e));
    }
  }

  /// Closes the mic and goes quiet. The cooking session carries on.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _repeat?.cancel();
    _chimer?.cancel();
    _repeat = _chimer = null;
    await _stopSpeaking();
    await _teardown();
    _emit(const VoiceState());
  }

  /// A tap on the flame: the same as the chef saying "Hey Sous". Silences
  /// Sous if it's talking, stops any repeats, sends whatever the phone has
  /// queued for the chef, and listens for the chef's words.
  Future<void> openTurn() async {
    if (_running) _open(wordsComing: false);
  }

  /// Stops Sous mid-sentence: a tap on the flame, or the chef saying "Hold",
  /// "Wait", "Stop" or "Hey Sous". The rest of this reply isn't spoken, but
  /// the brain still finishes it, so timers and steps in it still happen.
  Future<void> silence() async {
    _muted = true;
    _splitter.clear();
    await _stopSpeaking();
    _update();
  }

  /// [silence], and also cancels the reply that's streaming
  /// ([CookingSession.interrupt]), for when it should be abandoned.
  Future<void> interrupt() async {
    _muted = true;
    _splitter.clear();
    _session.interrupt();
    await _stopSpeaking();
    _update();
  }

  Future<void> dispose() async {
    await stop();
    await _states.close();
  }

  Future<void> _teardown() async {
    await _mic?.cancel();
    await _speech?.cancel();
    await _replies?.cancel();
    await _wake?.cancel();
    _mic = _speech = _replies = _wake = null;
    _hearing = false;
    _pending = null;
    _wantsEvents = false;
    _openUntil = null;
    await _audio.stopCapture();
    _speechToText.reset();
    _wakeWord?.reset();
  }

  void _onAudio(Float32List samples) {
    if (_wake != null) _wakeWord!.accept(samples);
    if (settings.duplex == DuplexMode.half &&
        !settings.stopWordsWhileSpeaking &&
        _sousAudible) {
      return;
    }
    _speechToText.accept(samples);
  }

  bool get _sousAudible {
    if (_playing) return true;
    final until = _playedUntil;
    return until != null && _clock().isBefore(until.add(settings.echoTail));
  }

  bool get _sousSpeaking => _playing || _queue.isNotEmpty;

  bool get _sessionBusy => switch (_session.state.phase) {
    CookingPhase.thinking ||
    CookingPhase.replying ||
    CookingPhase.runningTools => true,
    _ => false,
  };

  bool get _turnOpen {
    final until = _openUntil;
    return until != null && _clock().isBefore(until);
  }

  void _keepListening() => _openUntil = _clock().add(settings.listenFor);

  void _onWake() {
    if (_running) _open(wordsComing: _hearing);
  }

  /// "Hey Sous" or a tap. When [wordsComing], the chef is still mid-sentence
  /// and the queued events go with their words instead of on their own.
  void _open({required bool wordsComing}) {
    _stopRepeating(answered: true);
    _keepListening();
    if (_sousSpeaking) unawaited(silence());
    if (!wordsComing) _wantsEvents = true;
    _sendPending();
    _update();
  }

  void _onSpeech(SpeechEvent event) {
    if (!_running) return;
    switch (event) {
      case SpeechStarted():
        _hearing = true;
        _speechInTurn = _turnOpen;
        _overlapsSous = _sousAudible;
        if (settings.duplex == DuplexMode.full && _sousSpeaking) {
          unawaited(silence());
        }
      case PartialTranscript(:final text):
        _emit(_copy(partial: text));
      case FinalTranscript(:final text):
        final overlaps = _overlapsSous;
        final inTurn = _speechInTurn || _turnOpen;
        _hearing = false;
        _overlapsSous = false;
        _speechInTurn = false;
        _emit(_copy(partial: ''));
        _onUtterance(text.trim(), overlapsSous: overlaps, inTurn: inTurn);
    }
    _update();
  }

  /// "Hey Sous" opens a turn and silences Sous. Stop words silence Sous.
  /// Anything else counts only inside an open turn, or as an answer to an
  /// instruction Sous is waiting on, and goes to Sous once it has finished
  /// the reply it's on, so nothing it was doing gets skipped.
  void _onUtterance(
    String text, {
    required bool overlapsSous,
    required bool inTurn,
  }) {
    if (text.isEmpty) return;
    final afterWake = afterWakePhrase(text);
    if (afterWake != null) {
      final words = isStopCommand(afterWake) ? '' : afterWake;
      _open(wordsComing: words.isNotEmpty);
      if (words.isNotEmpty) _take(words);
      return;
    }
    if ((_sousSpeaking || _sessionBusy) && isStopCommand(text)) {
      unawaited(silence());
      return;
    }
    if (overlapsSous && settings.duplex == DuplexMode.half) return;
    final answersSous =
        _session.state.awaitingAck != null && isAcknowledgement(text);
    if (!inTurn && !answersSous) return;
    _stopRepeating(answered: true);
    if (_sousSpeaking) unawaited(silence());
    _take(text);
  }

  void _take(String text) {
    _pending = _pending == null ? text : '$_pending $text';
    _sendPending();
  }

  void _sendPending() {
    if (!_session.state.canSpeak) return;
    final text = _pending;
    final events = _wantsEvents && _session.state.needsChef;
    _wantsEvents = false;
    if (text == null && !events) return;
    _pending = null;
    if (text != null) _emit(_copy(heard: text));
    unawaited(_session.send(text: text).catchError((Object e) => _report(e)));
  }

  /// Repeats the instruction Sous is waiting on, after the next gap in
  /// [VoiceLoopSettings.repeatGaps], until the chef opens a turn.
  void _scheduleRepeat() {
    final ack = _session.state.awaitingAck;
    if (!_running ||
        ack == null ||
        identical(ack, _ackAnswered) ||
        _repeat != null ||
        _sousSpeaking ||
        !_session.state.canSpeak) {
      return;
    }
    if (!identical(ack, _ack)) {
      _ack = ack;
      _repeats = 0;
    }
    final gaps = settings.repeatGaps;
    _repeat = _startTimer(gaps[math.min(_repeats, gaps.length - 1)], () {
      _repeat = null;
      if (!_running || !identical(_session.state.awaitingAck, ack)) return;
      if (identical(ack, _ackAnswered)) return;
      if (_hearing || _sousSpeaking || !_session.state.canSpeak) {
        _scheduleRepeat();
        return;
      }
      _repeats++;
      _speak(ack.short);
    });
  }

  void _stopRepeating({bool answered = false}) {
    _repeat?.cancel();
    _repeat = null;
    if (answered) _ackAnswered = _session.state.awaitingAck;
  }

  /// Plays the chime now and every [VoiceLoopSettings.chimeEvery] while the
  /// phone needs the chef. Sous never speaks first, so this is all it does.
  void _syncChime(bool needed) {
    if (!needed || !_running) {
      _chimer?.cancel();
      _chimer = null;
    } else if (_chimer == null) {
      _ring();
    }
  }

  void _ring() {
    _chimer = _startTimer(settings.chimeEvery, _ring);
    if (_sousSpeaking || _hearing || _sessionBusy) return;
    _playedUntil = _clock().add(_chime.duration);
    unawaited(_audio.play(_chime).catchError((Object e) => _report(e)));
  }

  void _onSession(CookingState s) {
    if (!_running) return;
    final reply = s.reply;
    if (s.phase == CookingPhase.thinking && reply.isEmpty) {
      _consumed = 0;
      _muted = false;
      _splitter.clear();
    }
    if (reply.length < _consumed) _consumed = reply.length;
    if (!_muted && reply.length > _consumed) {
      _splitter.add(reply.substring(_consumed)).forEach(_speak);
    }
    _consumed = reply.length;
    if (!_muted &&
        s.phase != CookingPhase.thinking &&
        s.phase != CookingPhase.replying) {
      final rest = _splitter.flush();
      if (rest != null) _speak(rest);
    }
    if (s.awaitingAck == null || !identical(s.awaitingAck, _ack)) {
      _stopRepeating();
    }
    if (s.canSpeak) _sendPending();
    if (s.canSpeak && !_sousSpeaking) _scheduleRepeat();
    _syncChime(s.needsChef);
    _update();
  }

  void _speak(String sentence) {
    final text = speakable(sentence);
    if (text.isEmpty) return;
    final generation = _speakGeneration;
    final audio = _synthesis.then((_) async {
      if (generation != _speakGeneration) return null;
      try {
        return await _textToSpeech.synthesize(text);
      } on Object catch (e) {
        _report(e);
        return null;
      }
    });
    _synthesis = audio;
    _queue.add(audio);
    if (!_pumping) unawaited(_pump());
    _update();
  }

  Future<void> _pump() async {
    _pumping = true;
    final generation = _speakGeneration;
    while (_queue.isNotEmpty && generation == _speakGeneration) {
      final chunk = await _queue.first;
      if (generation != _speakGeneration) return;
      _queue.removeFirst();
      if (chunk == null || chunk.samples.isEmpty) continue;
      _playing = true;
      if (_hearing) _overlapsSous = true;
      _update();
      try {
        await _audio.play(chunk);
      } on Object catch (e) {
        _report(e);
      }
      if (generation != _speakGeneration) return;
      _playing = false;
      _playedUntil = _clock();
    }
    _pumping = false;
    if (_running && _queue.isEmpty) _scheduleRepeat();
    _update();
  }

  Future<void> _stopSpeaking() async {
    _speakGeneration++;
    _queue.clear();
    _pumping = false;
    final wasPlaying = _playing;
    _playing = false;
    if (wasPlaying) _playedUntil = _clock();
    await _audio.stopPlayback();
  }

  void _update() {
    if (!_running) return;
    final chefTalking =
        _hearing &&
        !(_overlapsSous && _sousSpeaking) &&
        (_speechInTurn || _turnOpen);
    final status = chefTalking
        ? VoiceStatus.hearing
        : _sousSpeaking
        ? VoiceStatus.speaking
        : _sessionBusy || _pending != null
        ? VoiceStatus.thinking
        : VoiceStatus.listening;
    final needsChef = _session.state.needsChef;
    if (status != _state.status || needsChef != _state.needsChef) {
      _emit(_copy(status: status, needsChef: needsChef));
    }
  }

  void _report(Object error) => _emit(_copy(error: error));

  VoiceState _copy({
    VoiceStatus? status,
    String? partial,
    String? heard,
    Object? error,
    bool? needsChef,
  }) => VoiceState(
    status: status ?? _state.status,
    partial: partial ?? _state.partial,
    heard: heard ?? _state.heard,
    error: error ?? _state.error,
    needsChef: needsChef ?? _state.needsChef,
  );

  void _emit(VoiceState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }
}

/// Whether [text] is the chef answering an instruction on its own:
/// "Heard", "Yes, Chef", "Got it, Chef" and the like. It's strict, since it
/// lets words through without "Hey Sous" and a busy kitchen says "yeah" a
/// lot. The brain decides whether it really closes the instruction.
bool isAcknowledgement(String text) {
  final words = text
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z' ]"), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  return words.length <= 4 && _acknowledgement.hasMatch(words.join(' '));
}

final _acknowledgement = RegExp(
  r"^(?:heard|yes chef|oui chef|got it chef|understood|copy that)\b",
);

/// Whether [text] is the cook asking Sous to stop talking.
bool isStopCommand(String text) {
  final words = text
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z' ]"), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty && !_fillers.contains(w))
      .join(' ');
  return _stopPhrases.contains(words);
}

const _fillers = {
  'sous',
  'sue',
  'chef',
  'please',
  'ok',
  'okay',
  'oh',
  'um',
  'uh',
};

const _stopPhrases = {
  'hey',
  'hold',
  'hold it',
  'stop',
  'stop stop',
  'stop it',
  'stop talking',
  'wait',
  'wait wait',
  'hang on',
  'hold on',
  'pause',
  'shh',
  'shush',
  'quiet',
  'be quiet',
  'enough',
};
