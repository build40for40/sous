import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// What the flame is showing.
enum FlameMood { idle, listening, thinking, talking }

/// How much Sous needs the cook: blue normally, orange for a heads-up, red
/// for an alarm that repeats until the cook says "Heard".
enum FlameAlert { none, headsUp, alarm }

Future<ui.FragmentProgram>? _program;
ui.FragmentProgram? _loaded;

/// Sous's face: a gas burner seen from above, a ring of blue fire around a
/// dark iron cap. It's low while waiting, bounces while the cook speaks,
/// flickers while Sous thinks and surges while Sous talks.
class Flame extends StatefulWidget {
  const Flame({
    super.key,
    this.mood = FlameMood.idle,
    this.alert = FlameAlert.none,
    this.alignment = Alignment.center,
  });

  final FlameMood mood;
  final FlameAlert alert;

  /// Where the burner sits. Its fire and glow spill past the edges.
  final Alignment alignment;

  /// Loads the fire's shader. Until it's ready the flame is a plain ring.
  static Future<void> load() =>
      _program ??= ui.FragmentProgram.fromAsset('shaders/flame.frag')
          .then((p) => _loaded = p);

  @override
  State<Flame> createState() => _FlameState();
}

class _FlameState extends State<Flame> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _gas = _Gas();
  ui.FragmentShader? _shader = _loaded?.fragmentShader();
  Duration _last = Duration.zero;
  bool _calm = false;

  @override
  void initState() {
    super.initState();
    _ticker.start();
    if (_shader == null) {
      unawaited(
        Flame.load().then((_) {
          if (mounted) setState(() => _shader = _loaded!.fragmentShader());
        }, onError: (Object _) {}),
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _calm = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  void _tick(Duration elapsed) {
    final dt = math.min((elapsed - _last).inMicroseconds / 1e6, .05);
    _last = elapsed;
    _gas.step(dt * (_calm ? .25 : 1), widget.mood, widget.alert);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _gas.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _FlamePainter(_gas, _shader, widget.alignment),
      size: Size.infinite,
    ),
  );
}

/// How the gas is burning right now. Each value eases towards what the mood
/// and alert ask for, so changes swell rather than jump.
class _Gas extends ChangeNotifier {
  double t = 0;
  double amp = .04;
  double listen = 0;
  double warm = 0;
  double urgent = 0;

  void step(double dt, FlameMood mood, FlameAlert alert) {
    t += dt;
    double wave(double ms) => .5 + .5 * math.sin(t * 1000 / ms);
    var target = .04;
    var listenTarget = 0.0;
    switch (mood) {
      case FlameMood.idle:
        break;
      case FlameMood.listening:
        target = .12 + .22 * wave(280);
        listenTarget = 1;
      case FlameMood.thinking:
        target =
            .1 +
            .12 * wave(420) +
            .1 * (math.sin(t * 17) * math.sin(t * 5.3)).abs();
      case FlameMood.talking:
        target = .18 + .2 * wave(240);
    }
    switch (alert) {
      case FlameAlert.none:
        break;
      case FlameAlert.headsUp:
        target = math.max(target, .2 + .05 * math.sin(t * 1000 / 700));
      case FlameAlert.alarm:
        target = math.max(target, .2 + .6 * math.exp(-(t % .9) / .16));
    }
    final k = 1 - math.pow(.001, dt).toDouble();
    warm += ((alert == FlameAlert.headsUp ? 1 : 0) - warm) * k * 1.2;
    urgent += ((alert == FlameAlert.alarm ? 1 : 0) - urgent) * k * 1.6;
    amp = alert == FlameAlert.alarm ? target : amp + (target - amp) * k * .6;
    listen += (listenTarget - listen) * k;
    notifyListeners();
  }
}

class _FlamePainter extends CustomPainter {
  _FlamePainter(this.gas, this.shader, this.alignment) : super(repaint: gas);

  final _Gas gas;
  final ui.FragmentShader? shader;
  final Alignment alignment;

  @override
  void paint(Canvas canvas, Size size) {
    final c = alignment.withinRect(Offset.zero & size);
    // The ring's radius is a quarter of the scale, as in the design
    final scale = size.shortestSide * 1.16;
    final shader = this.shader;
    if (shader == null) {
      _ring(canvas, c, scale * .25);
      return;
    }
    shader
      ..setFloat(0, c.dx)
      ..setFloat(1, c.dy)
      ..setFloat(2, scale)
      ..setFloat(3, gas.t)
      ..setFloat(4, math.max(0, gas.amp))
      ..setFloat(5, gas.listen)
      ..setFloat(6, gas.warm)
      ..setFloat(7, gas.urgent);
    canvas.drawRect(
      Rect.fromCircle(center: c, radius: scale * .85),
      Paint()
        ..shader = shader
        ..blendMode = BlendMode.plus,
    );
  }

  void _ring(Canvas canvas, Offset c, double r) {
    final color = Color.lerp(
      Color.lerp(const Color(0xFF3D7BFF), const Color(0xFFFF7A10), gas.warm),
      const Color(0xFFF2140C),
      gas.urgent,
    )!;
    canvas
      ..drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * .12
          ..color = color.withValues(alpha: .6)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * .15),
      )
      ..drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * .03
          ..color = color,
      );
  }

  @override
  bool shouldRepaint(_FlamePainter old) =>
      old.gas != gas || old.shader != shader || old.alignment != alignment;
}
