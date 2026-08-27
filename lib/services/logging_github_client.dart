import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

/// Envuelve el cliente HTTP usado por el paquete `github` para registrar el
/// código de estado real de cada respuesta con error. El paquete `github`
/// convierte cualquier 401 en la excepción `AccessForbidden`, con el mensaje
/// fijo "Access Forbidden" en vez del motivo real que dio GitHub, así que
/// sin este log no hay forma de confirmarlo (los demás códigos, incluido
/// el 403, sí conservan el mensaje original de la API).
class LoggingGitHubClient extends http.BaseClient {
  LoggingGitHubClient(this._inner);

  final http.Client _inner;

  /// Código de estado HTTP de la última respuesta con error, para poder
  /// mostrarlo en pantalla aunque no haya consola de debug a mano (p.ej. en
  /// el build desplegado en versiona.site).
  int? lastErrorStatusCode;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    if (response.statusCode >= 400) {
      lastErrorStatusCode = response.statusCode;
      final bytes = await response.stream.toBytes();
      developer.log(
        'GitHub API ${response.statusCode} en ${request.method} '
        '${request.url}: ${String.fromCharCodes(bytes)}',
        name: 'github.http',
      );
      return http.StreamedResponse(
        Stream.value(bytes),
        response.statusCode,
        contentLength: bytes.length,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    }
    return response;
  }
}
