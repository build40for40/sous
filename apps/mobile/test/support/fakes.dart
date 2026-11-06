import 'dart:convert';
import 'dart:io';

import 'package:sous/api/brain_client.dart';
import 'package:sous/auth/session_tokens.dart';
import 'package:sous/auth/token_store.dart';

/// An unsigned JWT with just the claims the app reads. Never a real token.
String fakeJwt({required DateTime expiresAt, String sub = 'user_fake01'}) {
  String part(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return [
    part({'alg': 'none', 'typ': 'JWT'}),
    part({'sub': sub, 'exp': expiresAt.millisecondsSinceEpoch ~/ 1000}),
    'fake-signature',
  ].join('.');
}

const fakeUser = AuthUser(id: 'user_fake01', email: 'cook@example.com');

SessionTokens fakeTokens({
  required DateTime expiresAt,
  String refreshToken = 'refresh-fake-1',
}) => SessionTokens(
  accessToken: fakeJwt(expiresAt: expiresAt),
  refreshToken: refreshToken,
  user: fakeUser,
);

class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this.tokens]);

  SessionTokens? tokens;
  int writes = 0;

  @override
  Future<SessionTokens?> read() async => tokens;

  @override
  Future<void> write(SessionTokens tokens) async {
    this.tokens = tokens;
    writes++;
  }

  @override
  Future<void> clear() async => tokens = null;
}

/// Hands out `token-1`, then `token-2` after each refresh.
class FakeTokenSource implements AccessTokenSource {
  int version = 1;
  int refreshes = 0;
  bool signedIn = true;
  bool wasRejected = false;

  @override
  Future<String?> accessToken() async => signedIn ? 'token-$version' : null;

  @override
  Future<String?> refresh() async {
    refreshes++;
    if (!signedIn) return null;
    version++;
    return 'token-$version';
  }

  @override
  Future<void> rejected() async {
    wasRejected = true;
    signedIn = false;
  }
}

/// A file from `packages/contracts`, the shapes the brain and app agree on.
Map<String, Object?> contractExample(String name) => jsonDecode(
  File('../../packages/contracts/examples/$name').readAsStringSync(),
) as Map<String, Object?>;

/// Formats events the way the brain's `sse()` does.
String sse(Map<String, Object?> event) =>
    'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n';
