import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/workos_client.dart';
import 'brain_exception.dart';
import 'cooks.dart';
import 'json.dart';
import 'profile.dart';
import 'recipe.dart';
import 'session.dart';
import 'sse.dart';

/// Where the brain gets the cook's WorkOS access token.
abstract interface class AccessTokenSource {
  /// A token that isn't about to expire, or null when signed out.
  Future<String?> accessToken();

  /// A brand-new token after the brain rejected the last one, or null if the
  /// session is gone.
  Future<String?> refresh();

  /// The brain still says 401 after a refresh: sign the cook out.
  Future<void> rejected();
}

/// A typed client for the Sous brain at `/sous/api/v1`. Every failure is a
/// [BrainException].
class BrainClient {
  BrainClient({
    required this.baseUri,
    required http.Client httpClient,
    required this._tokens,
    this.timeout = const Duration(seconds: 30),
    this.slowTimeout = const Duration(seconds: 90),
  }) : _http = httpClient;

  final Uri baseUri;

  /// For plain reads and writes, and for a turn's response headers.
  final Duration timeout;

  /// For `/suggest`, which waits on Claude.
  final Duration slowTimeout;
  final http.Client _http;
  final AccessTokenSource _tokens;

  Future<Profile> getMe() async => Profile.fromJson(await _json('GET', '/me'));

  /// Merges [preferences] into what's saved (a null value removes that key)
  /// and replaces [about] when given.
  Future<Profile> updateMe({Json? preferences, String? about}) async =>
      Profile.fromJson(
        await _json(
          'PATCH',
          '/me',
          body: {'preferences': ?preferences, 'about': ?about},
        ),
      );

  /// Deletes the account and everything Sou knows. Sign out afterwards.
  Future<void> deleteMe() => _send('DELETE', '/me');

  Future<List<Recipe>> listRecipes() async =>
      listOf((await _json('GET', '/recipes'))['recipes'], Recipe.fromJson);

  Future<Recipe> getRecipe(String id) async =>
      Recipe.fromJson(await _json('GET', '/recipes/${_id(id)}'));

  /// Saves a recipe. A bad one is [BrainError.invalid] with `issues` in
  /// [BrainException.details].
  Future<Recipe> createRecipe(Recipe recipe) async =>
      Recipe.fromJson(await _json('POST', '/recipes', body: recipe.toJson()));

  Future<void> deleteRecipe(String id) =>
      _send('DELETE', '/recipes/${_id(id)}');

  /// Up to five saved recipes, best first. Takes a few seconds.
  Future<List<Suggestion>> suggest() async => listOf(
    (await _json('GET', '/suggest', timeout: slowTimeout))['suggestions'],
    Suggestion.fromJson,
  );

  /// Finished cooks, newest first.
  Future<List<Cook>> history() async =>
      listOf((await _json('GET', '/history'))['cooks'], Cook.fromJson);

  Future<StartedSession> startSession(String recipeId) async =>
      StartedSession.fromJson(
        await _json('POST', '/sessions', body: {'recipe_id': recipeId}),
      );

  /// Sends one turn and streams Sou's reply. A refused turn throws before the
  /// first event; a reply that breaks off throws [BrainError.network].
  Stream<StreamEvent> takeTurn(String sessionId, TurnRequest request) async* {
    final response = await _request(
      'POST',
      '/sessions/${_id(sessionId)}/turns',
      body: request.toJson(),
      headers: {'Accept': 'text/event-stream'},
    );
    try {
      await for (final message in parseSse(response.stream)) {
        final Object? json;
        try {
          json = jsonDecode(message.data);
        } on FormatException {
          continue;
        }
        if (json is! Json) continue;
        final event = StreamEvent.fromJson(json);
        if (event != null) yield event;
      }
    } on http.ClientException catch (e) {
      throw BrainException(BrainError.network, details: {'message': e.message});
    }
  }

  /// Ends the session and queues Sou's reflection on it.
  Future<EndedSession> endSession(
    String sessionId, {
    int? rating,
    String? notes,
  }) async => EndedSession.fromJson(
    await _json(
      'POST',
      '/sessions/${_id(sessionId)}/end',
      body: {'rating': ?rating, 'notes': ?notes},
    ),
  );

  Future<SessionView> getSession(String sessionId) async =>
      SessionView.fromJson(await _json('GET', '/sessions/${_id(sessionId)}'));

  Future<Json> _json(
    String method,
    String path, {
    Json? body,
    Duration? timeout,
  }) async {
    final response = await _request(method, path, body: body, timeout: timeout);
    final text = await _readBody(response, timeout);
    try {
      return jsonDecode(text) as Json;
    } on Object {
      throw BrainException(
        BrainError.retryable,
        status: response.statusCode,
        code: 'bad_response',
      );
    }
  }

  Future<void> _send(String method, String path) async {
    final response = await _request(method, path);
    await _readBody(response, null);
  }

  /// Sends with a fresh token, refreshing once on a 401, and throws for any
  /// non-2xx status.
  Future<http.StreamedResponse> _request(
    String method,
    String path, {
    Json? body,
    Map<String, String> headers = const {},
    Duration? timeout,
  }) async {
    var token = await _token(_tokens.accessToken);
    var response = await _sendOnce(method, path, token, body, headers, timeout);
    if (response.statusCode == 401) {
      await response.stream.drain<void>().catchError((_) {});
      token = await _token(_tokens.refresh);
      response = await _sendOnce(method, path, token, body, headers, timeout);
      if (response.statusCode == 401) {
        await response.stream.drain<void>().catchError((_) {});
        await _tokens.rejected();
        throw const BrainException(BrainError.signedOut, status: 401);
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }
    final text = await _readBody(response, timeout).catchError((_) => '');
    throw BrainException.fromResponse(response.statusCode, text);
  }

  Future<String> _token(Future<String?> Function() get) async {
    final String? token;
    try {
      token = await get();
    } on WorkosException {
      throw const BrainException(BrainError.network, code: 'refresh_failed');
    }
    if (token == null) throw const BrainException(BrainError.signedOut);
    return token;
  }

  Future<http.StreamedResponse> _sendOnce(
    String method,
    String path,
    String token,
    Json? body,
    Map<String, String> headers,
    Duration? timeout,
  ) async {
    final request =
        http.Request(method, baseUri.replace(path: '${baseUri.path}$path'))
          ..headers.addAll({
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
            ...headers,
          });
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      return await _http.send(request).timeout(timeout ?? this.timeout);
    } on TimeoutException {
      throw const BrainException(BrainError.network, code: 'timeout');
    } on http.ClientException catch (e) {
      throw BrainException(BrainError.network, details: {'message': e.message});
    }
  }

  Future<String> _readBody(
    http.StreamedResponse response,
    Duration? timeout,
  ) async {
    try {
      return await response.stream.bytesToString().timeout(
        timeout ?? this.timeout,
      );
    } on TimeoutException {
      throw const BrainException(BrainError.network, code: 'timeout');
    } on http.ClientException catch (e) {
      throw BrainException(BrainError.network, details: {'message': e.message});
    }
  }

  static String _id(String id) => Uri.encodeComponent(id);
}
