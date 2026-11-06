import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sous/voice/model_downloader.dart';

final vad = VoiceModel(
  id: 'vad',
  url: Uri.parse('https://models.test/vad.onnx'),
  bytes: 4,
);
final voice = VoiceModel(
  id: 'voice',
  url: Uri.parse('https://models.test/voice.tar.bz2'),
  bytes: 6,
  folder: 'voice-v1',
);

void main() {
  late Directory root;
  late List<String> fetched;
  late List<String> extracted;
  var failVoice = false;

  ModelDownloader downloader() => ModelDownloader(
    root: () async => root,
    httpClient: MockClient.streaming((request, _) async {
      fetched.add(request.url.path);
      if (failVoice && request.url.path.endsWith('.tar.bz2')) {
        return http.StreamedResponse(Stream.value([1, 2]), 500);
      }
      final size = request.url.path.endsWith('.onnx') ? 4 : 6;
      return http.StreamedResponse(
        Stream.fromIterable([
          for (var i = 0; i < size; i += 2) [i, i + 1],
        ]),
        200,
      );
    }),
    extract: (archive, into) async {
      extracted.add(archive);
      expect(await File(archive).length(), 6);
      await Directory('$into/voice-v1').create(recursive: true);
      await File('$into/voice-v1/model.onnx').writeAsString('fake');
    },
  );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sous-models-');
    fetched = [];
    extracted = [];
    failVoice = false;
  });

  tearDown(() => root.delete(recursive: true));

  test('downloads, unpacks and reports progress across models', () async {
    final models = downloader();
    expect(await models.allReady([vad, voice]), isFalse);

    final progress = await models.download([vad, voice]).toList();

    expect(fetched, ['/vad.onnx', '/voice.tar.bz2']);
    expect(progress.first.received, 0);
    expect(progress.first.total, 10);
    expect(progress.first.current, 'vad');
    expect(
      progress.map((p) => p.received),
      orderedEquals([0, 2, 4, 4, 6, 8, 10, 10, 10]),
    );
    expect(progress.where((p) => p.extracting).single.current, 'voice');
    expect(progress.last.done, isTrue);
    expect(progress.last.fraction, 1);

    expect(await models.allReady([vad, voice]), isTrue);
    expect(await File(await models.pathOf(vad, 'vad.onnx')).length(), 4);
    expect(
      await File(await models.pathOf(voice, 'model.onnx')).readAsString(),
      'fake',
    );
    expect(File(extracted.single).existsSync(), isFalse);
  });

  test('skips what is already there', () async {
    await downloader().download([vad]).drain<void>();
    fetched.clear();

    final progress = await downloader().download([vad, voice]).toList();
    expect(fetched, ['/voice.tar.bz2']);
    expect(progress.first.total, 6);
  });

  test('a failed download leaves nothing half there and can retry', () async {
    failVoice = true;
    final models = downloader();
    await expectLater(
      models.download([vad, voice]).drain<void>(),
      throwsA(isA<HttpException>()),
    );
    expect(await models.isReady(vad), isTrue);
    expect(await models.isReady(voice), isFalse);
    expect(Directory('${root.path}/voice').existsSync(), isFalse);
    expect(root.listSync().map((e) => e.path.split('/').last), ['vad']);

    failVoice = false;
    await models.download([vad, voice]).drain<void>();
    expect(await models.allReady([vad, voice]), isTrue);
  });
}
