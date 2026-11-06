import 'package:flutter_test/flutter_test.dart';
import 'package:sous/auth/session_tokens.dart';

import '../support/fakes.dart';

void main() {
  final expiry = DateTime.utc(2026, 11, 6, 18, 5);

  test('reads the authenticate response and the expiry from the JWT', () {
    final tokens = SessionTokens.fromAuthenticateResponse({
      'access_token': fakeJwt(expiresAt: expiry),
      'refresh_token': 'refresh-fake-1',
      'user': {'id': 'user_fake01', 'email': 'cook@example.com'},
      'organization_id': null,
    });

    expect(tokens.expiresAt, expiry);
    expect(tokens.user.id, 'user_fake01');
    expect(tokens.user.email, 'cook@example.com');
    expect(tokens.refreshToken, 'refresh-fake-1');
  });

  test('round-trips through JSON for storage', () {
    final tokens = fakeTokens(expiresAt: expiry);
    final copy = SessionTokens.fromJson(tokens.toJson());

    expect(copy.accessToken, tokens.accessToken);
    expect(copy.refreshToken, tokens.refreshToken);
    expect(copy.user.email, 'cook@example.com');
    expect(copy.expiresAt, expiry);
  });

  test('counts as expiring inside the margin, and when exp is unreadable', () {
    final tokens = fakeTokens(expiresAt: expiry);
    const margin = Duration(seconds: 60);

    expect(
      tokens.expiresWithin(margin, expiry.subtract(const Duration(minutes: 2))),
      isFalse,
    );
    expect(
      tokens.expiresWithin(
        margin,
        expiry.subtract(const Duration(seconds: 30)),
      ),
      isTrue,
    );

    final opaque = SessionTokens(
      accessToken: 'not-a-jwt',
      refreshToken: 'r',
      user: fakeUser,
    );
    expect(opaque.expiresAt, isNull);
    expect(opaque.expiresWithin(margin, expiry), isTrue);
  });
}
