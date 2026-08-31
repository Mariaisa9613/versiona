import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Longitud máxima del texto reconocido que se añade al mensaje de commit,
/// para no generar commits con cuerpos kilométricos.
const _maxExtractedLength = 400;

/// Extrae el texto de un ticket fotografiado usando reconocimiento de texto
/// on-device (ML Kit): la imagen nunca sale del teléfono.
///
/// Solo funciona en Android e iOS; ML Kit no tiene implementación web, así
/// que ahí [extractText] siempre devuelve `null` y el ticket se sube sin
/// ampliar el mensaje de commit.
class TicketOcrService {
  Future<String?> extractText(String imagePath) async {
    if (kIsWeb) return null;

    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(
        InputImage.fromFilePath(imagePath),
      );
      final text = result.text.trim();
      if (text.isEmpty) return null;
      return text.length > _maxExtractedLength
          ? '${text.substring(0, _maxExtractedLength)}…'
          : text;
    } catch (_) {
      // El OCR es una mejora del mensaje de commit, no algo crítico: si
      // falla, el ticket se sube igualmente con el mensaje por defecto.
      return null;
    } finally {
      await recognizer.close();
    }
  }
}
