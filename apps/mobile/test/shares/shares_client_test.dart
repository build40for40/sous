import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sous/shares/share.dart';
import 'package:sous/shares/shares_client.dart';

import '../support/fake_extract.dart';

void main() {
  late FakeExtract server;

  setUp(() => server = FakeExtract());

  test('shares a link as the share sheet gave it, with the token', () async {
    final share = await server.client.shareLink(
      'Check this out https://www.instagram.com/reel/DTwZpo5DNVr/?igsh=abc',
    );
    expect(share.status, ShareStatus.reading);
    expect(share.url, 'https://www.instagram.com/reel/DTwZpo5DNVr/');
    final (method, path, body, auth) = server.requests.single;
    expect((method, path, auth), ('POST', '/shares', 'Bearer token-1'));
    expect(body, {
      'url':
          'Check this out https://www.instagram.com/reel/DTwZpo5DNVr/?igsh=abc',
    });
  });

  test('reports a duplicate, and re-reads a needs_screenshot link', () async {
    final first = await server.client.shareLink('https://instagram.com/p/A1');
    server.finish(first.id, 'saved', recipeId: 'r1');
    final again = await server.client.shareLink('https://instagram.com/p/A1');
    expect(again.duplicate, isTrue);
    expect(again.recipeId, 'r1');

    final second = await server.client.shareLink('https://instagram.com/p/B2');
    server.finish(second.id, 'needs_screenshot', reason: 'In the comments.');
    final retried = await server.client.shareLink('https://instagram.com/p/B2');
    expect(
      (retried.id, retried.status, retried.duplicate),
      (second.id, ShareStatus.reading, false),
    );
  });

  test('sends screenshots as base64 with their type', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    await server.client.shareScreenshot(bytes, 'image/png');
    final body = server.requests.single.$3 as Map<String, Object?>;
    expect(body['image'], {
      'media_type': 'image/png',
      'data': base64Encode(bytes),
    });
  });

  test('only takes a screenshot for a share that needs one', () async {
    final share = await server.client.shareLink('https://instagram.com/p/C3');
    final png = Uint8List.fromList([1]);
    await expectLater(
      server.client.addScreenshot(share.id, png, 'image/png'),
      throwsA(
        isA<ShareException>().having(
          (e) => e.error,
          'error',
          ShareError.inProgress,
        ),
      ),
    );
    server.finish(share.id, 'saved', recipeId: 'r');
    await expectLater(
      server.client.addScreenshot(share.id, png, 'image/png'),
      throwsA(
        isA<ShareException>().having(
          (e) => e.error,
          'error',
          ShareError.screenshotNotNeeded,
        ),
      ),
    );
    server.finish(share.id, 'needs_screenshot');
    final rescued = await server.client.addScreenshot(
      share.id,
      png,
      'image/png',
    );
    expect((rescued.status, rescued.kind), (ShareStatus.reading, 'screenshot'));
    expect(server.requests.last.$2, '/shares/${share.id}/screenshot');
  });

  test('maps the API errors', () async {
    Future<ShareError> errorFor(int status, String code) async {
      server
        ..failWith = status
        ..failCode = code;
      try {
        await server.client.listShares();
      } on ShareException catch (e) {
        return e.error;
      }
      fail('no error');
    }

    expect(await errorFor(422, 'unsupported_link'), ShareError.unsupportedLink);
    expect(await errorFor(429, 'daily_limit'), ShareError.dailyLimit);
    expect(
      await errorFor(503, 'extraction_unavailable'),
      ShareError.unavailable,
    );
    expect(await errorFor(409, 'share_in_progress'), ShareError.inProgress);
    expect(
      await errorFor(409, 'screenshot_not_needed'),
      ShareError.screenshotNotNeeded,
    );
    expect(await errorFor(413, 'image_too_large'), ShareError.imageTooLarge);
    expect(await errorFor(404, 'share_not_found'), ShareError.notFound);
    expect(await errorFor(400, 'invalid_share'), ShareError.invalid);
    expect(await errorFor(502, 'bad_gateway'), ShareError.retryable);

    server
      ..failWith = 429
      ..failCode = 'daily_limit';
    await expectLater(
      server.client.listShares(),
      throwsA(isA<ShareException>().having((e) => e.limit, 'limit', 50)),
    );
  });

  test('refreshes the token once on a 401, then signs out', () async {
    server.rejectTokens = true;
    await expectLater(
      server.client.listShares(),
      throwsA(
        isA<ShareException>().having(
          (e) => e.error,
          'error',
          ShareError.signedOut,
        ),
      ),
    );
    expect(server.tokens.refreshes, 1);
    expect(server.tokens.wasRejected, isTrue);
    expect(server.requests.map((r) => r.$4), [
      'Bearer token-1',
      'Bearer token-2',
    ]);
  });

  test('lists, gets and deletes shares, and deletes them all', () async {
    final a = await server.client.shareLink('https://instagram.com/p/D4');
    await server.client.shareLink('https://instagram.com/p/E5');
    expect((await server.client.listShares()).length, 2);
    expect((await server.client.getShare(a.id)).id, a.id);
    await server.client.deleteShare(a.id);
    expect((await server.client.listShares()).length, 1);
    await server.client.deleteAllShares();
    expect(await server.client.listShares(), isEmpty);
    expect(server.requests.last.$1, 'GET');
    expect(server.requests[server.requests.length - 2], (
      'DELETE',
      '/shares',
      null,
      'Bearer token-1',
    ));
  });

  test('parses a share and knows what the cook can do with it', () {
    final share = Share.fromJson({
      'id': 's1',
      'kind': 'link',
      'url': 'https://www.instagram.com/p/X/',
      'status': 'needs_screenshot',
      'reason': 'The recipe is in the comments.',
      'missing': ['quantities'],
      'created_at': '2026-11-06T18:00:00Z',
      'updated_at': '2026-11-06T18:01:00Z',
    });
    expect(share.status, ShareStatus.needsScreenshot);
    expect(share.canRetry, isTrue);
    expect(share.canAddScreenshot, isTrue);
    expect(share.missing, ['quantities']);
    expect(ShareStatus.parse('something_new'), ShareStatus.unknown);
  });
}
