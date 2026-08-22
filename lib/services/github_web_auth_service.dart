import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../config/github_config.dart';
import 'browser_navigation.dart';

class WebAuthException implements Exception {
  WebAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// OAuth web con Authorization Code + PKCE.
///
/// El navegador realiza la redirección, pero el intercambio final pasa por
/// el proxy configurado: GitHub exige un client secret y no admite la petición
/// CORS directa desde Flutter Web.
class GitHubWebAuthService {
  GitHubWebAuthService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  static const _stateKey = 'versiona_oauth_state';
  static const _verifierKey = 'versiona_oauth_verifier';

  bool get hasCallback =>
      Uri.base.queryParameters.containsKey('code') ||
      Uri.base.queryParameters.containsKey('error');

  Future<void> startAuthorization() async {
    if (!GitHubConfig.isWebOAuthConfigured) {
      throw WebAuthException(
        'Falta configurar OAUTH_PROXY_URL para conectar GitHub desde Chrome.',
      );
    }

    final state = _randomUrlSafeValue(32);
    final verifier = _randomUrlSafeValue(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');

    writeSessionValue(_stateKey, state);
    writeSessionValue(_verifierKey, verifier);

    final authorizationUrl = Uri.https('github.com', '/login/oauth/authorize', {
      'client_id': GitHubConfig.githubClientId,
      'redirect_uri': callbackUrl,
      'scope': GitHubConfig.scopes,
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });
    navigateBrowser(authorizationUrl.toString());
  }

  Future<String?> completeCallback() async {
    if (!hasCallback) return null;

    final parameters = Uri.base.queryParameters;
    final error = parameters['error'];
    if (error != null) {
      _clearAttempt();
      _cleanCallbackUrl();
      throw WebAuthException(
        parameters['error_description'] ?? 'GitHub ha cancelado el acceso.',
      );
    }

    final expectedState = readSessionValue(_stateKey);
    final verifier = readSessionValue(_verifierKey);
    final receivedState = parameters['state'];
    final code = parameters['code'];
    if (expectedState == null ||
        verifier == null ||
        receivedState != expectedState ||
        code == null) {
      _clearAttempt();
      _cleanCallbackUrl();
      throw WebAuthException(
        'La respuesta de GitHub no es válida o la sesión de acceso ha caducado.',
      );
    }

    try {
      final response = await _client.post(
        Uri.parse(GitHubConfig.webOAuthProxyUrl),
        headers: const {'Content-Type': 'application/json'},
        body: jsonEncode({
          'code': code,
          'redirect_uri': callbackUrl,
          'code_verifier': verifier,
        }),
      );
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final token = body['access_token'] as String?;
      if (response.statusCode != 200 || token == null) {
        throw WebAuthException(
          body['error_description'] as String? ??
              body['error'] as String? ??
              'No se pudo completar el acceso con GitHub.',
        );
      }
      return token;
    } on FormatException {
      throw WebAuthException(
        'El servidor de autenticación devolvió una respuesta inválida.',
      );
    } on http.ClientException {
      throw WebAuthException(
        'No se pudo contactar con el servidor de autenticación web.',
      );
    } finally {
      _clearAttempt();
      _cleanCallbackUrl();
    }
  }

  String get callbackUrl {
    final base = Uri.base;
    return Uri(
      scheme: base.scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: base.path,
    ).toString();
  }

  String _randomUrlSafeValue(int byteCount) {
    final random = Random.secure();
    final bytes = List<int>.generate(byteCount, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  void _clearAttempt() {
    removeSessionValue(_stateKey);
    removeSessionValue(_verifierKey);
  }

  void _cleanCallbackUrl() => replaceBrowserUrl(callbackUrl);
}
