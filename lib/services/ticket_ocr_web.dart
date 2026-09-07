import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// `Tesseract.createWorker(idioma)`, autoalojado en `web/tesseract/` (ver
/// `web/index.html`): la imagen se procesa entera en el navegador vía
/// WebAssembly, nunca se sube a ningún servidor. Solo el motor y los datos
/// de idioma (varios MB) se piden la primera vez a la CDN oficial de
/// Tesseract.js, no la imagen del ticket.
@JS('Tesseract.createWorker')
external JSPromise<_TesseractWorker> _createWorker(JSString langs);

extension type _TesseractWorker._(JSObject _) implements JSObject {
  external JSPromise<JSObject> recognize(web.Blob image);
}

// El worker carga el motor WASM y los datos de idioma la primera vez que se
// crea (varios MB): usar Tesseract.recognize() suelto para cada ticket
// repetía esa carga en cada subida, lo que la hacía notablemente lenta. Un
// único worker reutilizado entre llamadas paga ese coste solo una vez por
// sesión de navegador.
Future<_TesseractWorker>? _workerFuture;

Future<_TesseractWorker> _worker() {
  final existing = _workerFuture;
  if (existing != null) return existing;

  final created = _createWorker('spa'.toJS).toDart;
  _workerFuture = created;
  // Si la creación falla (p. ej. sin red al cargar los datos de idioma por
  // primera vez), no la dejamos guardada en caché: así la próxima subida
  // puede reintentar en vez de fallar siempre hasta recargar la página.
  unawaited(
    created.then(
      (_) {},
      onError: (_) {
        if (identical(_workerFuture, created)) _workerFuture = null;
      },
    ),
  );
  return created;
}

Future<String?> extractRawText(
  Uint8List bytes, {
  required String mimeType,
}) async {
  final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(type: mimeType));
  final worker = await _worker();
  final result = await worker.recognize(blob).toDart;
  final data = result.getProperty<JSObject>('data'.toJS);
  final text = data.getProperty<JSString>('text'.toJS).toDart.trim();
  return text.isEmpty ? null : text;
}
