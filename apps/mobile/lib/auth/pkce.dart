import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A PKCE verifier and its S256 challenge, plus a `state` value for the
/// round trip through the browser.
class Pkce {
  Pkce._(this.verifier, this.challenge, this.state);

  factory Pkce.generate([Random? random]) {
    final rng = random ?? Random.secure();
    final verifier = _randomString(rng, 64);
    return Pkce._(verifier, challengeFor(verifier), _randomString(rng, 32));
  }

  final String verifier;
  final String challenge;
  final String state;

  static String challengeFor(String verifier) =>
      _base64Url(sha256.convert(ascii.encode(verifier)).bytes);

  static String _randomString(Random rng, int bytes) =>
      _base64Url(List<int>.generate(bytes, (_) => rng.nextInt(256)));

  static String _base64Url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
