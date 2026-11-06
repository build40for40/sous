import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sous/cooking/cooking_tools.dart';
import 'package:sous/main.dart';
import 'package:sous/services.dart';
import 'package:sous/ui/flame.dart';
import 'package:sous/ui/home.dart';

import '../support/fakes.dart';

Map<String, Object?> _recipe(
  String id,
  String title,
  String source,
  int minutes,
) => {
  'id': id,
  'title': title,
  'source_url': 'https://$source/fake/$id',
  'servings': 2,
  'times': {'total_minutes': minutes},
  'ingredients': [
    {'name': 'Red lentils', 'quantity': 200, 'unit': 'g'},
    {'name': 'Basmati rice', 'quantity': 150, 'unit': 'g'},
    {'name': 'Onion', 'quantity': 1},
    {
      'name': 'Garlic',
      'quantity': 5,
      'unit': 'cloves',
      'note': 'One more than the recipe. You asked last time.',
    },
    {'name': 'Ghee', 'quantity': 2, 'unit': 'tbsp'},
  ],
  'steps': [
    {'text': 'Rinse the lentils, then simmer them with the turmeric.'},
    {'text': 'Put the rice on with the cumin seeds.'},
    {'text': 'Make the tadka: hot ghee, seeds, garlic and chilli.'},
  ],
};

final _recipes = [
  _recipe('fake-1', 'Fake Tadka Dahl', 'www.instagram.com', 35),
  _recipe('fake-2', 'Fake Miso Salmon Traybake', 'www.instagram.com', 25),
  _recipe('fake-3', 'Fake Lemon Orzo with Peas', 'example.com', 22),
];

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late SousServices services;

  setUpAll(() async {
    await TestWidgetsFlutterBinding.ensureInitialized().runAsync(Flame.load);
  });

  Future<void> open(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(412, 920)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    services = SousServices(
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/recipes')) {
          return http.Response(
            jsonEncode({'recipes': _recipes}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      }),
      store: MemoryTokenStore(
        fakeTokens(expiresAt: DateTime.now().add(const Duration(days: 1))),
      ),
    );
    await tester.runAsync(services.auth.restore);
    await tester.pumpWidget(MainApp(services: services));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await settle(tester);
  }

  Future<void> showSaved(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(TextButton, 'Saved'));
    await settle(tester);
  }

  Future<void> pick(WidgetTester tester) async {
    await showSaved(tester);
    await tester.tap(find.text('Fake Tadka Dahl'));
    await settle(tester);
  }

  testWidgets('Sous before a recipe is picked', (tester) async {
    await open(tester);
    await expectLater(
      find.byType(MainApp),
      matchesGoldenFile('goldens/home_sous.png'),
    );
  });

  testWidgets('Saved', (tester) async {
    await open(tester);
    await showSaved(tester);
    await expectLater(
      find.byType(MainApp),
      matchesGoldenFile('goldens/home_saved.png'),
    );
  });

  testWidgets('Recipe', (tester) async {
    await open(tester);
    await pick(tester);
    await expectLater(
      find.byType(MainApp),
      matchesGoldenFile('goldens/home_recipe.png'),
    );
  });

  testWidgets('Sous with timers, one done', (tester) async {
    await open(tester);
    await pick(tester);
    await tester.tap(find.text('Swipe to go back to Sous'));
    await settle(tester);
    final tools = tester.state(find.byType(Home)) as CookingTools;
    await tools.startTimer('rice', 12 * 60);
    await tools.startTimer('dahl', 20);
    await tools.startTimer('tadka', 0);
    await settle(tester);
    expect(find.text('Say “Hey Sous” or tap the flame'), findsOneWidget);
    await expectLater(
      find.byType(MainApp),
      matchesGoldenFile('goldens/home_timers.png'),
    );
  });
}
