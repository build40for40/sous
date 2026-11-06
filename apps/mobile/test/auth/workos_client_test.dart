import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sous/auth/pkce.dart';
import 'package:sous/auth/workos_client.dart';

import '../support/fakes.dart';

void main() {
  final expiry = DateTime.utc(2026, 11, 6, 18);

  WorkosClient client(MockClientHandler handler) => WorkosClient(
    clientId: 'client_fake',
    redirectUri: Uri.parse('sous://auth/callback'),
    apiBase: Uri.parse('https://api.workos.test'),
    httpClient: MockClient(handler),
  );

  http.Response tokensResponse() => http.Response(
    jsonEncode({
      'access_token': fakeJwt(expiresAt: expiry),
      'refresh_token': 'refresh-fake-2',
      'user': {'id': 'user_fake01'},
    }),
    200,
  );

  test('builds the hosted AuthKit URL with a PKCE challenge', () {
    final pkce = Pkce.generate(Random(3));
    final url = client((_) async => http.Response('', 500))
        .authorizationUrl(pkce, signUp: true);

    expect(url.origin, 'https://api.workos.test');
    expect(url.path, '/user_management/authorize');
    expect(url.queryParameters, {
      'response_type': 'code',
      'client_id': 'client_fake',
      'redirect_uri': 'sous://auth/callback',
      'provider': 'authkit',
      'code_challenge': pkce.challenge,
      'code_challenge_method': 'S256',
      'state': pkce.state,
      'screen_hint': 'sign-up',
    });
  });

  test('exchanges the code with the verifier and no secret', () async {
    late Map<String, Object?> sent;
    final tokens = await client((request) async {
      expect(request.url.path, '/user_management/authenticate');
      sent = jsonDecode(request.body) as Map<String, Object?>;
      return tokensResponse();
    }).authenticateWithCode('code-fake', 'verifier-fake');

    expect(sent, {
      'client_id': 'client_fake',
      'grant_type': 'authorization_code',
      'code': 'code-fake',
      'code_verifier': 'verifier-fake',
    });
    expect(sent.containsKey('client_secret'), isFalse);
    expect(tokens.refreshToken, 'refresh-fake-2');
    expect(tokens.expiresAt, expiry);
  });

  test('refreshes with the refresh token and no secret', () async {
    late Map<String, Object?> sent;
    await client((request) async {
      sent = jsonDecode(request.body) as Map<String, Object?>;
      return tokensResponse();
    }).authenticateWithRefreshToken('refresh-fake-1');

    expect(sent, {
      'client_id': 'client_fake',
      'grant_type': 'refresh_token',
      'refresh_token': 'refresh-fake-1',
    });
  });

  test('treats a refused grant as final and outages as transient', () async {
    Future<WorkosFailure> failureFor(MockClientHandler handler) async {
      try {
        await client(handler).authenticateWithRefreshToken('r');
      } on WorkosException catch (e) {
        return e.failure;
      }
      fail('expected a WorkosException');
    }

    expect(
      await failureFor(
        (_) async => http.Response(
          jsonEncode({'error': 'invalid_grant', 'error_description': 'Used'}),
          400,
        ),
      ),
      WorkosFailure.rejected,
    );
    expect(
      await failureFor((_) async => http.Response('down', 503)),
      WorkosFailure.transient,
    );
    expect(
      await failureFor((_) async => http.Response('slow down', 429)),
      WorkosFailure.transient,
    );
    expect(
      await failureFor((_) async => throw http.ClientException('offline')),
      WorkosFailure.transient,
    );
  });
}
