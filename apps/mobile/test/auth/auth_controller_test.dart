import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sous/auth/auth_browser.dart';
import 'package:sous/auth/auth_controller.dart';
import 'package:sous/auth/pkce.dart';
import 'package:sous/auth/workos_client.dart';

import '../support/fakes.dart';

class FakeBrowser implements AuthBrowser {
  FakeBrowser(this.respond);

  Uri? Function(Uri url) respond;
  Uri? opened;

  @override
  Future<Uri?> authenticate(Uri url, String callbackScheme) async {
    opened = url;
    expect(callbackScheme, 'sous');
    return respond(url);
  }
}

/// Answers like WorkOS: the code `good-code` with a verifier that matches the
/// challenge the browser was sent, and refresh tokens `refresh-fake-N`, each
/// usable once.
class FakeWorkos {
  FakeWorkos(this.now);

  DateTime Function() now;
  String? challenge;
  int refreshes = 0;
  final used = <String>{};
  http.Response? Function()? override;
  Completer<void>? holdRefresh;

  Future<http.Response> handle(http.Request request) async {
    final forced = override?.call();
    if (forced != null) return forced;
    final body = jsonDecode(request.body) as Map<String, Object?>;
    expect(body.containsKey('client_secret'), isFalse);
    if (body['grant_type'] == 'authorization_code') {
      final verifier = body['code_verifier'] as String;
      if (body['code'] != 'good-code' ||
          Pkce.challengeFor(verifier) != challenge) {
        return http.Response(jsonEncode({'error': 'invalid_grant'}), 400);
      }
      return _tokens('refresh-fake-1');
    }
    final token = body['refresh_token'] as String;
    if (!used.add(token)) {
      return http.Response(jsonEncode({'error': 'invalid_grant'}), 400);
    }
    await holdRefresh?.future;
    refreshes++;
    return _tokens('refresh-fake-${refreshes + 1}');
  }

  http.Response _tokens(String refresh) => http.Response(
    jsonEncode({
      'access_token': fakeJwt(expiresAt: now().add(const Duration(minutes: 5))),
      'refresh_token': refresh,
      'user': {'id': 'user_fake01', 'email': 'cook@example.com'},
    }),
    200,
  );
}

void main() {
  var now = DateTime.utc(2026, 11, 6, 18);
  late FakeWorkos workos;
  late MemoryTokenStore store;
  late FakeBrowser browser;
  late AuthController auth;

  Uri? approve(Uri url) {
    workos.challenge = url.queryParameters['code_challenge'];
    return Uri.parse(
      'sous://auth/callback?code=good-code&state=${url.queryParameters['state']}',
    );
  }

  setUp(() {
    now = DateTime.utc(2026, 11, 6, 18);
    workos = FakeWorkos(() => now);
    store = MemoryTokenStore();
    browser = FakeBrowser(approve);
    auth = AuthController(
      workos: WorkosClient(
        clientId: 'client_fake',
        redirectUri: Uri.parse('sous://auth/callback'),
        apiBase: Uri.parse('https://api.workos.test'),
        httpClient: MockClient(workos.handle),
      ),
      browser: browser,
      store: store,
      callbackScheme: 'sous',
      clock: () => now,
    );
  });

  Future<bool> signIn() {
    browser.respond = approve;
    return auth.signIn();
  }

  test('restores a saved session, or starts signed out', () async {
    await auth.restore();
    expect(auth.state, isA<SignedOut>());

    store.tokens = fakeTokens(expiresAt: now.add(const Duration(minutes: 5)));
    await auth.restore();
    expect(auth.state, isA<SignedIn>());
    expect(auth.user!.id, 'user_fake01');
  });

  test('signs in through the browser with PKCE and saves the tokens', () async {
    await auth.restore();
    final states = <AuthState>[];
    auth.states.listen(states.add);

    expect(await signIn(), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(browser.opened!.queryParameters['code_challenge_method'], 'S256');
    expect(states.map((s) => s.runtimeType), [SigningIn, SignedIn]);
    expect(store.tokens!.refreshToken, 'refresh-fake-1');
    expect(await auth.accessToken(), store.tokens!.accessToken);
  });

  test('a closed browser goes back to signed out with no error', () async {
    await auth.restore();
    browser.respond = (_) => null;

    expect(await auth.signIn(), isFalse);
    expect((auth.state as SignedOut).error, isNull);
  });

  test('rejects a callback with the wrong state or an error', () async {
    await auth.restore();
    browser.respond = (_) =>
        Uri.parse('sous://auth/callback?code=good-code&state=forged');
    expect(await auth.signIn(), isFalse);
    expect((auth.state as SignedOut).error, AuthError.callbackRejected);

    browser.respond = (url) => Uri.parse(
      'sous://auth/callback?error=access_denied&state=${url.queryParameters['state']}',
    );
    expect(await auth.signIn(), isFalse);
    expect((auth.state as SignedOut).error, AuthError.callbackRejected);
    expect(store.tokens, isNull);
  });

  test('reports a refused code and a network failure differently', () async {
    await auth.restore();
    browser.respond = (url) => Uri.parse(
      'sous://auth/callback?code=stale-code&state=${url.queryParameters['state']}',
    );
    expect(await auth.signIn(), isFalse);
    expect((auth.state as SignedOut).error, AuthError.exchangeRejected);

    workos.override = () => http.Response('down', 503);
    expect(await signIn(), isFalse);
    expect((auth.state as SignedOut).error, AuthError.network);
  });

  test('refreshes before expiry and stores the rotated tokens', () async {
    await auth.restore();
    await signIn();
    final first = await auth.accessToken();

    now = now.add(const Duration(minutes: 3));
    expect(await auth.accessToken(), first);
    expect(workos.refreshes, 0);

    now = now.add(const Duration(minutes: 1, seconds: 30));
    final second = await auth.accessToken();
    expect(second, isNot(first));
    expect(workos.refreshes, 1);
    expect(store.tokens!.refreshToken, 'refresh-fake-2');
    expect(auth.state, isA<SignedIn>());
  });

  test('concurrent callers share one refresh', () async {
    await auth.restore();
    await signIn();
    now = now.add(const Duration(minutes: 10));
    workos.holdRefresh = Completer<void>();

    final tokens = [auth.accessToken(), auth.accessToken(), auth.refresh()];
    workos.holdRefresh!.complete();
    final results = await Future.wait(tokens);

    expect(workos.refreshes, 1);
    expect(results.toSet(), hasLength(1));
  });

  test('a refused refresh signs the cook out', () async {
    await auth.restore();
    await signIn();
    workos.used.add('refresh-fake-1');

    expect(await auth.refresh(), isNull);
    expect(auth.state, isA<SignedOut>());
    expect(store.tokens, isNull);
  });

  test('a refresh that cannot reach WorkOS keeps the session', () async {
    await auth.restore();
    await signIn();
    workos.override = () => throw http.ClientException('offline');

    await expectLater(auth.refresh(), throwsA(isA<WorkosException>()));
    expect(auth.state, isA<SignedIn>());
    expect(store.tokens, isNotNull);
  });

  test('signs out, and the brain rejecting a token does too', () async {
    await auth.restore();
    await signIn();
    await auth.signOut();
    expect(auth.state, isA<SignedOut>());
    expect(store.tokens, isNull);
    expect(await auth.accessToken(), isNull);

    await signIn();
    await auth.rejected();
    expect(auth.state, isA<SignedOut>());
  });
}
