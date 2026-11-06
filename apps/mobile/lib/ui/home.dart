import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../api/recipe.dart';
import '../api/session.dart';
import '../cooking/cooking_session.dart';
import '../cooking/cooking_tools.dart';
import '../cooking/kitchen_timers.dart';
import '../services.dart';
import '../voice/model_downloader.dart';
import '../voice/voice_loop.dart';
import 'flame.dart';
import 'widgets.dart';

const _black = Color(0xFF000000);
const _text = Color(0xFFF5F5F7);
const _grey = Color(0xFF7C7C80);
const _faint = Color(0xFF1F1F21);
const _accent = Color(0xFF6FA8FF);

/// Sous is home. The recipe slides up over it, and Saved slides in from the
/// side.
enum _View { sous, recipe, saved }

/// The signed-in app: Sous (voice first), Recipe and Saved.
class Home extends StatefulWidget {
  const Home({super.key, required this.services});

  final SousServices services;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> implements CookingTools {
  _View _view = _View.sous;
  late Future<List<Recipe>> _recipes = widget.services.brain.listRecipes();
  Recipe? _selected;

  CookingSession? _session;
  CookingState _cooking = const CookingState();
  StreamSubscription<CookingState>? _sub;

  VoiceLoop? _loop;
  VoiceState _voice = const VoiceState();
  StreamSubscription<VoiceState>? _voiceSub;
  DownloadProgress? _download;

  final _kitchen = KitchenTimers();
  late final StreamSubscription<KitchenTimer> _finished;
  Timer? _tick;
  final _say = TextEditingController();

  List<KitchenTimer> get _timers => _kitchen.timers;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_timers.isNotEmpty && mounted) setState(() {});
    });
    _finished = _kitchen.finished.listen((t) {
      _session?.notify(TimerFinished(timerId: t.id, label: t.label));
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_finished.cancel());
    _kitchen.dispose();
    unawaited(_stopCooking());
    _say.dispose();
    super.dispose();
  }

  // ---- CookingTools: what Sous can do to the screen ----

  @override
  Future<String> startTimer(String label, int seconds) async {
    final id = _kitchen.start(label, seconds);
    setState(() {});
    return id;
  }

  @override
  Future<void> cancelTimer(String timerId) async {
    _kitchen.cancel(timerId);
    setState(() {});
  }

  @override
  Future<void> goToStep(int index) async => setState(() {});

  @override
  Future<void> setStage(Stage stage) async => setState(() {});

  @override
  Future<void> show(ShowView view) async {
    if (view == ShowView.ingredients || view == ShowView.step) {
      _go(_View.recipe);
    }
  }

  // ---- Cooking ----

  /// Gets the voice ready (downloading its models the first time), starts
  /// the cook, then listens. Typing still works if the voice can't start.
  Future<void> _startCooking() async {
    final recipe = _selected;
    if (recipe?.id == null) {
      _go(_View.saved);
      return;
    }
    await _stopCooking();
    final session = widget.services.cookingSession(this);
    _sub = session.states.listen((s) {
      if (s.events.isEmpty && _cooking.events.isNotEmpty) {
        _kitchen.clearFinished();
      }
      if (mounted) setState(() => _cooking = s);
    });
    setState(() {
      _session = session;
      _cooking = session.state;
      _voice = const VoiceState();
    });
    for (final t in [..._timers]) {
      _kitchen.cancel(t.id);
    }
    unawaited(WakelockPlus.enable().catchError((Object _) {}));
    final voiceReady = await _prepareVoice();
    if (!mounted || _session != session) return;
    await session.start(recipe!.id!);
    if (!mounted || _session != session || !voiceReady) return;
    if (session.state.phase == CookingPhase.failed) return;
    final loop = widget.services.voice.loopFor(session);
    _loop = loop;
    _voiceSub = loop.states.listen((s) {
      if (mounted) setState(() => _voice = s);
    });
    await loop.start();
  }

  Future<bool> _prepareVoice() async {
    final voice = widget.services.voice;
    try {
      if (await voice.isReady()) return true;
      await for (final progress in voice.prepare()) {
        if (mounted) setState(() => _download = progress);
      }
      return true;
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _voice = VoiceState(status: VoiceStatus.failed, error: e),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _download = null);
    }
  }

  Future<void> _stopCooking() async {
    final loop = _loop;
    final session = _session;
    _loop = null;
    await _voiceSub?.cancel();
    await _sub?.cancel();
    await loop?.dispose();
    await session?.dispose();
    await WakelockPlus.disable().catchError((Object _) {});
  }

  Future<void> _send() async {
    final text = _say.text.trim();
    final session = _session;
    if (text.isEmpty || session == null || !_cooking.canSpeak) return;
    _say.clear();
    await session.say(text);
  }

  bool get _voiceOn => _loop?.running ?? false;

  FlameAlert get _alert {
    final now = DateTime.now();
    if (_cooking.needsChef || _timers.any((t) => t.finished)) {
      return FlameAlert.alarm;
    }
    if (_timers.any((t) => t.left(now).inSeconds <= 30)) {
      return FlameAlert.headsUp;
    }
    return FlameAlert.none;
  }

  FlameMood get _mood {
    if (_voiceOn) {
      return switch (_voice.flame) {
        FlameState.chefSpeaking => FlameMood.listening,
        FlameState.thinking => FlameMood.thinking,
        FlameState.sousTalking => FlameMood.talking,
        FlameState.waiting || FlameState.needsChef => FlameMood.idle,
      };
    }
    if (_download != null) return FlameMood.thinking;
    return switch (_cooking.phase) {
      CookingPhase.starting ||
      CookingPhase.thinking ||
      CookingPhase.runningTools ||
      CookingPhase.ending => FlameMood.thinking,
      CookingPhase.replying => FlameMood.talking,
      _ => FlameMood.idle,
    };
  }

  /// The same as "Hey Sous": silences Sous, or opens a turn that carries
  /// anything the phone has been waiting to tell Sous.
  void _tapFlame() {
    final session = _session;
    if (session == null || _cooking.phase == CookingPhase.failed) {
      unawaited(_startCooking());
      return;
    }
    final loop = _loop;
    if (loop != null && loop.running) {
      unawaited(loop.openTurn());
    } else if (_cooking.needsChef && _cooking.canSpeak) {
      unawaited(session.send());
    }
  }

  void _open(Recipe r) => setState(() {
    _selected = r;
    _view = _View.recipe;
  });

  void _go(_View view) {
    if (_view != view) setState(() => _view = view);
  }

  // ---- Screens ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _black,
      body: SafeArea(
        child: Stack(
          children: [
            // Sous is home: swipe up or down anywhere to see the recipe
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0).abs() > 200) {
                    _go(_View.recipe);
                  }
                },
                child: _sousTab(),
              ),
            ),
            _layer(_View.recipe, _recipeLayer(), from: const Offset(0, 1)),
            _layer(_View.saved, _savedLayer(), from: const Offset(1, 0)),
          ],
        ),
      ),
    );
  }

  Widget _layer(_View view, Widget child, {required Offset from}) {
    final shown = _view == view;
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !shown,
        child: AnimatedSlide(
          offset: shown ? Offset.zero : from,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          child: ColoredBox(color: _black, child: child),
        ),
      ),
    );
  }

  /// The recipe, over Sous. Swiping past the top or the bottom, or tapping
  /// the handle, goes back to Sous.
  Widget _recipeLayer() => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onVerticalDragEnd: (d) {
      if ((d.primaryVelocity ?? 0).abs() > 200) _go(_View.sous);
    },
    child: Column(
      children: [
        GestureDetector(
          onTap: () => _go(_View.sous),
          child: Padding(
            padding: const EdgeInsets.only(top: 10, bottom: 6),
            child: Column(
              children: [
                Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                    color: const Color(0xFF3A3A3C),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Swipe to go back to Sous',
                  style: TextStyle(fontSize: 12, color: _grey),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: NotificationListener<ScrollUpdateNotification>(
            onNotification: (n) {
              final m = n.metrics;
              if (n.dragDetails != null &&
                  (m.pixels < m.minScrollExtent - 70 ||
                      m.pixels > m.maxScrollExtent + 70)) {
                _go(_View.sous);
              }
              return false;
            },
            child: _recipeTab(),
          ),
        ),
      ],
    ),
  );

  Widget _savedLayer() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 12, top: 6),
        child: TextButton.icon(
          onPressed: () => _go(_View.sous),
          icon: const Icon(Icons.chevron_left, color: _grey),
          label: const Text(
            'Sous',
            style: TextStyle(fontSize: 16, color: _grey),
          ),
        ),
      ),
      Expanded(child: _savedTab()),
    ],
  );

  String get _caption {
    if (_alert == FlameAlert.alarm) {
      final done = _timers.where((t) => t.finished).firstOrNull;
      return done == null ? 'Sous needs you.' : 'Chef! ${done.label}.';
    }
    if (_selected == null) return 'Pick a recipe in Saved, then tap the flame';
    if (_session == null) return 'Tap the flame to cook ${_selected!.title}';
    if (_download case final d?) {
      return 'Getting Sous’s voice ready… ${(d.fraction * 100).round()}%';
    }
    if (_cooking.phase == CookingPhase.failed) {
      return 'Sous couldn’t start. Tap to try again.';
    }
    if (_cooking.phase == CookingPhase.interrupted) {
      return 'Didn’t catch that. Say it again.';
    }
    return _cooking.reply.isEmpty ? '…' : _cooking.reply;
  }

  String get _hint {
    if (_alert == FlameAlert.alarm) return 'Say “Hey Sous” or tap the flame';
    if (_alert == FlameAlert.headsUp) return 'Heads up';
    if (_session == null) return '';
    if (_voiceOn && _voice.flame == FlameState.chefSpeaking) {
      return _voice.partial.isEmpty ? 'Listening…' : '“${_voice.partial}”';
    }
    if (_voice.status == VoiceStatus.failed) {
      return 'Voice didn’t start, so type to Sous';
    }
    final said = _cooking.transcript.whereType<CookTurn>().lastOrNull?.text;
    if (said != null) return '“$said”';
    return _voiceOn ? 'Say “Hey Sous” or tap the flame' : '';
  }

  Widget _sousTab() {
    final now = DateTime.now();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          Row(
            children: [
              TextButton(
                onPressed: () => _go(_View.saved),
                style: TextButton.styleFrom(padding: EdgeInsets.zero),
                child: const Text(
                  'Saved',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: _grey,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  (_selected?.title ?? 'Tonight').toUpperCase(),
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: .3,
                    color: _grey,
                  ),
                ),
              ),
              const SizedBox(width: 48),
            ],
          ),
          Expanded(
            flex: 5,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _tapFlame,
              child: Semantics(
                button: true,
                label: 'Talk to Sous',
                child: TickerMode(
                  enabled: _view == _View.sous,
                  child: Flame(
                    mood: _mood,
                    alert: _alert,
                    alignment: const Alignment(0, .45),
                  ),
                ),
              ),
            ),
          ),
          Caption(hint: _hint, said: _caption),
          const SizedBox(height: 18),
          if (_timers.isNotEmpty)
            Wrap(
              spacing: 32,
              runSpacing: 14,
              alignment: WrapAlignment.center,
              children: [
                for (final t in _timers)
                  TimerReadout(label: t.label, left: t.left(now)),
              ],
            ),
          const Spacer(flex: 2),
          if (_session != null && _cooking.phase != CookingPhase.failed)
            TextField(
              controller: _say,
              enabled: _cooking.canSpeak,
              onSubmitted: (_) => _send(),
              textInputAction: TextInputAction.send,
              style: const TextStyle(color: _text, fontSize: 16),
              cursorColor: _accent,
              decoration: InputDecoration(
                hintText: _voiceOn ? 'Or type to Sous' : 'Type to Sous',
                hintStyle: const TextStyle(color: _grey),
                filled: true,
                fillColor: SousColors.field,
                isDense: true,
                contentPadding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                enabledBorder: _fieldBorder(_faint),
                disabledBorder: _fieldBorder(_faint),
                focusedBorder: _fieldBorder(const Color(0xFF3A3A3C)),
                suffixIcon: IconButton(
                  onPressed: _send,
                  icon: const Icon(Icons.arrow_upward_rounded, color: _text),
                ),
              ),
            ),
          if (_selected != null)
            GestureDetector(
              onTap: () => _go(_View.recipe),
              child: const Padding(
                padding: EdgeInsets.only(top: 10, bottom: 12),
                child: Column(
                  children: [
                    Icon(Icons.keyboard_arrow_up, color: _grey, size: 22),
                    Text(
                      'Swipe for the recipe',
                      style: TextStyle(fontSize: 12, color: _grey),
                    ),
                  ],
                ),
              ),
            )
          else
            const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _recipeTab() {
    final r = _selected;
    if (r == null) {
      return const _Empty(
        'No recipe yet',
        'Pick one in Saved, or ask Sous what to cook tonight.',
      );
    }
    final cookingThis = _session != null && _cooking.recipeId == r.id;
    final current = cookingThis ? _cooking.stepIndex : null;
    final minutes = r.times?.totalMinutes;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 24),
      children: [
        Text(
          cookingThis ? 'TONIGHT' : 'RECIPE',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            letterSpacing: .3,
            color: _grey,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          r.title,
          style: const TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.w700,
            height: 1.05,
            letterSpacing: -.9,
            color: _text,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          [
            if (minutes != null) '$minutes min',
            if (r.servings != null) 'serves ${r.servings}',
          ].join(' · '),
          style: const TextStyle(fontSize: 15, color: _grey),
        ),
        if (_source(r) case final source?) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              SourcePill(source),
              const SizedBox(width: 8),
              Text(
                source == 'Instagram'
                    ? 'From a post on Instagram'
                    : 'From a recipe website',
                style: const TextStyle(fontSize: 13, color: _grey),
              ),
            ],
          ),
        ],
        const _Heading('Ingredients'),
        for (final i in r.ingredients)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: _faint)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        i.name,
                        style: const TextStyle(fontSize: 17, color: _text),
                      ),
                      if (i.note != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            i.note!,
                            style: const TextStyle(
                              fontSize: 13,
                              color: _accent,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  _amount(i),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 17,
                    color: _grey,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        const _Heading('Method'),
        for (final (n, s) in r.steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 28,
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 400),
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 17,
                      height: 1.4,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: n == current ? _accent : _grey,
                    ),
                    child: Text('${n + 1}'),
                  ),
                ),
                Expanded(
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 400),
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 17,
                      height: 1.4,
                      color: current == null || n == current ? _text : _grey,
                    ),
                    child: Text(s.text),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _savedTab() {
    return FutureBuilder<List<Recipe>>(
      future: _recipes,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: _accent, strokeWidth: 2),
          );
        }
        if (snap.hasError) {
          return _Empty(
            'Couldn’t load your recipes',
            'Check your connection.',
            action: 'Try again',
            onAction: () => setState(() {
              _recipes = widget.services.brain.listRecipes();
            }),
          );
        }
        final recipes = snap.data ?? const <Recipe>[];
        return RefreshIndicator(
          onRefresh: () async {
            setState(() {
              _recipes = widget.services.brain.listRecipes();
            });
            await _recipes;
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
            children: [
              const Text(
                'Saved',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w700,
                  height: 1.05,
                  letterSpacing: -.9,
                  color: _text,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                recipes.isEmpty
                    ? 'Share a recipe from Instagram to Sous and it lands here.'
                    : 'Say “Sous, number two”, or tap one',
                style: const TextStyle(fontSize: 14, color: _grey),
              ),
              const SizedBox(height: 10),
              for (final (n, r) in recipes.indexed)
                InkWell(
                  onTap: () => _open(r),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      border: Border(
                        top: const BorderSide(color: _faint),
                        bottom: n == recipes.length - 1
                            ? const BorderSide(color: _faint)
                            : BorderSide.none,
                      ),
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 32,
                          child: Text(
                            '${n + 1}',
                            style: const TextStyle(
                              fontSize: 15,
                              color: _grey,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                        RecipeThumb(r.title),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r.title,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                  color: _text,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  SourcePill(_source(r) ?? 'Saved'),
                                  if (r.times?.totalMinutes != null) ...[
                                    const SizedBox(width: 6),
                                    Text(
                                      '${r.times!.totalMinutes} min',
                                      style: const TextStyle(
                                        fontSize: 13,
                                        color: _grey,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

String? _source(Recipe r) {
  final url = r.sourceUrl;
  if (url == null) return null;
  return url.contains('instagram.com') ? 'Instagram' : 'Web';
}

String _amount(Ingredient i) {
  final q = i.quantity;
  if (q == null) return i.unit ?? '';
  final n = q == q.roundToDouble() ? q.toInt().toString() : q.toString();
  return [n, ?i.unit].join(' ');
}

OutlineInputBorder _fieldBorder(Color color) => OutlineInputBorder(
  borderRadius: BorderRadius.circular(14),
  borderSide: BorderSide(color: color),
);

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 34, bottom: 10),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        letterSpacing: .3,
        color: _grey,
      ),
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.title, this.body, {this.action, this.onAction});

  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: _text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, color: _grey),
          ),
          if (action != null) ...[
            const SizedBox(height: 16),
            TextButton(onPressed: onAction, child: Text(action!)),
          ],
        ],
      ),
    ),
  );
}
