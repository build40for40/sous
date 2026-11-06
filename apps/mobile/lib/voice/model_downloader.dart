import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;

/// A model file or `.tar.bz2` archive a local engine needs.
class VoiceModel {
  const VoiceModel({
    required this.id,
    required this.url,
    required this.bytes,
    this.folder,
  });

  /// Also the folder it lands in under the download root.
  final String id;
  final Uri url;

  /// Download size, for progress before the server says.
  final int bytes;

  /// For an archive, the folder inside it that holds the files. Null for a
  /// single file, which is saved under its own name.
  final String? folder;

  bool get isArchive => folder != null;
}

class DownloadProgress {
  const DownloadProgress({
    required this.received,
    required this.total,
    this.current,
    this.extracting = false,
  });

  final int received;
  final int total;

  /// The model being fetched, or null once everything is ready.
  final String? current;

  /// True while an archive is being unpacked after its download.
  final bool extracting;

  bool get done => current == null;

  double get fraction => total == 0 ? 1 : (received / total).clamp(0, 1);
}

typedef Extractor = Future<void> Function(String archive, String into);

Future<void> _extractInIsolate(String archive, String into) =>
    Isolate.run(() => extractFileToDisk(archive, into));

/// Fetches models on first run instead of bundling them, and finds them
/// afterwards. A model counts as there only once it has fully downloaded and
/// unpacked, so a run that dies halfway starts that model again.
class ModelDownloader {
  ModelDownloader({
    required this._root,
    http.Client? httpClient,
    Extractor? extract,
  }) : _http = httpClient ?? http.Client(),
       _extract = extract ?? _extractInIsolate;

  final Future<Directory> Function() _root;
  final http.Client _http;
  final Extractor _extract;

  static const _readyMarker = '.ready';

  /// Where [model]'s files are once it's ready.
  Future<Directory> folderFor(VoiceModel model) async {
    final base = Directory('${(await _root()).path}/${model.id}');
    return model.isArchive ? Directory('${base.path}/${model.folder}') : base;
  }

  /// The path of a file inside [model]'s folder.
  Future<String> pathOf(VoiceModel model, String file) async =>
      '${(await folderFor(model)).path}/$file';

  Future<bool> isReady(VoiceModel model) async =>
      File('${(await _root()).path}/${model.id}/$_readyMarker').exists();

  Future<bool> allReady(Iterable<VoiceModel> models) async {
    for (final model in models) {
      if (!await isReady(model)) return false;
    }
    return true;
  }

  /// Downloads whichever of [models] aren't there yet, reporting progress
  /// across all of them. Errors end the stream; call again to retry.
  Stream<DownloadProgress> download(List<VoiceModel> models) async* {
    final missing = [
      for (final model in models)
        if (!await isReady(model)) model,
    ];
    final total = missing.fold(0, (sum, m) => sum + m.bytes);
    var received = 0;
    final root = await _root();
    await root.create(recursive: true);

    for (final model in missing) {
      final dir = Directory('${root.path}/${model.id}');
      if (await dir.exists()) await dir.delete(recursive: true);
      final part = File(
        '${root.path}/${model.id}.part${model.isArchive ? '.tar.bz2' : ''}',
      );
      final before = received;
      yield DownloadProgress(
        received: received,
        total: total,
        current: model.id,
      );

      try {
        final response = await _http.send(http.Request('GET', model.url));
        if (response.statusCode != 200) {
          throw HttpException(
            'Model download failed (${response.statusCode})',
            uri: model.url,
          );
        }
        final sink = part.openWrite();
        try {
          await for (final bytes in response.stream) {
            sink.add(bytes);
            received = (received + bytes.length).clamp(0, before + model.bytes);
            yield DownloadProgress(
              received: received,
              total: total,
              current: model.id,
            );
          }
        } finally {
          await sink.close();
        }

        await dir.create(recursive: true);
        if (model.isArchive) {
          yield DownloadProgress(
            received: received,
            total: total,
            current: model.id,
            extracting: true,
          );
          await _extract(part.path, dir.path);
          await part.delete();
        } else {
          await part.rename('${dir.path}/${model.url.pathSegments.last}');
        }
        await File('${dir.path}/$_readyMarker').writeAsString(model.url.path);
        received = before + model.bytes;
      } catch (_) {
        if (await part.exists()) await part.delete();
        if (await dir.exists()) await dir.delete(recursive: true);
        rethrow;
      }
    }
    yield DownloadProgress(received: total, total: total);
  }
}
