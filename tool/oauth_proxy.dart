import 'dart:convert';
import 'dart:io';

const _defaultClientId = 'Ov23liV3MqUyzESsKWT9';

Future<void> main() async {
  final secret = Platform.environment['OAUTH_CLIENT_SECRET'];
  if (secret == null || secret.isEmpty) {
    stderr.writeln('Falta la variable OAUTH_CLIENT_SECRET.');
    exitCode = 64;
    return;
  }

  final clientId = Platform.environment['GITHUB_CLIENT_ID'] ?? _defaultClientId;
  final allowedOrigins =
      (Platform.environment['ALLOWED_ORIGINS'] ??
              'http://localhost:8080,http://127.0.0.1:8080')
          .split(',')
          .map((origin) => origin.trim())
          .where((origin) => origin.isNotEmpty)
          .toSet();
  final port = int.tryParse(Platform.environment['PORT'] ?? '') ?? 8787;
  final host = Platform.environment['HOST'] ?? '127.0.0.1';
  final server = await HttpServer.bind(host, port);
  stdout.writeln('Proxy OAuth de Versiona escuchando en $host:$port');

  await for (final request in server) {
    await _handle(request, clientId, secret, allowedOrigins);
  }
}

Future<void> _handle(
  HttpRequest request,
  String clientId,
  String clientSecret,
  Set<String> allowedOrigins,
) async {
  if (request.method == 'GET' && request.uri.path == '/health') {
    await _json(request.response, HttpStatus.ok, {'status': 'ok'});
    return;
  }

  final origin = request.headers.value('origin');
  if (origin == null || !allowedOrigins.contains(origin)) {
    await _json(request.response, HttpStatus.forbidden, {
      'error': 'Origen no permitido.',
    });
    return;
  }

  request.response.headers
    ..set('Access-Control-Allow-Origin', origin)
    ..set('Vary', 'Origin')
    ..set('Access-Control-Allow-Headers', 'Content-Type')
    ..set('Access-Control-Allow-Methods', 'POST, OPTIONS');

  if (request.method == 'OPTIONS') {
    request.response.statusCode = HttpStatus.noContent;
    await request.response.close();
    return;
  }
  if (request.method != 'POST' || request.uri.path != '/oauth/token') {
    await _json(request.response, HttpStatus.notFound, {
      'error': 'No encontrado.',
    });
    return;
  }

  try {
    final input =
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
    final code = input['code'] as String?;
    final redirectUri = input['redirect_uri'] as String?;
    final verifier = input['code_verifier'] as String?;
    if (code == null || redirectUri == null || verifier == null) {
      await _json(request.response, HttpStatus.badRequest, {
        'error': 'Faltan parámetros OAuth.',
      });
      return;
    }

    final github = HttpClient();
    final githubRequest = await github.postUrl(
      Uri.parse('https://github.com/login/oauth/access_token'),
    );
    githubRequest.headers
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..set(HttpHeaders.contentTypeHeader, 'application/json');
    githubRequest.write(
      jsonEncode({
        'client_id': clientId,
        'client_secret': clientSecret,
        'code': code,
        'redirect_uri': redirectUri,
        'code_verifier': verifier,
      }),
    );
    final githubResponse = await githubRequest.close();
    final responseBody = await utf8.decoder.bind(githubResponse).join();
    github.close();

    request.response.statusCode = githubResponse.statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(responseBody);
    await request.response.close();
  } catch (_) {
    await _json(request.response, HttpStatus.badGateway, {
      'error': 'No se pudo contactar con GitHub.',
    });
  }
}

Future<void> _json(
  HttpResponse response,
  int statusCode,
  Map<String, String> body,
) async {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}
