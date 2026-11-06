import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_io.dart';

/// Two soft bell notes, rising: what Sous plays instead of speaking first.
AudioChunk chime({int sampleRate = 24000, double volume = .35}) {
  const notes = [(hz: 880.0, at: 0.0), (hz: 1318.5, at: .16)];
  const length = .9;
  final samples = Float32List((length * sampleRate).round());
  for (var i = 0; i < samples.length; i++) {
    final t = i / sampleRate;
    var v = 0.0;
    for (final n in notes) {
      final s = t - n.at;
      if (s < 0) continue;
      final attack = math.min(1.0, s / .008);
      final decay = math.exp(-s * 5.5);
      v +=
          attack *
          decay *
          (math.sin(2 * math.pi * n.hz * s) +
              .25 * math.sin(4 * math.pi * n.hz * s));
    }
    samples[i] = (v * volume / 1.25).clamp(-1.0, 1.0);
  }
  return AudioChunk(samples, sampleRate);
}
