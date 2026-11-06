import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

var _bound = false;

/// Loads the sherpa-onnx native library in this isolate, once.
void bindSherpa() {
  if (_bound) return;
  sherpa.initBindings();
  _bound = true;
}
