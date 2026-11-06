import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../api/brain_client.dart';
import '../api/json.dart';
import '../auth/workos_client.dart';
import 'share.dart';

/// The states a failed `/shares` call lands in.
enum ShareError {
  /// 401: the cook has to sign in again.
  signedOut,

  /// 422 `unsupported_link`: not an Instagram post or a web page.
  unsupportedLink,

  /// 429 `daily_limit`: too many reads today ([ShareException.limit]).
  dailyLimit,

  /// 503 `extraction_unavailable`: switched off on the server.
  unavailable,

  /// 409 `share_in_progress`: still reading; wait for it.
  inProgress,

  /// 409 `screenshot_not_needed`: the share isn't `needs_screenshot`.
  screenshotNotNeeded,

  /// 413 `image_too_large`, even after downscaling.
  imageTooLarge,

  /// 404.
  notFound,

  /// 400 or another 4xx: the request itself was wrong. Retrying won't help.
  invalid,

  /// 5xx: worth trying again.
  retryable,

  /// No connection or a timeout: worth trying again.
  network;

  /// Whether sending the same share again later could work.
  bool get isTemporary =>
      this == retryable ||
      this == network ||
      this == signedOut ||
      this == unavailable;
}

class ShareException implements Exception {
  const ShareException(this.error, {this.status, this.code, this.limit});

  factory ShareException.fromResponse(int status, String body) {
    Json? json;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Json) json = decoded;
    } on FormatException {
      json = null;
    }
    final code = json?['error'] as String?;
    final error = switch ((status, code)) {
      (401, _) => ShareError.signedOut,
      (422, _) => ShareError.unsupportedLink,
      (429, _) => ShareError.dailyLimit,
      (503, _) => ShareError.unavailable,
      (409, 'screenshot_not_needed') => ShareError.screenshotNotNeeded,
      (409, _) => ShareError.inProgress,
      (413, _) => ShareError.imageTooLarge,
      (404, _) => ShareError.notFound,
      (>= 500, _) => ShareError.retryable,
      _ => ShareError.invalid,
    };
    return ShareException(
      error,
      status: status,
      code: code,
      limit: json?['limit'] as int?,
    );
  }

  final ShareError error;
  final int? status;

  /// The server's error code, e.g. `daily_limit`.
  final String? code;

  /// For [ShareError.dailyLimit]: reads allowed per day.
  final int? limit;

  @override
  String toString() => 'ShareException(${error.name}, $status, $code)';
}

/// A typed client for `workers/extract` at `/sous/api/v1/shares`, signed in
/// with the same WorkOS token as the brain. Every failure is a
/// [ShareException]. See `workers/extract/README.md`.
class SharesClient {
  SharesClient({
    required this.baseUri,
    required http.Client httpClient,
    required this._tokens,
    this.timeout = const Duration(seconds: 30),
  }) : _http = httpClient;

  final Uri baseUri;
  final Duration timeout;
  final http.Client _http;
  final AccessTokenSource _tokens;

  /// Shares a link: whatever the share sheet gave, words and all. A post the
  /// cook already shared comes back with [Share.duplicate]; one that came back
  /// `needs_screenshot` is read again.
  Future<Share> shareLink(String text) async =>
      Share.fromJson(await _json('POST', '', body: {'url': text}));

  /// Shares a screenshot on its own. [bytes] must already be under the
  /// server's limit (see `prepareScreenshot`).
  Future<Share> shareScreenshot(Uint8List bytes, String mediaType) async =>
      Share.fromJson(
        await _json('POST', '', body: {'image': _image(bytes, mediaType)}),
      );

  /// Sends a screenshot for a share that came back `needs_screenshot`.
  Future<Share> addScreenshot(
    String shareId,
    Uint8List bytes,
    String mediaType,
  ) async => Share.fromJson(
    await _json(
      'POST',
      '/${_id(shareId)}/screenshot',
      body: {'image': _image(bytes, mediaType)},
    ),
  );

  /// The cook's shares, newest first.
  Future<List<Share>> listShares() async =>
      listOf((await _json('GET', ''))['shares'], Share.fromJson);

  Future<Share> getShare(String shareId) async =>
      Share.fromJson(await _json('GET', '/${_id(shareId)}'));

  /// Forgets one share. A recipe it saved stays in the brain.
  Future<void> deleteShare(String shareId) async {
    await _send('DELETE', '/${_id(shareId)}');
  }

  /// Forgets every share: the extraction half of deleting an account. Call it
  /// before the brain's `DELETE /me`, which ends the WorkOS session.
  Future<void> deleteAllShares() async {
    await _send('DELETE', '');
  }

  Json _image(Uint8List bytes, String mediaType) => {
    'media_type': mediaType,
    'data': base64Encode(bytes),
  };

  Future<Json> _json(String method, String path, {Json? body}) async {
    final text = await _send(method, path, body: body);
    try {
      return jsonDecode(text) as Json;
    } on Object {
      throw const ShareException(ShareError.retryable, code: 'bad_response');
    }
  }

  /// Sends with a fresh token, refreshing once on a 401, and throws for any
  /// non-2xx status. Returns the body.
  Future<String> _send(String method, String path, {Json? body}) async {
    var token = await _token(_tokens.accessToken);
    var response = await _once(method, path, token, body);
    if (response.statusCode == 401) {
      token = await _token(_tokens.refresh);
      response = await _once(method, path, token, body);
      if (response.statusCode == 401) {
        await _tokens.rejected();
        throw const ShareException(ShareError.signedOut, status: 401);
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response.body;
    }
    throw ShareException.fromResponse(response.statusCode, response.body);
  }

  Future<String> _token(Future<String?> Function() get) async {
    final String? token;
    try {
      token = await get();
    } on WorkosException {
      throw const ShareException(ShareError.network, code: 'refresh_failed');
    }
    if (token == null) throw const ShareException(ShareError.signedOut);
    return token;
  }

  Future<http.Response> _once(
    String method,
    String path,
    String token,
    Json? body,
  ) async {
    final uri = baseUri.replace(path: '${baseUri.path}/shares$path');
    final request = http.Request(method, uri)
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      });
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    try {
      return await http.Response.fromStream(
        await _http.send(request).timeout(timeout),
      ).timeout(timeout);
    } on TimeoutException {
      throw const ShareException(ShareError.network, code: 'timeout');
    } on http.ClientException {
      throw const ShareException(ShareError.network);
    }
  }

  static String _id(String id) => Uri.encodeComponent(id);
}
