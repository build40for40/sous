import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sous/shares/pending_shares.dart';
import 'package:sous/shares/screenshot.dart';
import 'package:sous/shares/share.dart';
import 'package:sous/shares/share_inbox.dart';
import 'package:sous/shares/share_receiver.dart';
import 'package:sous/shares/shares_client.dart';

import '../support/fake_extract.dart';

class FakeReceiver implements ShareReceiver {
  final controller = StreamController<IncomingShare>();

  @override
  Stream<IncomingShare> shares() => controller.stream;
}

void main() {
  late FakeExtract server;
  late MemoryPendingShareStore store;
  late ShareInbox inbox;
  final files = <String, Uint8List>{};

  ShareInbox makeInbox() => ShareInbox(
    client: server.client,
    store: store,
    pollEvery: const Duration(milliseconds: 10),
    readFile: (path) async =>
        files[path] ?? (throw FileSystemException('gone', path)),
    prepare: (bytes) async => PreparedScreenshot(bytes, 'image/jpeg'),
  );

  setUp(() {
    server = FakeExtract();
    store = MemoryPendingShareStore();
    files
      ..clear()
      ..['/tmp/shot.png'] = Uint8List.fromList([1, 2, 3]);
    inbox = makeInbox();
  });

  tearDown(() => inbox.dispose());

  test('sends a shared link and shows it reading', () async {
    await inbox.receive(
      const IncomingText('https://www.instagram.com/reel/DTwZpo5DNVr/?igsh=x'),
    );
    expect(inbox.state.pending, 0);
    expect(inbox.state.shares.single.status, ShareStatus.reading);
    expect(store.saved, isEmpty);
  });

  test('follows a reading share until it is saved', () async {
    await inbox.receive(const IncomingText('https://instagram.com/p/Poll1'));
    final id = inbox.state.shares.single.id;
    final saved = inbox.states.firstWhere(
      (s) => s.shares.isNotEmpty && s.shares.first.status == ShareStatus.saved,
    );
    server.finish(id, 'saved', recipeId: 'recipe-1', title: 'Cookies');
    final state = await saved.timeout(const Duration(seconds: 2));
    expect(state.shares.single.recipeId, 'recipe-1');
    expect(state.anyReading, isFalse);
  });

  test(
    'keeps shares made while signed out and sends them on sign-in',
    () async {
      server.tokens.signedIn = false;
      await inbox.receive(const IncomingText('https://instagram.com/p/Later1'));
      expect(inbox.state.pending, 1);
      expect(store.saved.single.text, 'https://instagram.com/p/Later1');

      // The app restarts: a new inbox finds what was waiting.
      inbox.dispose();
      inbox = makeInbox();
      server.tokens.signedIn = true;
      await inbox.flush();
      expect(inbox.state.pending, 0);
      expect(inbox.state.shares.single.url, 'https://instagram.com/p/Later1');
    },
  );

  test('keeps a share while offline or at the daily limit, and drops one the server will never take', () async {
    server.failWith = 503;
    await inbox.receive(const IncomingText('https://instagram.com/p/Busy1'));
    expect(inbox.state.pending, 1);
    server
      ..failWith = 429
      ..failCode = 'daily_limit';
    await inbox.flush();
    expect(inbox.state.pending, 1);
    expect(inbox.state.error?.limit, 50);

    server.failWith = null;
    await inbox.receive(const IncomingText('just words, no link'));
    expect(
      inbox.state.pending,
      0,
      reason: 'the busy one was sent, the bad one dropped',
    );
    expect(inbox.state.shares.single.url, 'https://instagram.com/p/Busy1');
    expect(inbox.state.error?.error, ShareError.unsupportedLink);
  });

  test('sends a screenshot, then lets go of the kept copy', () async {
    await inbox.receive(const IncomingImage('/tmp/shot.png'));
    expect(inbox.state.shares.single.kind, 'screenshot');
    expect(store.discarded, ['/tmp/shot.png']);
    final body = server.requests.single.$3 as Map<String, Object?>;
    expect((body['image'] as Map)['media_type'], 'image/jpeg');
  });

  test('drops a screenshot whose file has gone', () async {
    await inbox.receive(const IncomingImage('/tmp/missing.png'));
    expect(inbox.state.pending, 0);
    expect(server.requests, isEmpty);
  });

  test('rescues a needs_screenshot share with a screenshot, or by sharing it again', () async {
    await inbox.receive(const IncomingText('https://instagram.com/p/Cmnt1'));
    final share = inbox.state.shares.single;
    server.finish(share.id, 'needs_screenshot', reason: 'In the comments.');
    await inbox.refresh();
    expect(inbox.state.shares.single.canAddScreenshot, isTrue);

    await inbox.retry(inbox.state.shares.single);
    expect(inbox.state.shares.single.status, ShareStatus.reading);

    server.finish(share.id, 'needs_screenshot');
    await inbox.refresh();
    await inbox.addScreenshot(share.id, '/tmp/shot.png');
    expect(server.requests.last.$2, '/shares/${share.id}/screenshot');
    expect(inbox.state.shares.single.kind, 'screenshot');
  });

  test(
    'a saved share can\'t take a screenshot; the attempt is dropped',
    () async {
      await inbox.receive(const IncomingText('https://instagram.com/p/Done1'));
      final id = inbox.state.shares.single.id;
      server.finish(id, 'saved', recipeId: 'r');
      await inbox.addScreenshot(id, '/tmp/shot.png');
      expect(inbox.state.pending, 0);
      expect(inbox.state.error?.code, 'screenshot_not_needed');
    },
  );

  test(
    'deleteAll forgets shares on the server and anything waiting here',
    () async {
      await inbox.receive(const IncomingText('https://instagram.com/p/Mine1'));
      server.tokens.signedIn = false;
      await inbox.receive(const IncomingText('https://instagram.com/p/Mine2'));
      server.tokens.signedIn = true;
      await inbox.deleteAll();
      expect(server.shares, isEmpty);
      expect(inbox.state.shares, isEmpty);
      expect(inbox.state.pending, 0);
      expect(store.saved, isEmpty);
    },
  );

  test('takes shares from the receiver once started', () async {
    final receiver = FakeReceiver();
    await inbox.start(receiver);
    final got = inbox.states.firstWhere((s) => s.shares.isNotEmpty);
    receiver.controller.add(const IncomingText('https://instagram.com/p/Rx1'));
    expect(
      (await got.timeout(const Duration(seconds: 2))).shares.single.url,
      'https://instagram.com/p/Rx1',
    );
  });
}
