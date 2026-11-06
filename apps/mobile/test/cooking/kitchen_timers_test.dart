import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sous/cooking/kitchen_timers.dart';

void main() {
  test('runs several named timers at once and reports each as it '
      'finishes', () {
    final now = DateTime.utc(2026, 11, 6, 18);
    final alarms = <Duration, void Function()>{};
    final timers = KitchenTimers(
      clock: () => now,
      startTimer: (after, then) {
        alarms[after] = then;
        return Timer(const Duration(days: 1), () {});
      },
    );
    addTearDown(timers.dispose);
    final finished = <String>[];
    timers.finished.listen((t) => finished.add(t.label));

    final rice = timers.start('rice', 720);
    final dahl = timers.start('dahl', 1200);
    expect(rice, isNot(dahl));
    expect(timers.timers.map((t) => t.label), ['rice', 'dahl']);
    expect(
      timers.timers.first.left(now.add(const Duration(minutes: 2))),
      const Duration(minutes: 10),
    );

    alarms[const Duration(minutes: 12)]!();
    expect(finished, ['rice']);
    expect(timers.timers.first.finished, isTrue);
    expect(timers.timers.first.left(now), Duration.zero);

    timers.clearFinished();
    expect(timers.timers.map((t) => t.id), [dahl]);
    timers.cancel(dahl);
    alarms[const Duration(minutes: 20)]!();
    expect(finished, ['rice'], reason: 'a cancelled timer never goes off');
    expect(() => timers.cancel(dahl), throwsArgumentError);
  });
}
