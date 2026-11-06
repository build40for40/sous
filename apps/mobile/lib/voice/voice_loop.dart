import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../cooking/cooking_session.dart';
import 'audio_io.dart';
import 'sentences.dart';
import 'speakable.dart';
import 'speech_to_text.dart';
import 'text_to_speech.dart';

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

class VoiceState {
  const VoiceState({
    this.status = VoiceStatus.off,
    this.partial = '',
    this.heard,
    this.error,
  });

  final VoiceStatus status;

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
  });

  final DuplexMode duplex;

  /// Captures through the platform's voice-processing path.
  final bool echoCancel;

  /// In half duplex, keeps listening while Sous speaks, but only for "stop",
  /// "wait" and the like.
  final bool stopWordsWhileSpeaking;

  /// How long after Sous stops that the mic may still be hearing Sous.
  final Duration echoTail;
}

/// The spoken conversation: hears the cook, sends what they said to the
/// [CookingSession], speaks Sous's reply sentence by sentence while it
/// streams, and stops when the chef cuts in. Works with any [AudioIO],
/// [SpeechToText] and [TextToSpeech].
class VoiceLoop {
  VoiceLoop({
    required this._audio,
    required this._speechToText,
    required this._textToSpeech,
    required this._session,
    this.settings = const VoiceLoopSettings(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AudioIO _audio;
  final SpeechToText _speechToText;
  final TextToSpeech _textToSpeech;
  final CookingSession _session;
  final DateTime Function() _clock;
  final VoiceLoopSettings settings;

  final _states = StreamController<VoiceState>.broadcast();
  var _state = const VoiceState();

  StreamSubscription<Float32List>? _mic;
  StreamSubscription<SpeechEvent>? _speech;
  StreamSubscription<CookingState>? _replies;
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
    await _stopSpeaking();
    await _teardown();
    _emit(const VoiceState());
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
    _mic = _speech = _replies = null;
    _hearing = false;
    _pending = null;
    await _audio.stopCapture();
    _speechToText.reset();
  }

  void _onAudio(Float32List samples) {
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

  void _onSpeech(SpeechEvent event) {
    if (!_running) return;
    switch (event) {
      case SpeechStarted():
        _hearing = true;
        _overlapsSous = _sousAudible;
        if (settings.duplex == DuplexMode.full && _sousSpeaking) {
          unawaited(silence());
        }
      case PartialTranscript(:final text):
        _emit(_copy(partial: text));
      case FinalTranscript(:final text):
        final overlaps = _overlapsSous;
        _hearing = false;
        _overlapsSous = false;
        _emit(_copy(partial: ''));
        _onUtterance(text.trim(), overlaps);
    }
    _update();
  }

  /// Stop words silence Sous. Anything else goes to Sous once it has
  /// finished the reply it's on, so nothing it was doing gets skipped.
  void _onUtterance(String text, bool overlapsSous) {
    if (text.isEmpty) return;
    if ((_sousSpeaking || _sessionBusy) && isStopCommand(text)) {
      unawaited(silence());
      return;
    }
    if (overlapsSous && settings.duplex == DuplexMode.half) return;
    if (_sousSpeaking) unawaited(silence());
    _pending = _pending == null ? text : '$_pending $text';
    _sendPending();
  }

  void _sendPending() {
    final text = _pending;
    if (text == null || !_session.state.canSpeak) return;
    _pending = null;
    _emit(_copy(heard: text));
    unawaited(_session.say(text).catchError((Object e) => _report(e)));
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
    if (s.canSpeak) _sendPending();
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
    final status = _hearing && !(_overlapsSous && _sousSpeaking)
        ? VoiceStatus.hearing
        : _sousSpeaking
        ? VoiceStatus.speaking
        : _sessionBusy || _pending != null
        ? VoiceStatus.thinking
        : VoiceStatus.listening;
    if (status != _state.status) _emit(_copy(status: status));
  }

  void _report(Object error) => _emit(_copy(error: error));

  VoiceState _copy({
    VoiceStatus? status,
    String? partial,
    String? heard,
    Object? error,
  }) => VoiceState(
    status: status ?? _state.status,
    partial: partial ?? _state.partial,
    heard: heard ?? _state.heard,
    error: error ?? _state.error,
  );

  void _emit(VoiceState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }
}

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
