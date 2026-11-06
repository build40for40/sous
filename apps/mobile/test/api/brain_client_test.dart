import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sous/api/brain_client.dart';
import 'package:sous/api/brain_exception.dart';
import 'package:sous/api/recipe.dart';
import 'package:sous/api/session.dart';
import 'package:sous/auth/workos_client.dart';

import '../support/fakes.dart';

class Call {
  Call(this.method, this.path, this.token, this.body);

  final String method;
  final String path;
  final String? token;
  final Object? body;
}

void main() {
  late FakeTokenSource tokens;
  late List<Call> calls;

  final recipeJson = contractExample('recipe.json');
  const startedAt = '2026-11-06T18:00:00Z';

  BrainClient client(
    FutureOr<http.StreamedResponse> Function(Call call) respond,
  ) => BrainClient(
    baseUri: Uri.parse('https://brain.test/sous/api/v1'),
    httpClient: MockClient.streaming((request, body) async {
      final text = await body.bytesToString();
      final call = Call(
        request.method,
        request.url.path,
        request.headers['Authorization'],
        text.isEmpty ? null : jsonDecode(text),
      );
      calls.add(call);
      return respond(call);
    }),
    tokens: tokens,
  );

  http.StreamedResponse json(Object? body, [int status = 200]) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(body))),
        status,
      );

  http.StreamedResponse empty([int status = 204]) =>
      http.StreamedResponse(const Stream.empty(), status);

  setUp(() {
    tokens = FakeTokenSource();
    calls = [];
  });

  group('every endpoint', () {
    final profile = {
      'id': 'user_fake01',
      'preferences': {'diet': 'vegetarian'},
      'about': 'Cooks for two.',
      'learned': ['hates coriander'],
      'updated_at': startedAt,
    };

    test('GET /me', () async {
      final me = await client((_) => json(profile)).getMe();
      expect(calls.single.method, 'GET');
      expect(calls.single.path, '/sous/api/v1/me');
      expect(calls.single.token, 'Bearer token-1');
      expect(me.learned, ['hates coriander']);
    });

    test('PATCH /me', () async {
      final me = await client((_) => json(profile))
          .updateMe(preferences: {'diet': null}, about: 'New me.');
      expect(calls.single.method, 'PATCH');
      expect(calls.single.body, {
        'preferences': {'diet': null},
        'about': 'New me.',
      });
      expect(me.about, 'Cooks for two.');

      await client((_) => json(profile)).updateMe(about: 'Only about.');
      expect(calls.last.body, {'about': 'Only about.'});
    });

    test('DELETE /me', () async {
      await client((_) => empty()).deleteMe();
      expect(
        (calls.single.method, calls.single.path),
        ('DELETE', '/sous/api/v1/me'),
      );
    });

    test('GET /recipes', () async {
      final recipes = await client(
        (_) => json({
          'recipes': [recipeJson],
        }),
      ).listRecipes();
      expect(calls.single.path, '/sous/api/v1/recipes');
      expect(recipes.single.title, 'Fake Example Beans on Toast');
    });

    test('POST /recipes', () async {
      final recipe = Recipe.fromJson(recipeJson);
      final saved = await client((_) => json(recipeJson, 201))
          .createRecipe(recipe);
      expect(calls.single.method, 'POST');
      expect((calls.single.body as Map).containsKey('id'), isFalse);
      expect(saved.id, 'recipe-example-1');
    });

    test('GET /recipes/:id', () async {
      final recipe = await client((_) => json(recipeJson))
          .getRecipe('recipe-example-1');
      expect(calls.single.path, '/sous/api/v1/recipes/recipe-example-1');
      expect(recipe.steps, hasLength(3));
    });

    test('DELETE /recipes/:id', () async {
      await client((_) => empty()).deleteRecipe('recipe-example-1');
      expect(
        (calls.single.method, calls.single.path),
        ('DELETE', '/sous/api/v1/recipes/recipe-example-1'),
      );
    });

    test('GET /suggest', () async {
      final suggestions = await client(
        (_) => json({
          'suggestions': [
            {
              'number': 1,
              'recipe_id': 'r1',
              'title': 'Beans',
              'reason': 'Quick.',
            },
          ],
        }),
      ).suggest();
      expect(calls.single.path, '/sous/api/v1/suggest');
      expect(suggestions.single.number, 1);
      expect(suggestions.single.reason, 'Quick.');
    });

    test('GET /history', () async {
      final cooks = await client(
        (_) => json({
          'cooks': [
            {
              'session_id': 's1',
              'recipe_id': 'r1',
              'recipe_title': 'Beans',
              'started_at': startedAt,
              'ended_at': startedAt,
              'date': '2026-11-06',
              'rating': 5,
              'summary': 'Lovely.',
              'reflection_status': 'done',
            },
          ],
        }),
      ).history();
      expect(calls.single.path, '/sous/api/v1/history');
      expect(cooks.single.rating, 5);
    });

    test('POST /sessions', () async {
      final started = await client(
        (_) => json({
          'id': 's1',
          'recipe_id': 'r1',
          'stage': 'decide',
          'started_at': startedAt,
          'opening_line': 'Right then.',
        }, 201),
      ).startSession('r1');
      expect(calls.single.body, {'recipe_id': 'r1'});
      expect(started.openingLine, 'Right then.');
    });

    test('POST /sessions/:id/turns streams typed events', () async {
      final events = await client(
        (_) => http.StreamedResponse(
          Stream.fromIterable(
            [
              sse({'type': 'text', 'delta': 'Two '}),
              sse({'type': 'text', 'delta': 'minutes.'}),
              sse({
                'type': 'tool_call',
                'tool_call': {
                  'id': 't1',
                  'name': 'start_timer',
                  'input': {'label': 'eggs', 'seconds': 120},
                },
              }),
              sse({'type': 'done', 'stop_reason': 'tool_use'}),
            ].map(utf8.encode),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ).takeTurn('s1', TurnRequest(text: 'eggs in')).toList();

      expect(calls.single.path, '/sous/api/v1/sessions/s1/turns');
      expect(calls.single.body, {'text': 'eggs in'});
      expect(events.map((e) => e.runtimeType), [
        TextEvent,
        TextEvent,
        ToolCallEvent,
        DoneEvent,
      ]);
      expect((events.last as DoneEvent).stopReason, StopReason.toolUse);
    });

    test('POST /sessions/:id/end', () async {
      final ended = await client(
        (_) => json({
          'id': 's1',
          'ended_at': startedAt,
          'rating': 4,
          'notes': 'More cheese.',
          'reflection_status': 'pending',
        }, 202),
      ).endSession('s1', rating: 4, notes: 'More cheese.');
      expect(calls.single.path, '/sous/api/v1/sessions/s1/end');
      expect(calls.single.body, {'rating': 4, 'notes': 'More cheese.'});
      expect(ended.notes, 'More cheese.');

      await client(
        (_) => json({
          'id': 's1',
          'ended_at': startedAt,
          'reflection_status': 'pending',
        }, 202),
      ).endSession('s1');
      expect(calls.last.body, <String, Object?>{});
    });

    test('GET /sessions/:id', () async {
      final view = await client(
        (_) => json({
          'session': contractExample('session.json'),
          'reflection': null,
          'reflection_status': 'pending',
          'reflected_at': null,
        }),
      ).getSession('s1');
      expect(calls.single.path, '/sous/api/v1/sessions/s1');
      expect(view.reflection, isNull);
      expect(view.session.turns, isNotEmpty);
    });
  });

  group('auth', () {
    test('refreshes once on a 401 and retries with the new token', () async {
      final me = await client(
        (call) => call.token == 'Bearer token-1'
            ? json({'error': 'sign_in_required'}, 401)
            : json({
                'id': 'user_fake01',
                'preferences': {},
                'about': '',
                'learned': [],
                'updated_at': startedAt,
              }),
      ).getMe();

      expect(calls.map((c) => c.token), ['Bearer token-1', 'Bearer token-2']);
      expect(tokens.refreshes, 1);
      expect(me.id, 'user_fake01');
    });

    test('signs out when the brain still says 401 after a refresh', () async {
      final brain = client((_) => json({'error': 'sign_in_required'}, 401));

      await expectLater(
        brain.listRecipes(),
        throwsA(
          isA<BrainException>().having(
            (e) => e.error,
            'error',
            BrainError.signedOut,
          ),
        ),
      );
      expect(calls, hasLength(2));
      expect(tokens.wasRejected, isTrue);
    });

    test('fails fast as signed out with no token', () async {
      tokens.signedIn = false;
      await expectLater(
        client((_) => json({})).history(),
        throwsA(
          isA<BrainException>().having(
            (e) => e.error,
            'error',
            BrainError.signedOut,
          ),
        ),
      );
      expect(calls, isEmpty);
    });
  });

  group('errors', () {
    Future<BrainException> failure(
      FutureOr<http.StreamedResponse> Function(Call) respond,
      Future<Object?> Function(BrainClient) call,
    ) async {
      try {
        await call(client(respond));
      } on BrainException catch (e) {
        return e;
      }
      fail('expected a BrainException');
    }

    test('a refused turn throws before any event', () async {
      final e = await failure(
        (_) => json({
          'error': 'tool_results_required',
          'tool_call_ids': ['t1'],
        }, 409),
        (b) => b.takeTurn('s1', TurnRequest(text: 'hi')).toList(),
      );
      expect(e.error, BrainError.toolResultsRequired);
      expect(e.toolCallIds, ['t1']);
    });

    test('unavailable, retryable and not found', () async {
      expect(
        (await failure(
          (_) => json({'error': 'live_sessions_unavailable'}, 503),
          (b) => b.startSession('r1'),
        )).error,
        BrainError.unavailable,
      );
      expect(
        (await failure(
          (_) => json({'error': 'suggestions_failed'}, 502),
          (b) => b.suggest(),
        )).error,
        BrainError.retryable,
      );
      expect(
        (await failure(
          (_) => json({'error': 'recipe_not_found'}, 404),
          (b) => b.getRecipe('nope'),
        )).code,
        'recipe_not_found',
      );
    });

    test('no connection and a reply that breaks off are network', () async {
      expect(
        (await failure(
          (_) => throw http.ClientException('offline'),
          (b) => b.getMe(),
        )).error,
        BrainError.network,
      );

      final broken = StreamController<List<int>>();
      broken.add(utf8.encode(sse({'type': 'text', 'delta': 'Two'})));
      broken.addError(http.ClientException('connection reset'));
      unawaited(broken.close());
      expect(
        (await failure(
          (_) => http.StreamedResponse(broken.stream, 200),
          (b) => b.takeTurn('s1', TurnRequest(text: 'hi')).toList(),
        )).error,
        BrainError.network,
      );
    });

    test('a refresh that cannot reach WorkOS is a network error', () async {
      final e = await failure(
        (_) => json({}),
        (b) => BrainClient(
          baseUri: b.baseUri,
          httpClient: MockClient((_) async => http.Response('{}', 200)),
          tokens: _OfflineTokens(),
        ).getMe(),
      );
      expect(e.error, BrainError.network);
      expect(e.code, 'refresh_failed');
    });
  });
}

class _OfflineTokens extends FakeTokenSource {
  @override
  Future<String?> accessToken() =>
      Future.error(const WorkosException(WorkosFailure.transient, 'offline'));
}
