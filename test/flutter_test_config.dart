import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Lo carga `flutter test` antes de cada fichero de test.
///
/// Las imágenes de test/golden se generaron en macOS, y cada sistema pinta
/// el texto a su manera: en Linux (el CI) salían entre un 0,7 % y un 2,3 %
/// de píxeles distintos sin que la pantalla hubiera cambiado. Fuera de
/// macOS se salta solo la comparación de píxeles; el resto de cada test
/// (qué textos y botones hay) se sigue comprobando en todas partes.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (!Platform.isMacOS) goldenFileComparator = _GoldensOnlyOnMacOS();
  await testMain();
}

class _GoldensOnlyOnMacOS extends GoldenFileComparator {
  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async => true;

  /// Tampoco se regeneran: con --update-goldens desde otro sistema se
  /// sustituirían las de macOS por unas que allí no coinciden.
  @override
  Future<void> update(Uri golden, Uint8List imageBytes) async {}
}
