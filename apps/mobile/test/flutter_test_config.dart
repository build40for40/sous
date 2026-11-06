import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads the app's fonts so goldens show real text, and lets goldens differ
/// in faint anti-aliasing, since text renders a little differently on macOS
/// and Linux.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final inter = FontLoader('Inter');
  for (final weight in ['Light', 'Regular', 'Medium', 'SemiBold', 'Bold']) {
    inter.addFont(
      File('assets/fonts/Inter-$weight.ttf')
          .readAsBytes()
          .then(ByteData.sublistView),
    );
  }
  await inter.load();
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
  }
  final comparator = goldenFileComparator;
  if (comparator is LocalFileComparator) {
    goldenFileComparator = _NearEnough(
      comparator.basedir.resolve('x_test.dart'),
    );
  }
  await testMain();
}

class _NearEnough extends LocalFileComparator {
  _NearEnough(super.testFile);

  /// A pixel only counts as changed when a channel moves by more than this,
  /// so anti-aliasing at the edges of glyphs doesn't.
  static const _channelSlack = 96;
  static const _changedShare = .01;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final goldenBytes = await getGoldenBytes(golden);
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      goldenBytes,
    );
    if (result.passed ||
        await _changed(imageBytes, Uint8List.fromList(goldenBytes)) <=
            _changedShare) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }

  static Future<double> _changed(Uint8List a, Uint8List b) async {
    final pa = await _pixels(a);
    final pb = await _pixels(b);
    if (pa.lengthInBytes != pb.lengthInBytes) return 1;
    var changed = 0;
    for (var i = 0; i < pa.lengthInBytes; i += 4) {
      for (var c = 0; c < 4; c++) {
        if ((pa.getUint8(i + c) - pb.getUint8(i + c)).abs() > _channelSlack) {
          changed++;
          break;
        }
      }
    }
    return changed / (pa.lengthInBytes / 4);
  }

  static Future<ByteData> _pixels(Uint8List png) async {
    final codec = await ui.instantiateImageCodec(png);
    final image = (await codec.getNextFrame()).image;
    final data = await image.toByteData();
    image.dispose();
    codec.dispose();
    return data!;
  }
}
