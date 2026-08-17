import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/github_config.dart';

/// Datos del código que el usuario debe introducir en github.com/login/device.
class DeviceCodeRequest {
  DeviceCodeRequest({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int expiresIn;
  final int interval;
}

/// Excepción lanzada cuando el usuario deniega el acceso o el código expira.
class DeviceAuthException implements Exception {
  DeviceAuthException(this.message);
  final String message;

  @override
  String toString() => message;
}

enum DevicePollStatus { pending, success, expired, denied, otherError }

/// Resultado de una única comprobación del endpoint de token.
class DevicePollResult {
  DevicePollResult._(this.status, {this.token, this.errorMessage, this.retryAfterSeconds});

  factory DevicePollResult.success(String token) =>
      DevicePollResult._(DevicePollStatus.success, token: token);
  factory DevicePollResult.pending({int? retryAfterSeconds}) =>
      DevicePollResult._(
        DevicePollStatus.pending,
        retryAfterSeconds: retryAfterSeconds,
      );
  factory DevicePollResult.expired() =>
      DevicePollResult._(DevicePollStatus.expired);
  factory DevicePollResult.denied() =>
      DevicePollResult._(DevicePollStatus.denied);
  factory DevicePollResult.otherError(String message) =>
      DevicePollResult._(DevicePollStatus.otherError, errorMessage: message);

  final DevicePollStatus status;
  final String? token;
  final String? errorMessage;

  /// Solo presente cuando GitHub pide reducir la frecuencia de sondeo
  /// ("slow_down"): nuevo intervalo mínimo en segundos.
  final int? retryAfterSeconds;
}

/// Implementa el "OAuth Device Flow" de GitHub: no requiere client secret ni
/// backend propio, por lo que es apto para una app 100% cliente.
///
/// Referencia: https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow
class GitHubDeviceAuthService {
  GitHubDeviceAuthService({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  static const _deviceCodeUrl = 'https://github.com/login/device/code';
  static const _tokenUrl = 'https://github.com/login/oauth/access_token';

  Future<DeviceCodeRequest> requestDeviceCode() async {
    final response = await _client.post(
      Uri.parse(_deviceCodeUrl),
      headers: const {'Accept': 'application/json'},
      body: {
        'client_id': GitHubConfig.githubClientId,
        'scope': GitHubConfig.scopes,
      },
    );

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode != 200 || body.containsKey('error')) {
      throw DeviceAuthException(
        body['error_description'] as String? ??
            'No se pudo iniciar el inicio de sesión con GitHub.',
      );
    }

    return DeviceCodeRequest(
      deviceCode: body['device_code'] as String,
      userCode: body['user_code'] as String,
      verificationUri: body['verification_uri'] as String,
      expiresIn: body['expires_in'] as int,
      interval: body['interval'] as int,
    );
  }

  /// Comprueba una única vez si el usuario ya ha autorizado el acceso.
  ///
  /// Es responsabilidad de quien la llama decidir cuándo repetirla (p.ej.
  /// cada [DeviceCodeRequest.interval] segundos, o al instante cuando la
  /// app vuelve a primer plano tras abrir el navegador).
  Future<DevicePollResult> checkAccessToken(DeviceCodeRequest request) async {
    final response = await _client.post(
      Uri.parse(_tokenUrl),
      headers: const {'Accept': 'application/json'},
      body: {
        'client_id': GitHubConfig.githubClientId,
        'device_code': request.deviceCode,
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
      },
    );

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final error = body['error'] as String?;

    if (error == null) {
      return DevicePollResult.success(body['access_token'] as String);
    }

    switch (error) {
      case 'authorization_pending':
        return DevicePollResult.pending();
      case 'slow_down':
        return DevicePollResult.pending(
          retryAfterSeconds: body['interval'] as int?,
        );
      case 'expired_token':
        return DevicePollResult.expired();
      case 'access_denied':
        return DevicePollResult.denied();
      default:
        return DevicePollResult.otherError(
          body['error_description'] as String? ??
              'No se pudo completar el inicio de sesión.',
        );
    }
  }
}
