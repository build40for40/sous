import 'dart:async';

/// Starts a one-off timer. [Timer.new] on the phone, a fake in tests.
typedef StartTimer = Timer Function(Duration after, void Function() then);

/// One named countdown, like "rice".
class KitchenTimer {
  KitchenTimer(this.id, this.label, this.endsAt);

  /// What `start_timer` returns to Sous, so it can cancel it later.
  final String id;
  final String label;
  final DateTime endsAt;

  /// True once it has gone off, until [KitchenTimers.clearFinished].
  bool finished = false;

  Duration left(DateTime now) {
    final d = endsAt.difference(now);
    return finished || d.isNegative ? Duration.zero : d;
  }
}

/// Sous's timers, run on the phone so they keep going when the brain drops
/// out. Several can run at once.
class KitchenTimers {
  KitchenTimers({DateTime Function()? clock, StartTimer? startTimer})
    : _clock = clock ?? DateTime.now,
      _startTimer = startTimer ?? Timer.new;

  final DateTime Function() _clock;
  final StartTimer _startTimer;

  final _timers = <KitchenTimer>[];
  final _alarms = <String, Timer>{};
  final _finished = StreamController<KitchenTimer>.broadcast(sync: true);
  var _count = 0;

  /// Running and finished timers, oldest first.
  List<KitchenTimer> get timers => List.unmodifiable(_timers);

  /// Each timer as it goes off.
  Stream<KitchenTimer> get finished => _finished.stream;

  /// Starts a countdown and returns its id.
  String start(String label, int seconds) {
    if (seconds <= 0) {
      throw ArgumentError.value(seconds, 'seconds', 'must be positive');
    }
    final length = Duration(seconds: seconds);
    final timer = KitchenTimer('timer-${++_count}', label, _clock().add(length));
    _timers.add(timer);
    _alarms[timer.id] = _startTimer(length, () => _finish(timer));
    return timer.id;
  }

  void cancel(String id) {
    final before = _timers.length;
    _timers.removeWhere((t) => t.id == id);
    _alarms.remove(id)?.cancel();
    if (_timers.length == before) throw ArgumentError('No timer called $id');
  }

  /// Takes finished timers off the list once the chef has heard about them.
  void clearFinished() => _timers.removeWhere((t) => t.finished);

  void _finish(KitchenTimer timer) {
    _alarms.remove(timer.id);
    if (!_timers.contains(timer)) return;
    timer.finished = true;
    if (!_finished.isClosed) _finished.add(timer);
  }

  void dispose() {
    for (final alarm in _alarms.values) {
      alarm.cancel();
    }
    _alarms.clear();
    unawaited(_finished.close());
  }
}
