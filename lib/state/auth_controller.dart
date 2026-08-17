import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:github/github.dart';

import '../config/github_config.dart';
import '../services/drive_service.dart';
import '../services/github_device_auth_service.dart';
import '../services/secure_storage_service.dart';
import '../utils/platform_info.dart';

enum AuthStatus {
  /// Comprobando si ya hay una sesión guardada en el dispositivo.
  checking,
  signedOut,

  /// Se ha pedido un código y se está esperando a que el usuario lo
  /// introduzca en github.com/login/device.
  awaitingUserCode,

  /// Token obtenido; preparando el repositorio privado del usuario.
  preparingWorkspace,
  signedIn,
}

/// Controla el ciclo de vida completo de la sesión con GitHub: Device Flow,
/// persistencia del token y preparación del "workspace" (repo privado).
class AuthController extends ChangeNotifier {
  AuthController({
    SecureStorageService? storage,
    GitHubDeviceAuthService? deviceAuth,
  })  : _storage = storage ?? SecureStorageService(),
        _deviceAuth = deviceAuth ?? GitHubDeviceAuthService();

  final SecureStorageService _storage;
  final GitHubDeviceAuthService _deviceAuth;

  Timer? _pollTimer;
  DeviceCodeRequest? _activeRequest;
  DateTime? _pollDeadline;
  int _pollIntervalSeconds = 5;

  AuthStatus status = AuthStatus.checking;
  DeviceCodeRequest? deviceCodeRequest;
  String? errorMessage;
  CurrentUser? currentUser;
  DriveService? driveService;

  /// En modo demo todo el mundo entra con el mismo token compartido, sin
  /// pantalla de login. Ver [GitHubConfig.demoPersonalAccessToken].
  bool get isDemoMode => GitHubConfig.isDemoMode;

  /// Nombre del repositorio de GitHub donde se están guardando los
  /// ficheros del usuario actual (p.ej. "versiona-drive").
  String? get activeRepoName => driveService?.repoName;

  /// Se llama una vez al arrancar la app para reanudar la sesión si el
  /// usuario ya había conectado su cuenta anteriormente (o para entrar
  /// directamente si la app está en modo demo).
  Future<void> bootstrap() async {
    if (isDemoMode) {
      await _completeSignIn(
        GitHubConfig.demoPersonalAccessToken!,
        persist: false,
      );
      return;
    }

    final token = await _storage.readToken();
    if (token == null) {
      status = AuthStatus.signedOut;
      notifyListeners();
      return;
    }
    await _completeSignIn(token, persist: false);
  }

  Future<void> startSignIn() async {
    if (!isGitHubLoginSupportedOnThisPlatform) {
      errorMessage =
          'La conexión con GitHub no está disponible en el navegador '
          '(GitHub bloquea estas peticiones desde webs por seguridad). '
          'Abre Versiona como app de escritorio o móvil para conectar tu '
          'cuenta.';
      status = AuthStatus.signedOut;
      notifyListeners();
      return;
    }

    if (!GitHubConfig.isGitHubClientIdConfigured) {
      errorMessage =
          'Falta configurar el Client ID de GitHub en '
          'lib/config/github_config.dart (githubClientId) antes de poder '
          'conectar cuentas. Revisa las instrucciones en ese fichero.';
      status = AuthStatus.signedOut;
      notifyListeners();
      return;
    }

    status = AuthStatus.awaitingUserCode;
    errorMessage = null;
    deviceCodeRequest = null;
    notifyListeners();

    try {
      final request = await _deviceAuth.requestDeviceCode();
      deviceCodeRequest = request;
      _activeRequest = request;
      _pollIntervalSeconds = request.interval;
      _pollDeadline = DateTime.now().add(Duration(seconds: request.expiresIn));

      // En móvil, tras pulsar "Abrir GitHub" el código desaparece de la
      // vista al cambiar de app/pestaña: copiarlo evita que el usuario
      // tenga que memorizarlo.
      await Clipboard.setData(ClipboardData(text: request.userCode));

      notifyListeners();
      _schedulePoll(Duration(seconds: _pollIntervalSeconds));
    } on DeviceAuthException catch (e) {
      errorMessage = e.message;
      status = AuthStatus.signedOut;
      notifyListeners();
    } catch (e) {
      errorMessage =
          'No se pudo conectar con GitHub. Comprueba tu conexión a '
          'internet y vuelve a intentarlo. (${e.runtimeType})';
      status = AuthStatus.signedOut;
      notifyListeners();
    }
  }

  void _schedulePoll(Duration delay) {
    _pollTimer?.cancel();
    _pollTimer = Timer(delay, _poll);
  }

  Future<void> _poll() async {
    final request = _activeRequest;
    final deadline = _pollDeadline;
    if (request == null || deadline == null) return;

    if (DateTime.now().isAfter(deadline)) {
      _failSignIn('El código ha expirado. Vuelve a intentarlo.');
      return;
    }

    final result = await _deviceAuth.checkAccessToken(request);
    // La petición pudo tardar; si mientras tanto se canceló o completó el
    // inicio de sesión, no hacer nada más.
    if (_activeRequest != request) return;

    switch (result.status) {
      case DevicePollStatus.success:
        await _completeSignIn(result.token!, persist: true);
        break;
      case DevicePollStatus.pending:
        if (result.retryAfterSeconds != null) {
          _pollIntervalSeconds = result.retryAfterSeconds!;
        }
        _schedulePoll(Duration(seconds: _pollIntervalSeconds));
        break;
      case DevicePollStatus.expired:
        _failSignIn('El código ha expirado. Vuelve a intentarlo.');
        break;
      case DevicePollStatus.denied:
        _failSignIn('Has cancelado el acceso desde GitHub.');
        break;
      case DevicePollStatus.otherError:
        _failSignIn(
          result.errorMessage ?? 'No se pudo completar el inicio de sesión.',
        );
        break;
    }
  }

  /// Se llama cuando la app vuelve a primer plano (p.ej. el usuario regresa
  /// del navegador tras autorizar el acceso). Si hay una espera en curso,
  /// comprueba el estado inmediatamente en vez de esperar al siguiente
  /// ciclo de sondeo.
  void checkNowIfWaiting() {
    if (status == AuthStatus.awaitingUserCode && _activeRequest != null) {
      _pollTimer?.cancel();
      _poll();
    }
  }

  void _failSignIn(String message) {
    _pollTimer?.cancel();
    _activeRequest = null;
    errorMessage = message;
    status = AuthStatus.signedOut;
    notifyListeners();
  }

  /// Cancela una autenticación en curso (el usuario cierra el diálogo antes
  /// de completar el código).
  void cancelSignIn() {
    _pollTimer?.cancel();
    _activeRequest = null;
    deviceCodeRequest = null;
    status = AuthStatus.signedOut;
    notifyListeners();
  }

  Future<void> _completeSignIn(String token, {required bool persist}) async {
    _pollTimer?.cancel();
    _activeRequest = null;
    status = AuthStatus.preparingWorkspace;
    notifyListeners();

    try {
      final github = GitHub(auth: Authentication.withToken(token));
      final user = await github.users.getCurrentUser();
      final drive = DriveService(github);
      await drive.ensureDriveRepo(user.login!);

      if (persist) {
        await _storage.saveToken(token);
      }

      currentUser = user;
      driveService = drive;
      status = AuthStatus.signedIn;
      notifyListeners();
    } on GitHubError catch (e) {
      errorMessage =
          'No se pudo preparar tu espacio en GitHub: '
          '${e.message ?? e.runtimeType}';
      status = AuthStatus.signedOut;
      notifyListeners();
    } on PlatformException catch (e) {
      errorMessage =
          'No se pudo guardar la sesión de forma segura en este '
          'dispositivo: ${e.message ?? e.code}';
      status = AuthStatus.signedOut;
      notifyListeners();
    } catch (e) {
      errorMessage =
          'No se pudo preparar tu espacio en GitHub. Comprueba tu conexión '
          'a internet y vuelve a intentarlo. (${e.runtimeType})';
      status = AuthStatus.signedOut;
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    _pollTimer?.cancel();
    _activeRequest = null;

    // En modo demo no hay una sesión personal que cerrar: todo el mundo
    // comparte el mismo token.
    if (isDemoMode) return;

    await _storage.clearToken();
    currentUser = null;
    driveService = null;
    deviceCodeRequest = null;
    status = AuthStatus.signedOut;
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }
}
