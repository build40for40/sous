import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sous/auth/auth_controller.dart';
import 'package:sous/main.dart';
import 'package:sous/services.dart';

import 'support/fakes.dart';

void main() {
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
}
