import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:versiona/services/github_device_auth_service.dart';
import 'package:versiona/services/secure_storage_service.dart';
import 'package:versiona/state/auth_controller.dart';

/// Llavero en memoria, para poder comprobar si el token sobrevive a un
/// fallo o no.
class _FakeStorage extends SecureStorageService {
  _FakeStorage([this.token]);

  String? token;
  int clearCount = 0;

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> saveToken(String value) async => token = value;

  @override
  Future<void> clearToken() async {
    clearCount++;
    token = null;
  }
}

/// Un llavero que no deja guardar nada, como el de iOS con el dispositivo
/// bloqueado o el de macOS sin permisos.
class _BrokenKeychain extends _FakeStorage {
  @override
  Future<void> saveToken(String value) async => throw PlatformException(
    code: 'keychain',
    message: 'errSecInteractionNotAllowed',
  );
}

/// GitHub para una cuenta que entra por primera vez: todavía sin ningún
/// espacio de Versiona, y que acepta crear uno.
http.Client _githubForFirstWorkspace() {
  var workBranchExists = false;
  http.Response json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );
  const tip = {'sha': 'abc'};

  return MockClient((request) async {
    switch ((request.method, request.url.path)) {
      case ('GET', '/user'):
        return json({'login': 'maria', 'id': 1});
      case ('GET', '/user/repos'):
        return json(const []);
      case ('POST', '/user/repos'):
        return json({
          'name': 'espacio',
          'full_name': 'maria/espacio',
          'default_branch': 'main',
          'private': true,
        }, 201);
      case ('GET', '/repos/maria/espacio/branches/main'):
        return json({'name': 'main', 'commit': tip});
      case ('GET', '/repos/maria/espacio/branches/en-revision'):
        return json(
          workBranchExists ? {'name': 'en-revision', 'commit': tip} : const {},
        );
      case ('POST', '/repos/maria/espacio/git/refs'):
        workBranchExists = true;
        return json({'ref': 'refs/heads/en-revision', 'object': tip}, 201);
    }
    return json({'message': 'Not Found'}, 404);
  });
}

/// Responde a la API de GitHub con el código que se le diga. Solo hace falta
/// cubrir `GET /user`, que es la primera llamada de `_completeSignIn`.
http.Client _githubReplying(int statusCode, {String body = '{}'}) {
  return MockClient((request) async {
    return http.Response(
      body,
      statusCode,
      headers: const {'content-type': 'application/json'},
    );
  });
}

const _validUser = '{"login":"maria","id":1}';

DeviceCodeRequest _request() => DeviceCodeRequest(
  deviceCode: 'device-code',
  userCode: 'ABCD-1234',
  verificationUri: 'https://github.com/login/device',
  expiresIn: 900,
  interval: 5,
);

/// Device flow guionizado: cada entrada de [_steps] es o un
/// [DevicePollResult] a devolver, o una excepción a lanzar. La última se
/// repite indefinidamente.
class _ScriptedDeviceAuth extends GitHubDeviceAuthService {
  _ScriptedDeviceAuth(this._steps);

  final List<Object> _steps;
  int calls = 0;

  /// Si no es `null`, `checkAccessToken` se queda esperando a que se
  /// complete, para poder probar qué pasa con una petición en vuelo.
  Completer<DevicePollResult>? gate;

  @override
  Future<DeviceCodeRequest> requestDeviceCode() async => _request();

  @override
  Future<DevicePollResult> checkAccessToken(DeviceCodeRequest request) async {
    calls++;
    final blocker = gate;
    if (blocker != null) return blocker.future;

    final step = _steps[(calls - 1).clamp(0, _steps.length - 1)];
    if (step is Exception) throw step;
    return step as DevicePollResult;
  }
}

void main() {
  group('Un fallo de GitHub al preparar el espacio', () {
    test('un 401 borra el token: GitHub ha rechazado la sesión', () async {
      final storage = _FakeStorage('token-caducado');
      final auth = AuthController(
        storage: storage,
        httpClient: _githubReplying(401, body: '{"message":"Bad credentials"}'),
      );

      await auth.bootstrap();

      expect(storage.token, isNull);
      expect(storage.clearCount, 1);
      expect(auth.status, AuthStatus.signedOut);
      expect(auth.canRetrySavedSession, isFalse);
      expect(auth.errorMessage, contains('caducado'));
    });

    test('un 500 conserva el token y ofrece reintentar', () async {
      final storage = _FakeStorage('token-bueno');
      final auth = AuthController(
        storage: storage,
        httpClient: _githubReplying(500, body: '{"message":"Server Error"}'),
      );

      await auth.bootstrap();

      // Lo que ha fallado es GitHub, no el token: borrarlo obligaba a
      // repetir el device flow entero por una incidencia pasajera.
      expect(storage.token, 'token-bueno');
      expect(storage.clearCount, 0);
      expect(auth.status, AuthStatus.signedOut);
      expect(auth.canRetrySavedSession, isTrue);
    });

    test('un 403 por límite de peticiones tampoco borra el token', () async {
      final storage = _FakeStorage('token-bueno');
      final auth = AuthController(
        storage: storage,
        httpClient: _githubReplying(
          403,
          body: '{"message":"API rate limit exceeded"}',
        ),
      );

      await auth.bootstrap();

      expect(storage.token, 'token-bueno');
      expect(auth.canRetrySavedSession, isTrue);
    });

    test('sin conexión conserva el token y ofrece reintentar', () async {
      final storage = _FakeStorage('token-bueno');
      final auth = AuthController(
        storage: storage,
        httpClient: MockClient((_) async {
          throw http.ClientException('Failed host lookup');
        }),
      );

      await auth.bootstrap();

      expect(storage.token, 'token-bueno');
      expect(storage.clearCount, 0);
      expect(auth.canRetrySavedSession, isTrue);
    });

    test('reintentar reutiliza la sesión guardada, sin volver a '
        'conectar la cuenta', () async {
      final storage = _FakeStorage('token-bueno');
      var failNext = true;
      final auth = AuthController(
        storage: storage,
        httpClient: MockClient((_) async {
          if (failNext) {
            failNext = false;
            return http.Response('{"message":"Server Error"}', 500);
          }
          return http.Response(
            _validUser,
            200,
            headers: const {'content-type': 'application/json'},
          );
        }),
      );

      await auth.bootstrap();
      expect(auth.canRetrySavedSession, isTrue);

      await auth.retrySavedSession();

      // GitHub vuelve a responder, así que el reintento pasa de la
      // identificación del usuario sin pedir un código nuevo.
      expect(auth.status, isNot(AuthStatus.awaitingUserCode));
      expect(storage.token, 'token-bueno');
    });

    test('reintentar sin sesión guardada lo dice, en vez de fallar en '
        'silencio', () async {
      final storage = _FakeStorage();
      final auth = AuthController(
        storage: storage,
        httpClient: _githubReplying(500),
      );

      await auth.retrySavedSession();

      expect(auth.status, AuthStatus.signedOut);
      expect(auth.canRetrySavedSession, isFalse);
      expect(auth.errorMessage, contains('sesión guardada'));
    });
  });

  group('Sondeo del código de dispositivo', () {
    testWidgets('un fallo de red no congela la espera: se reintenta', (
      tester,
    ) async {
      final deviceAuth = _ScriptedDeviceAuth([
        http.ClientException('Failed host lookup'),
        const FormatException('Unexpected character'),
        DevicePollResult.pending(),
      ]);
      final auth = AuthController(
        storage: _FakeStorage(),
        deviceAuth: deviceAuth,
      );
      addTearDown(auth.dispose);

      // Sin await: startSignIn copia el código al portapapeles, y esa
      // respuesta del canal de plataforma no llega hasta el primer pump.
      unawaited(auth.startSignIn());
      await tester.pump();
      expect(auth.status, AuthStatus.awaitingUserCode);

      // Tres ciclos: los dos primeros revientan. Antes, la excepción
      // escapaba del callback del Timer, el sondeo no se reprogramaba y la
      // pantalla se quedaba esperando el código para siempre.
      for (var cycle = 0; cycle < 3; cycle++) {
        await tester.pump(const Duration(seconds: 5));
      }

      expect(deviceAuth.calls, 3);
      expect(auth.status, AuthStatus.awaitingUserCode);
      expect(auth.errorMessage, isNull);

      // El sondeo sigue vivo justamente porque el arreglo funciona: hay que
      // pararlo para no dejar un Timer pendiente al acabar el test.
      auth.cancelSignIn();
    });

    testWidgets('volver a primer plano no duplica el sondeo en vuelo', (
      tester,
    ) async {
      final deviceAuth = _ScriptedDeviceAuth([DevicePollResult.pending()]);
      final auth = AuthController(
        storage: _FakeStorage(),
        deviceAuth: deviceAuth,
      );
      addTearDown(auth.dispose);

      unawaited(auth.startSignIn());
      await tester.pump();

      // Una comprobación arranca y se queda en vuelo.
      final gate = Completer<DevicePollResult>();
      deviceAuth.gate = gate;
      await tester.pump(const Duration(seconds: 5));
      expect(deviceAuth.calls, 1);

      // El usuario vuelve del navegador mientras esa sigue sin contestar.
      auth.checkNowIfWaiting();
      await tester.pump();
      expect(
        deviceAuth.calls,
        1,
        reason:
            'la petición en vuelo debe terminar antes de lanzar otra, o se '
            'sondea al doble de ritmo y GitHub responde "slow_down"',
      );

      // Al contestar, el ciclo sigue vivo con su ritmo normal.
      deviceAuth.gate = null;
      gate.complete(DevicePollResult.pending());
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(deviceAuth.calls, 2);

      auth.cancelSignIn();
    });
  });

  group('El llavero no deja guardar la sesión', () {
    testWidgets('tras crear el espacio se entra igual, avisando', (
      tester,
    ) async {
      final storage = _BrokenKeychain();
      final auth = AuthController(
        storage: storage,
        deviceAuth: _ScriptedDeviceAuth([
          DevicePollResult.success('token-nuevo'),
        ]),
        httpClient: _githubForFirstWorkspace(),
      );
      addTearDown(auth.dispose);

      unawaited(auth.startSignIn());
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      for (var i = 0; i < 20; i++) {
        if (auth.status == AuthStatus.choosingWorkspaceName) break;
        await tester.pump();
      }
      expect(auth.status, AuthStatus.choosingWorkspaceName);

      await auth.confirmWorkspaceName('espacio');

      // Antes el fallo del llavero devolvía a elegir nombre, con el
      // repositorio ya creado: reintentar chocaba con "name already exists"
      // y no había forma de salir de ahí.
      expect(auth.status, AuthStatus.signedIn);
      expect(auth.driveService?.repoFullName, 'maria/espacio');
      expect(storage.token, isNull);
      expect(auth.takeSignInNotice(), contains('no ha podido guardar'));
      expect(auth.takeSignInNotice(), isNull, reason: 'se avisa una sola vez');
    });
  });

  group('Respuestas inesperadas del endpoint de token', () {
    test('un 502 con HTML se reporta como tal, no como FormatException', () {
      final service = GitHubDeviceAuthService(
        client: MockClient(
          (_) async => http.Response('<html>502 Bad Gateway</html>', 502),
        ),
      );

      expect(
        () => service.checkAccessToken(_request()),
        throwsA(
          isA<DeviceAuthException>().having(
            (e) => e.message,
            'message',
            contains('502'),
          ),
        ),
      );
    });

    test('una respuesta sin error pero sin token no se da por buena', () {
      final service = GitHubDeviceAuthService(
        client: MockClient(
          (_) async => http.Response(
            '{}',
            200,
            headers: const {'content-type': 'application/json'},
          ),
        ),
      );

      expect(
        () => service.checkAccessToken(_request()),
        throwsA(isA<DeviceAuthException>()),
      );
    });
  });
}
