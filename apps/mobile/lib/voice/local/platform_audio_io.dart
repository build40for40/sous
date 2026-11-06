import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../audio_io.dart';

/// The mic through `record` (16-bit PCM, voice communication source and
/// speakerphone on Android, voice processing on iOS when [startCapture] asks
/// for echo cancellation), and playback through `audioplayers` in a
/// play-and-record session so the mic keeps running while Sous talks.
class PlatformAudioIO implements AudioIO {
  PlatformAudioIO();

  late final _recorder = AudioRecorder();
  late final _player = AudioPlayer(playerId: 'sous-voice');
  Completer<void>? _playing;
  StreamSubscription<void>? _completions;
  var _clip = 0;
  var _configured = false;

  Future<void> _configure() async {
    if (_configured) return;
    _configured = true;
    await _player.setReleaseMode(ReleaseMode.stop);
    await _player.setAudioContext(
      AudioContext(
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playAndRecord,
          options: const {
            AVAudioSessionOptions.defaultToSpeaker,
            AVAudioSessionOptions.allowBluetooth,
            AVAudioSessionOptions.allowBluetoothA2DP,
          },
        ),
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.voiceCommunication,
          audioMode: AndroidAudioMode.inCommunication,
          audioFocus: AndroidAudioFocus.none,
        ),
      ),
    );
    _completions = _player.onPlayerComplete.listen((_) => _finish());
  }

  @override
  Future<bool> requestPermission() async {
    await _configure();
    return _recorder.hasPermission();
  }

  @override
  Future<Stream<Float32List>> startCapture({
    required int sampleRate,
    required bool echoCancel,
  }) async {
    await _configure();
    final pcm = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        echoCancel: echoCancel,
        noiseSuppress: echoCancel,
        audioInterruption: AudioInterruptionMode.pauseResume,
        androidConfig: AndroidRecordConfig(
          audioSource: echoCancel
              ? AndroidAudioSource.voiceCommunication
              : AndroidAudioSource.voiceRecognition,
          speakerphone: true,
          audioManagerMode: AudioManagerMode.modeInCommunication,
        ),
      ),
    );
    return pcm.map(pcm16ToFloat);
  }

  @override
  Future<void> stopCapture() async {
    if (!_configured) return;
    if (await _recorder.isRecording()) await _recorder.stop();
  }

  @override
  Future<void> play(AudioChunk chunk) async {
    await _configure();
    await stopPlayback();
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/sous-voice-${_clip++ % 4}.wav');
    await file.writeAsBytes(wav(chunk), flush: true);
    final done = Completer<void>();
    _playing = done;
    await _player.play(DeviceFileSource(file.path));
    return done.future;
  }

  void _finish() {
    final done = _playing;
    _playing = null;
    if (done != null && !done.isCompleted) done.complete();
  }

  @override
  Future<void> stopPlayback() async {
    if (_playing == null) return;
    _finish();
    await _player.stop();
  }

  @override
  Future<void> dispose() async {
    if (!_configured) return;
    await stopPlayback();
    await stopCapture();
    await _completions?.cancel();
    await _player.dispose();
    await _recorder.dispose();
  }
}

/// Little-endian 16-bit PCM to floats between -1 and 1.
Float32List pcm16ToFloat(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final out = Float32List(bytes.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768;
  }
  return out;
}

/// [chunk] as a 16-bit mono WAV file.
Uint8List wav(AudioChunk chunk) {
  final samples = chunk.samples;
  final bytes = ByteData(44 + samples.length * 2);
  void ascii(int at, String text) {
    for (var i = 0; i < text.length; i++) {
      bytes.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + samples.length * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, chunk.sampleRate, Endian.little);
  bytes.setUint32(28, chunk.sampleRate * 2, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final s = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    bytes.setInt16(44 + i * 2, s, Endian.little);
  }
  return bytes.buffer.asUint8List();
}
