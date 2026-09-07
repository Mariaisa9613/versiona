// Reconocimiento de texto on-device, con una implementación por
// plataforma: ML Kit (Android/iOS) o Tesseract.js autoalojado (web). Ambas
// exponen la misma firma: Future<String?> extractRawText(bytes, {mimeType}).
export 'ticket_ocr_native.dart'
    if (dart.library.js_interop) 'ticket_ocr_web.dart';
