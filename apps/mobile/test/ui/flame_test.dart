import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sous/ui/flame.dart';

void main() {
  setUpAll(() async {
    await TestWidgetsFlutterBinding.ensureInitialized().runAsync(Flame.load);
  });

  Future<void> burn(
    WidgetTester tester, {
    FlameMood mood = FlameMood.idle,
    FlameAlert alert = FlameAlert.none,
  }) async {
    tester.view
      ..physicalSize = const Size(412, 560)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ColoredBox(
        color: Colors.black,
        child: Flame(mood: mood, alert: alert),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  for (final mood in FlameMood.values) {
    testWidgets('flame while ${mood.name}', (tester) async {
      await burn(tester, mood: mood);
      await expectLater(
        find.byType(Flame),
        matchesGoldenFile('goldens/flame_${mood.name}.png'),
      );
    });
  }

  for (final alert in [FlameAlert.headsUp, FlameAlert.alarm]) {
    testWidgets('flame for a ${alert.name}', (tester) async {
      await burn(tester, alert: alert);
      await expectLater(
        find.byType(Flame),
        matchesGoldenFile('goldens/flame_${alert.name}.png'),
      );
    });
  }

  testWidgets('flame keeps burning past an hour', (tester) async {
    await burn(tester);
    await tester.pump(const Duration(hours: 2));
    expect(tester.binding.hasScheduledFrame, isTrue);
  });
}
