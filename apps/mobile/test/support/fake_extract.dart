import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sous/shares/shares_client.dart';

import 'fakes.dart';

/// A stand-in for `workers/extract` at `/sous/api/v1/shares`, keeping shares
/// in memory and answering the way the real Worker does.
class FakeExtract {
  FakeExtract() : tokens = FakeTokenSource();

  final FakeTokenSource tokens;
  final shares = <String, Map<String, Object?>>{};
  final requests = <(String method, String path, Object? body, String? auth)>[];

  /// Answer every request with 401, as if every token were bad.
  bool rejectTokens = false;

  /// Answer every request with this status instead (e.g. 503), or null.
  int? failWith;

  /// Error code to send with [failWith].
  String? failCode;

  /// What a new link share becomes: `reading` (default) or a final status.
  String newStatus = 'reading';
  var _n = 0;

  late final client = SharesClient(
    baseUri: Uri.parse('https://build40for40.test/sous/api/v1'),
    httpClient: MockClient(_handle),
    tokens: tokens,
  );

  /// The server finishing a share: e.g. `finish(id, 'saved', recipeId: 'r1')`.
  void finish(
    String id,
    String status, {
    String? recipeId,
    String? reason,
    String? title,
  }) {
    shares[id] = {
      ...shares[id]!,
      'status': status,
      'recipe_id': recipeId,
      'reason': reason,
      'title': title,
      'updated_at': _now(),
    };
  }

  Future<http.Response> _handle(http.Request request) async {
    final path = request.url.path.replaceFirst('/sous/api/v1', '');
    final body = request.body.isEmpty ? null : jsonDecode(request.body);
    requests.add((
      request.method,
      path,
      body,
      request.headers['Authorization'],
    ));
    if (rejectTokens ||
        !(request.headers['Authorization'] ?? '').startsWith('Bearer token')) {
      return _json({'error': 'sign_in_required'}, 401);
    }
    if (failWith != null) {
      return _json({'error': failCode ?? 'boom', 'limit': 50}, failWith!);
    }

    if (path == '/shares' && request.method == 'GET') {
      final list = shares.values.toList()
        ..sort(
          (a, b) =>
              (b['created_at'] as String).compareTo(a['created_at'] as String),
        );
      return _json({'shares': list});
    }
    if (path == '/shares' && request.method == 'DELETE') {
      shares.clear();
      return http.Response('', 204);
    }
    if (path == '/shares' && request.method == 'POST') {
      final b = body as Map<String, Object?>;
      if (b['image'] != null) return _json(_add('screenshot', null), 202);
      final url = b['url'] as String;
      final match = RegExp(r'https?://\S+').firstMatch(url);
      if (match == null) return _json({'error': 'unsupported_link'}, 422);
      final clean = match.group(0)!.split('?').first;
      final existing = shares.values.where((s) => s['url'] == clean);
      if (existing.isNotEmpty) {
        final s = existing.first;
        if (s['status'] == 'needs_screenshot') {
          s['status'] = 'reading';
          return _json(s, 202);
        }
        return _json({...s, 'duplicate': true});
      }
      return _json(_add('link', clean), 202);
    }
    final m = RegExp(r'^/shares/([\w-]+)(/screenshot)?$').firstMatch(path);
    if (m != null) {
      final share = shares[m.group(1)];
      if (share == null) return _json({'error': 'share_not_found'}, 404);
      if (m.group(2) != null) {
        if (share['status'] == 'reading') {
          return _json({'error': 'share_in_progress'}, 409);
        }
        if (share['status'] != 'needs_screenshot') {
          return _json({'error': 'screenshot_not_needed'}, 409);
        }
        share['status'] = 'reading';
        share['kind'] = 'screenshot';
        return _json(share, 202);
      }
      if (request.method == 'DELETE') {
        shares.remove(m.group(1));
        return http.Response('', 204);
      }
      return _json(share);
    }
    return _json({'error': 'not_found'}, 404);
  }

  Map<String, Object?> _add(String kind, String? url) {
    final id = '00000000-0000-4000-8000-${(++_n).toString().padLeft(12, '0')}';
    final now = _now();
    return shares[id] = {
      'id': id,
      'kind': kind,
      'url': url,
      'status': newStatus,
      'reason': null,
      'title': null,
      'creator': null,
      'recipe_id': null,
      'source_used': null,
      'completeness': null,
      'missing': <String>[],
      'created_at': now,
      'updated_at': now,
    };
  }

  String _now() => DateTime.utc(2026, 11, 6, 18, 0, _n).toIso8601String();

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: {'content-type': 'application/json'},
  );
}
