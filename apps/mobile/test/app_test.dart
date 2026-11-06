import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sous/auth/auth_controller.dart';
import 'package:sous/main.dart';
import 'package:sous/services.dart';
import 'package:sous/ui/flame.dart';

import 'support/fakes.dart';

void main() {
  setUpAll(() async {
    await TestWidgetsFlutterBinding.ensureInitialized().runAsync(Flame.load);
  });

  testWidgets('app boots to the sign-in screen when signed out', (
    tester,
  ) async {
    final services = SousServices(
      httpClient: MockClient((_) async => http.Response('', 500)),
      store: MemoryTokenStore(),
    );
    await services.auth.restore();
    await tester.pumpWidget(MainApp(services: services));
    await tester.pump();

    expect(find.text('Sign in'), findsOneWidget);
    expect(services.auth.state, isA<SignedOut>());
  });

  testWidgets('sign-in screen', (tester) async {
    tester.view
      ..physicalSize = const Size(412, 920)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = SousServices(
      httpClient: MockClient((_) async => http.Response('', 500)),
      store: MemoryTokenStore(),
    );
    await tester.runAsync(services.auth.restore);
    await tester.pumpWidget(MainApp(services: services));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    await expectLater(
      find.byType(MainApp),
      matchesGoldenFile('ui/goldens/sign_in.png'),
    );
  });
}
