import 'package:flutter/material.dart';

abstract final class SousColors {
  static const text = Color(0xFFF5F5F7);
  static const grey = Color(0xFF7C7C80);
  static const faint = Color(0xFF1F1F21);
  static const accent = Color(0xFF6FA8FF);
  static const field = Color(0xFF111113);
  static const soon = Color(0xFFFFA43A);
  static const due = Color(0xFFFF4D3D);
}

/// Text that fades out and back in when it changes to something new, and
/// simply grows when the new text carries on from the old, as a reply
/// streams in.
class FadeText extends StatefulWidget {
  const FadeText(
    this.text, {
    super.key,
    required this.style,
    this.textAlign = TextAlign.center,
  });

  final String text;
  final TextStyle style;
  final TextAlign textAlign;

  @override
  State<FadeText> createState() => _FadeTextState();
}

class _FadeTextState extends State<FadeText>
    with SingleTickerProviderStateMixin {
  late String _shown = widget.text;
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
    value: 1,
  );

  @override
  void didUpdateWidget(FadeText old) {
    super.didUpdateWidget(old);
    final next = widget.text;
    if (next == _shown || _fade.status == AnimationStatus.reverse) return;
    final carriesOn = _shown.isNotEmpty && next.startsWith(_shown);
    if (carriesOn || MediaQuery.disableAnimationsOf(context)) {
      setState(() => _shown = next);
      return;
    }
    _fade.reverse().whenCompleteOrCancel(() {
      if (!mounted) return;
      setState(() => _shown = widget.text);
      _fade.forward();
    });
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: CurvedAnimation(parent: _fade, curve: Curves.easeInOut),
    child: Text(
      _shown,
      textAlign: widget.textAlign,
      textWidthBasis: TextWidthBasis.longestLine,
      style: widget.style,
    ),
  );
}

/// What Sous is saying, with a quieter line above it: what the cook just
/// said, or what to do next.
class Caption extends StatelessWidget {
  const Caption({super.key, required this.hint, required this.said});

  final String hint;
  final String said;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 128, maxWidth: 300),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeText(
          hint,
          style: const TextStyle(
            fontSize: 16,
            height: 1.3,
            color: SousColors.grey,
          ),
        ),
        const SizedBox(height: 8),
        FadeText(
          said,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w500,
            letterSpacing: -.33,
            height: 1.3,
            color: SousColors.text,
          ),
        ),
      ],
    ),
  );
}

/// A timer under the burner: big light digits that warm to orange as it
/// gets close and turn the flame's red when it's done.
class TimerReadout extends StatelessWidget {
  const TimerReadout({super.key, required this.label, required this.left});

  final String label;
  final Duration left;

  @override
  Widget build(BuildContext context) {
    final color = left == Duration.zero
        ? SousColors.due
        : left.inSeconds <= 30
        ? SousColors.soon
        : SousColors.text;
    final digits =
        '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedDefaultTextStyle(
          duration: const Duration(milliseconds: 600),
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: 30,
            fontWeight: FontWeight.w300,
            letterSpacing: -.5,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: color,
          ),
          child: Text(digits),
        ),
        const SizedBox(height: 2),
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: .6,
            color: SousColors.grey,
          ),
        ),
      ],
    );
  }
}

/// Where a recipe came from, as a small outlined tag.
class SourcePill extends StatelessWidget {
  const SourcePill(this.source, {super.key});

  final String source;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xFF2E2E31)),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Text(
      source.toUpperCase(),
      style: const TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: .5,
        color: SousColors.grey,
      ),
    ),
  );
}

/// A stand-in for a photo of the dish: a plate in colours picked from the
/// recipe's name, until real cook photos arrive.
class RecipeThumb extends StatelessWidget {
  const RecipeThumb(this.name, {super.key, this.size = 56});

  final String name;
  final double size;

  static const _palettes = [
    [Color(0xFFF7C548), Color(0xFFE8731C), Color(0xFFB85A16)],
    [Color(0xFFC8432A), Color(0xFF8A2A16), Color(0xFF5A2414)],
    [Color(0xFFF29B6B), Color(0xFF4E8F45), Color(0xFFC9773E)],
    [Color(0xFFD93A22), Color(0xFFF2C14E), Color(0xFFA82A18)],
    [Color(0xFFC9792E), Color(0xFFE9DFC8), Color(0xFF7A4A22)],
    [Color(0xFFF4E04D), Color(0xFF7BC86C), Color(0xFFE8DDB0)],
  ];

  @override
  Widget build(BuildContext context) {
    final seed = name.codeUnits.fold(7, (h, c) => (h * 31 + c) & 0x7fffffff);
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * .21),
      child: CustomPaint(
        size: Size.square(size),
        painter: _PlatePainter(_palettes[seed % _palettes.length], seed),
      ),
    );
  }
}

class _PlatePainter extends CustomPainter {
  _PlatePainter(this.palette, this.seed);

  final List<Color> palette;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final c = size.center(Offset.zero);
    canvas
      ..drawColor(const Color(0xFF0E0E0F), BlendMode.src)
      ..drawCircle(c, s * .41, Paint()..color = const Color(0xFF1B1A18))
      ..drawCircle(c, s * .37, Paint()..color = palette[2]);
    void blob(Color color, Offset at, double r) => canvas.drawCircle(
      at,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color, color.withValues(alpha: 0)],
          stops: const [0, .4, 1],
        ).createShader(Rect.fromCircle(center: at, radius: r)),
    );
    final i = seed % 7;
    blob(
      palette[1],
      Offset(s * (.68 - (i * 13 % 30) / 100), s * (.62 - (i * 7 % 20) / 100)),
      s * .3,
    );
    blob(
      palette[0],
      Offset(s * (.3 + (i * 17 % 40) / 100), s * (.35 + (i * 11 % 30) / 100)),
      s * .25,
    );
  }

  @override
  bool shouldRepaint(_PlatePainter old) =>
      old.seed != seed || old.palette != palette;
}
