import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads the app's font so goldens show real text, and lets goldens differ by
/// a sliver, since text renders a little differently on macOS and Linux.
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

  static const _tolerance = .01;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= _tolerance) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}
