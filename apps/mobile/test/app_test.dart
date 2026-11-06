import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sous/auth/auth_controller.dart';
import 'package:sous/main.dart';
import 'package:sous/services.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('app boots and renders the placeholder screen', (tester) async {
    final services = SousServices(
      httpClient: MockClient((_) async => http.Response('', 500)),
      store: MemoryTokenStore(),
    );
    await services.auth.restore();
    await tester.pumpWidget(MainApp(services: services));

    expect(find.text('Hello World!'), findsOneWidget);
    expect(services.auth.state, isA<SignedOut>());
  });
}
