import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A share that hasn't reached the server yet: the cook was signed out or
/// offline, or the server was busy. Kept until it's sent.
class PendingShare {
  const PendingShare({
    required this.id,
    required this.addedAt,
    this.text,
    this.imagePath,
    this.forShareId,
  }) : assert((text == null) != (imagePath == null));

  factory PendingShare.fromJson(Map<String, Object?> json) => PendingShare(
    id: json['id'] as String,
    addedAt: DateTime.parse(json['added_at'] as String),
    text: json['text'] as String?,
    imagePath: json['image_path'] as String?,
    forShareId: json['for_share_id'] as String?,
  );

  final String id;
  final DateTime addedAt;

  /// A shared link or text.
  final String? text;

  /// A screenshot, copied somewhere that survives until it's sent.
  final String? imagePath;

  /// For a screenshot sent to rescue a share that came back
  /// `needs_screenshot`.
  final String? forShareId;

  Map<String, Object?> toJson() => {
    'id': id,
    'added_at': addedAt.toIso8601String(),
    'text': ?text,
    'image_path': ?imagePath,
    'for_share_id': ?forShareId,
  };
}

/// Where pending shares wait.
abstract interface class PendingShareStore {
  Future<List<PendingShare>> load();

  Future<void> save(List<PendingShare> shares);

  /// Copies a shared image somewhere it survives until it's sent (the
  /// platform's copy can be cleaned up), returning the new path.
  Future<String> keepImage(String path, String id);

  /// Removes a kept image once it's sent or dropped.
  Future<void> discardImage(String path);
}

/// Pending shares as a JSON file, and their images, in the app's support
/// directory.
class FilePendingShareStore implements PendingShareStore {
  FilePendingShareStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;

  Future<File> get _file async =>
      File('${(await _directory()).path}/pending_shares.json');

  @override
  Future<List<PendingShare>> load() async {
    final file = await _file;
    if (!await file.exists()) return [];
    try {
      final list = jsonDecode(await file.readAsString()) as List;
      return [
        for (final item in list)
          PendingShare.fromJson(item as Map<String, Object?>),
      ];
    } on Object {
      return [];
    }
  }

  @override
  Future<void> save(List<PendingShare> shares) async {
    final file = await _file;
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode([for (final s in shares) s.toJson()]));
    await tmp.rename(file.path);
  }

  @override
  Future<String> keepImage(String path, String id) async {
    final dir = Directory('${(await _directory()).path}/pending_shares');
    await dir.create(recursive: true);
    final dot = path.lastIndexOf('.');
    final ext = dot > path.lastIndexOf('/') ? path.substring(dot) : '';
    return (await File(path).copy('${dir.path}/$id$ext')).path;
  }

  @override
  Future<void> discardImage(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}

/// For tests: nothing touches the disk.
class MemoryPendingShareStore implements PendingShareStore {
  List<PendingShare> saved = [];
  final discarded = <String>[];

  @override
  Future<List<PendingShare>> load() async => List.of(saved);

  @override
  Future<void> save(List<PendingShare> shares) async => saved = List.of(shares);

  @override
  Future<String> keepImage(String path, String id) async => path;

  @override
  Future<void> discardImage(String path) async => discarded.add(path);
}
