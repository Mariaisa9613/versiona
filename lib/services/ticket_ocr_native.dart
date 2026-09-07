import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

// Reutilizado entre llamadas: crear un TextRecognizer nuevo cada vez tiene
// coste (carga del modelo), así que uno solo por sesión de la app basta.
final _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

/// Reconocimiento de texto on-device en Android/iOS vía ML Kit. El plugin
/// solo sabe leer ficheros reales, así que los bytes se vuelcan primero a
/// un fichero temporal (borrado al terminar).
Future<String?> extractRawText(
  Uint8List bytes, {
  required String mimeType,
}) async {
  final tempDir = await getTemporaryDirectory();
  final extension = mimeType == 'image/png' ? 'png' : 'jpg';
  final tempFile = File(
    '${tempDir.path}/versiona_ocr_${DateTime.now().microsecondsSinceEpoch}.$extension',
  );
  await tempFile.writeAsBytes(bytes, flush: true);

  try {
    final result = await _recognizer.processImage(
      InputImage.fromFilePath(tempFile.path),
    );
    final text = result.text.trim();
    return text.isEmpty ? null : text;
  } finally {
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
  }
}
