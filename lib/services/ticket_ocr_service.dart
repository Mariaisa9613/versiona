import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

import 'ticket_ocr_platform.dart' as platform;

/// Resultado de reconocer el texto de un ticket/factura: el texto completo
/// y, si se ha podido identificar, el número de factura/ticket.
class TicketOcrResult {
  const TicketOcrResult({required this.rawText, required this.invoiceNumber});

  final String rawText;
  final String? invoiceNumber;
}

/// Reconoce el texto de la foto o imagen de un ticket, on-device: en
/// Android/iOS vía ML Kit, en web vía Tesseract.js (autoalojado, ver
/// `web/tesseract/`). La imagen nunca sale del dispositivo/navegador.
///
/// Además intenta identificar un número de factura/ticket dentro del texto
/// reconocido, para poder renombrar el fichero y ampliar el mensaje de
/// commit con algo más útil que una marca de tiempo genérica.
class TicketOcrService {
  static final _invoiceNumberPattern = RegExp(
    r'(?:factura|fra\.?|albar[aá]n|recibo|ticket)\s*'
    r'(?:simplificada)?\s*'
    r'(?:n[ºo°]?\.?|num(?:ero)?\.?|#)?\s*[:\-]?\s*'
    r'([A-Z0-9][A-Z0-9\-/]{2,19})',
    caseSensitive: false,
  );

  /// Analiza [bytes] (una imagen JPEG/PNG/WEBP). Devuelve `null` si no se ha
  /// reconocido ningún texto o si el reconocimiento falla: es una mejora
  /// sobre el nombre/mensaje por defecto, no algo crítico para poder subir
  /// el fichero.
  Future<TicketOcrResult?> analyze(
    Uint8List bytes, {
    String mimeType = 'image/jpeg',
  }) async {
    String? rawText;
    try {
      rawText = await platform.extractRawText(bytes, mimeType: mimeType);
    } catch (e) {
      // El OCR es una mejora del nombre y del mensaje, no algo crítico: si
      // falla, el fichero se sube igual. Pero se deja constancia, porque un
      // fallo silencioso aquí se manifiesta como "el mensaje no trae nada
      // del OCR" y cuesta relacionarlo con su causa.
      debugPrint('[Versiona] El reconocimiento de texto ha fallado: $e');
      rawText = null;
    }
    if (rawText == null || rawText.trim().isEmpty) {
      debugPrint('[Versiona] El OCR no ha reconocido texto en esta imagen.');
      return null;
    }

    return TicketOcrResult(
      rawText: rawText,
      invoiceNumber: _detectInvoiceNumber(rawText),
    );
  }

  String? _detectInvoiceNumber(String text) {
    final match = _invoiceNumberPattern.firstMatch(text);
    final raw = match?.group(1)?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw.replaceAll(RegExp(r'[\-/]+$'), '').toUpperCase();
  }

  /// Si se ha detectado [invoiceNumber], propone un nombre de fichero que lo
  /// incluya (conservando la extensión de [defaultName]); si no, devuelve
  /// [defaultName] tal cual.
  String applyInvoiceNumberToName(String defaultName, String? invoiceNumber) {
    if (invoiceNumber == null) return defaultName;

    final dotIndex = defaultName.lastIndexOf('.');
    final extension = dotIndex == -1 ? '' : defaultName.substring(dotIndex);
    final sanitized = invoiceNumber.replaceAll(RegExp(r'[^A-Za-z0-9\-]'), '_');
    final stamp = DateFormat('HHmmss').format(DateTime.now());
    return 'FACTURA_${sanitized}_$stamp$extension';
  }
}
