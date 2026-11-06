import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:sous/shares/screenshot.dart';

void main() {
  Uint8List png(int width, int height) {
    final image = img.Image(width: width, height: height);
    // Noise, so it doesn't compress to nothing.
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        image.setPixelRgb(
          x,
          y,
          (x * 7 + y * 13) % 256,
          (x * y) % 256,
          (x ^ y) % 256,
        );
      }
    }
    return img.encodePng(image);
  }

  test('sends a small PNG as it is', () {
    final bytes = png(40, 30);
    final out = prepareScreenshotSync(bytes);
    expect(out.mediaType, 'image/png');
    expect(out.bytes, same(bytes));
  });

  test('scales and re-encodes an image over the limit until it fits', () {
    final bytes = png(900, 1600);
    expect(bytes.length, greaterThan(200000));
    final out = prepareScreenshotSync(bytes, maxBytes: 200000, maxSide: 1200);
    expect(out.mediaType, 'image/jpeg');
    expect(out.bytes.length, lessThanOrEqualTo(200000));
    final decoded = img.decodeImage(out.bytes)!;
    expect(decoded.height, lessThanOrEqualTo(1200));
    expect(decoded.width / decoded.height, closeTo(900 / 1600, 0.01));
  });

  test('re-encodes a format the API doesn\'t take', () {
    final bmp = img.encodeBmp(img.Image(width: 20, height: 20));
    expect(prepareScreenshotSync(bmp).mediaType, 'image/jpeg');
  });

  test('refuses something that isn\'t an image', () {
    expect(
      () => prepareScreenshotSync(Uint8List.fromList(List.filled(100, 7))),
      throwsA(isA<ScreenshotException>()),
    );
  });
}
