import 'package:flutter_test/flutter_test.dart';
import 'package:sous/main.dart';

void main() {
  testWidgets('app boots and renders the placeholder screen', (tester) async {
    await tester.pumpWidget(const MainApp());

    expect(find.text('Hello World!'), findsOneWidget);
  });
}
