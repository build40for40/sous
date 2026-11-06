import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'pkce.dart';
import 'session_tokens.dart';

/// Why talking to WorkOS failed. [rejected] is final: the code or refresh
/// token is no good and the cook has to sign in again. [transient] (network,
/// rate limit, WorkOS down) is worth retrying with the same session.
enum WorkosFailure { rejected, transient }

class WorkosException implements Exception {
  const WorkosException(this.failure, this.message);

  final WorkosFailure failure;
  final String message;

  @override
  String toString() => 'WorkosException(${failure.name}: $message)';
}

/// AuthKit's user management API as a public client: PKCE for sign-in and
/// refresh tokens for staying signed in, with only the client id.
class WorkosClient {
  WorkosClient({
    required this.clientId,
    required this.redirectUri,
    required this.apiBase,
    required http.Client httpClient,
    this.timeout = const Duration(seconds: 20),
  }) : _http = httpClient;

  final String clientId;
  final Uri redirectUri;
  final Uri apiBase;
  final Duration timeout;
  final http.Client _http;

  /// The hosted AuthKit page to open in the system browser.
  Uri authorizationUrl(Pkce pkce, {bool signUp = false}) => apiBase.replace(
    path: '/user_management/authorize',
    queryParameters: {
      'response_type': 'code',
      'client_id': clientId,
      'redirect_uri': redirectUri.toString(),
      'provider': 'authkit',
      'code_challenge': pkce.challenge,
      'code_challenge_method': 'S256',
      'state': pkce.state,
      if (signUp) 'screen_hint': 'sign-up',
    },
  );

  Future<SessionTokens> authenticateWithCode(String code, String verifier) =>
      _authenticate({
        'grant_type': 'authorization_code',
        'code': code,
        'code_verifier': verifier,
      });

  Future<SessionTokens> authenticateWithRefreshToken(String refreshToken) =>
      _authenticate({
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      });

  Future<SessionTokens> _authenticate(Map<String, String> grant) async {
    final http.Response response;
    try {
      response = await _http
          .post(
            apiBase.replace(path: '/user_management/authenticate'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'client_id': clientId, ...grant}),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const WorkosException(WorkosFailure.transient, 'timed out');
    } on http.ClientException catch (e) {
      throw WorkosException(WorkosFailure.transient, e.message);
    }

    final body = _decode(response.body);
    if (response.statusCode == 200 && body != null) {
      try {
        return SessionTokens.fromAuthenticateResponse(body);
      } on TypeError {
        throw const WorkosException(
          WorkosFailure.transient,
          'unexpected response',
        );
      }
    }
    final message =
        (body?['error_description'] ??
                body?['message'] ??
                body?['error'] ??
                'HTTP ${response.statusCode}')
            .toString();
    final retryable = response.statusCode >= 500 || response.statusCode == 429;
    throw WorkosException(
      retryable ? WorkosFailure.transient : WorkosFailure.rejected,
      message,
    );
  }

  static Map<String, Object?>? _decode(String body) {
    try {
      final json = jsonDecode(body);
      return json is Map<String, Object?> ? json : null;
    } on FormatException {
      return null;
    }
  }
}
