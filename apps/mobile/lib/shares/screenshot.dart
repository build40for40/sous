import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// The extraction API's limit for a screenshot, decoded (`MAX_IMAGE_BYTES` in
/// `workers/extract/src/index.ts`).
const maxScreenshotBytes = 1900000;

/// The longest side we send. A recipe screenshot stays readable well below a
/// phone's full resolution.
const maxScreenshotSide = 2048;

/// A screenshot ready to send.
class PreparedScreenshot {
  const PreparedScreenshot(this.bytes, this.mediaType);

  final Uint8List bytes;

  /// `image/jpeg`, `image/png`, `image/webp` or `image/gif`.
  final String mediaType;
}

/// Thrown when a file isn't an image we can read.
class ScreenshotException implements Exception {
  const ScreenshotException(this.message);

  final String message;

  @override
  String toString() => 'ScreenshotException($message)';
}

/// Makes [bytes] fit the API: a supported image under [maxScreenshotBytes].
/// A small JPEG or PNG goes as it is; anything else is decoded, scaled so its
/// longest side is at most [maxScreenshotSide], and re-encoded as JPEG,
/// stepping the quality down until it fits. Runs off the UI isolate.
Future<PreparedScreenshot> prepareScreenshot(Uint8List bytes) =>
    Isolate.run(() => prepareScreenshotSync(bytes));

PreparedScreenshot prepareScreenshotSync(
  Uint8List bytes, {
  int maxBytes = maxScreenshotBytes,
  int maxSide = maxScreenshotSide,
}) {
  final type = _sniff(bytes);
  if (type != null && bytes.length <= maxBytes) {
    return PreparedScreenshot(bytes, type);
  }
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const ScreenshotException("That file isn't an image Sous can read.");
  }
  var image = decoded;
  var side = maxSide;
  while (true) {
    if (image.width > side || image.height > side) {
      image = image.width >= image.height
          ? img.copyResize(decoded, width: side)
          : img.copyResize(decoded, height: side);
    }
    for (final quality in const [85, 70, 55]) {
      final jpeg = img.encodeJpg(image, quality: quality);
      if (jpeg.length <= maxBytes) {
        return PreparedScreenshot(jpeg, 'image/jpeg');
      }
    }
    if (side <= 512) {
      throw const ScreenshotException('That image is too big to send.');
    }
    side = side * 3 ~/ 4;
  }
}

/// The type from the file's first bytes, for the formats the API takes.
String? _sniff(Uint8List b) {
  bool starts(List<int> sig) =>
      b.length >= sig.length &&
      Iterable.generate(sig.length).every((i) => b[i] == sig[i]);
  if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (starts(const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
  if (starts(const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (b.length >= 12 &&
      starts(const [0x52, 0x49, 0x46, 0x46]) &&
      b[8] == 0x57 &&
      b[9] == 0x45 &&
      b[10] == 0x42 &&
      b[11] == 0x50) {
    return 'image/webp';
  }
  return null;
}
