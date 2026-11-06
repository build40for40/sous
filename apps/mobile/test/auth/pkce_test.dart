import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sous/auth/pkce.dart';

void main() {
  test('derives the S256 challenge from the RFC 7636 example', () {
    expect(
      Pkce.challengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
  });

  test('generates a URL-safe verifier of a valid length and a fresh state', () {
    final a = Pkce.generate(Random(1));
    final b = Pkce.generate(Random(2));

    expect(a.verifier, matches(RegExp(r'^[A-Za-z0-9_-]{43,128}$')));
    expect(a.challenge, Pkce.challengeFor(a.verifier));
    expect(a.state, isNot(b.state));
    expect(a.verifier, isNot(b.verifier));
  });
}
