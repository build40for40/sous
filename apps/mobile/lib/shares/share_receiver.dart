import 'dart:async';

import 'package:receive_sharing_intent/receive_sharing_intent.dart';

/// Something another app shared into Sous through the system share sheet.
sealed class IncomingShare {
  const IncomingShare();
}

/// A link, or text with a link in it, e.g. Instagram's "Share → Sous".
class IncomingText extends IncomingShare {
  const IncomingText(this.text);

  final String text;

  @override
  bool operator ==(Object other) => other is IncomingText && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// A screenshot or photo, as a file the platform copied for us.
class IncomingImage extends IncomingShare {
  const IncomingImage(this.path);

  final String path;

  @override
  bool operator ==(Object other) =>
      other is IncomingImage && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// Where shares from other apps come from.
abstract interface class ShareReceiver {
  /// Everything shared into Sous: what opened the app, then anything shared
  /// while it runs.
  Stream<IncomingShare> shares();
}

/// The system share sheet on Android (`ACTION_SEND`) and the Share Extension
/// on iOS, through `receive_sharing_intent`.
class SystemShareReceiver implements ShareReceiver {
  SystemShareReceiver({ReceiveSharingIntent? plugin})
    : _plugin = plugin ?? ReceiveSharingIntent.instance;

  final ReceiveSharingIntent _plugin;

  @override
  Stream<IncomingShare> shares() async* {
    final initial = await _plugin.getInitialMedia();
    yield* Stream.fromIterable(toIncoming(initial));
    if (initial.isNotEmpty) unawaited(_plugin.reset());
    await for (final files in _plugin.getMediaStream()) {
      yield* Stream.fromIterable(toIncoming(files));
    }
  }

  /// Links and text go as text; images as files. Video and other files aren't
  /// something Sous can read.
  static List<IncomingShare> toIncoming(List<SharedMediaFile> files) => [
    for (final file in files)
      if ((file.type == SharedMediaType.text ||
              file.type == SharedMediaType.url) &&
          file.path.trim().isNotEmpty)
        IncomingText(file.path.trim())
      else if (file.type == SharedMediaType.image ||
          (file.type == SharedMediaType.file &&
              (file.mimeType?.startsWith('image/') ?? false)))
        IncomingImage(file.path),
  ];
}
