import 'dart:math' as math;

import 'package:flutter/material.dart';

/// What the flame is showing.
enum FlameMood { idle, listening, thinking, talking }

/// How much Sous needs the cook: blue normally, orange for a heads-up, red
/// for an alarm that repeats until the cook says "Heard".
enum FlameAlert { none, headsUp, alarm }

/// Sous's face: a gas burner seen from above, a ring of blue fire around a
/// dark iron cap. It pulses gently while Sous listens, thinks or talks.
class Flame extends StatefulWidget {
  const Flame({
    super.key,
    this.mood = FlameMood.idle,
    this.alert = FlameAlert.none,
  });

  final FlameMood mood;
  final FlameAlert alert;

  @override
  State<Flame> createState() => _FlameState();
}

class _FlameState extends State<Flame> with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(hours: 1),
  )..forward();

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _clock,
        builder: (context, _) {
          final seconds =
              (_clock.lastElapsedDuration?.inMilliseconds ?? 0) / 1000;
          return CustomPaint(
            painter: _FlamePainter(
              t: seconds,
              mood: widget.mood,
              alert: widget.alert,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _Palette {
  const _Palette(this.deep, this.mid, this.hot);

  final Color deep;
  final Color mid;
  final Color hot;

  static const blue = _Palette(
    Color(0xFF060A2C),
    Color(0xFF1747D9),
    Color(0xFFA0D6FF),
  );
  static const orange = _Palette(
    Color(0xFF2B1202),
    Color(0xFFFF7A10),
    Color(0xFFFFC77A),
  );
  static const red = _Palette(
    Color(0xFF330303),
    Color(0xFFF2140C),
    Color(0xFFFF8C7A),
  );
}

class _FlamePainter extends CustomPainter {
  _FlamePainter({required this.t, required this.mood, required this.alert});

  final double t;
  final FlameMood mood;
  final FlameAlert alert;

  /// A soft, steady pulse from 0 to 1, like other voice assistants.
  double get _pulse {
    double wave(double period) => .5 + .5 * math.sin(t * 2 * math.pi / period);
    return switch (alert) {
      // A sharp flash once a second, in time with the alarm
      FlameAlert.alarm => math.exp(-((t % .9) / .16)),
      FlameAlert.headsUp => .15 + .2 * wave(4.4),
      FlameAlert.none => switch (mood) {
        FlameMood.idle => .05 * wave(6),
        FlameMood.listening => .35 * wave(1.75),
        FlameMood.thinking => .25 * wave(2.6),
        FlameMood.talking => .4 * wave(1.5),
      },
    };
  }

  _Palette get _palette => switch (alert) {
    FlameAlert.none => _Palette.blue,
    FlameAlert.headsUp => _Palette.orange,
    FlameAlert.alarm => _Palette.red,
  };

  // Cheap smooth noise from a few sines, so each jet drifts on its own.
  double _drift(int i, double speed) {
    final a = math.sin(i * 1.73 + t * speed);
    final b = math.sin(i * .61 - t * speed * .63 + 1.7);
    return .5 + .25 * a + .25 * b;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final c = Offset(size.width / 2, size.height / 2);
    final r = side * .3;
    final p = _palette;
    final pulse = _pulse;
    final glow = Paint()..blendMode = BlendMode.plus;

    // Haze breathing around the ring
    glow.shader = RadialGradient(
      colors: [
        p.mid.withValues(alpha: 0),
        p.mid.withValues(alpha: .22 + .25 * pulse),
        p.deep.withValues(alpha: 0),
      ],
      stops: const [.55, .62, 1],
    ).createShader(Rect.fromCircle(center: c, radius: r * 1.9));
    canvas.drawCircle(c, r * 1.9, glow);
    glow.shader = null;

    // The jets of flame
    const jets = 54;
    final outer = Paint()
      ..blendMode = BlendMode.plus
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * .045);
    final inner = Paint()
      ..blendMode = BlendMode.plus
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * .02);
    for (var i = 0; i < jets; i++) {
      final a = i / jets * 2 * math.pi;
      final dir = Offset(math.cos(a), math.sin(a));
      final d = _drift(i, .9);
      final length = r * (.14 + .14 * d + .12 * pulse);
      final base = c + dir * (r * .99);
      outer
        ..color = p.mid.withValues(alpha: .38 + .25 * d + .2 * pulse)
        ..strokeWidth = r * (.075 + .03 * d);
      canvas.drawLine(base, base + dir * length, outer);
      inner
        ..color = p.hot.withValues(alpha: .45 + .3 * d + .2 * pulse)
        ..strokeWidth = r * .03;
      canvas.drawLine(base, base + dir * (length * .42), inner);
    }

    // The iron cap, catching the flame's light at its edge
    canvas.drawCircle(
      c,
      r * .985,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF0B0C10),
            const Color(0xFF0B0C10),
            Color.lerp(const Color(0xFF0B0C10), p.mid, .28 + .15 * pulse)!,
          ],
          stops: const [0, .82, 1],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // The bright line where the gas meets the air
    canvas.drawCircle(
      c,
      r * .99,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * .018
        ..blendMode = BlendMode.plus
        ..color = p.hot.withValues(alpha: .7 + .3 * pulse)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * .012),
    );
  }

  @override
  bool shouldRepaint(_FlamePainter old) =>
      old.t != t || old.mood != mood || old.alert != alert;
}
