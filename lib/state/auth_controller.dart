import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:github/github.dart';
import 'package:http/http.dart' as http;

import '../config/github_config.dart';
import '../services/drive_service.dart';
import '../services/github_device_auth_service.dart';
import '../services/github_web_auth_service.dart';
import '../services/logging_github_client.dart';
import '../services/secure_storage_service.dart';
import '../utils/repo_naming.dart';

enum AuthStatus {
  /// Comprobando si ya hay una sesión guardada en el dispositivo.
  checking,
  signedOut,

  /// Se ha pedido un código y se está esperando a que el usuario lo
  /// introduzca en github.com/login/device.
  awaitingUserCode,

  /// Token obtenido; preparando el repositorio privado del usuario.
  preparingWorkspace,

  /// Primera vez que se conecta esta cuenta: todavía no existe ningún
  /// espacio de Versiona en ella, así que se espera a que el usuario
  /// confirme (o cambie) el nombre sugerido antes de crear nada.
  choosingWorkspaceName,
  signedIn,
}

/// Controla el ciclo de vida completo de la sesión con GitHub: Device Flow,
/// persistencia del token y preparación del "workspace" (repo privado).
class AuthController extends ChangeNotifier {
  AuthController({
    SecureStorageService? storage,
    GitHubDeviceAuthService? deviceAuth,
    GitHubWebAuthService? webAuth,
  }) : _storage = storage ?? SecureStorageService(),
       _deviceAuth = deviceAuth ?? GitHubDeviceAuthService(),
       _webAuth = webAuth ?? GitHubWebAuthService();

  final SecureStorageService _storage;
  final GitHubDeviceAuthService _deviceAuth;
  final GitHubWebAuthService _webAuth;

  Timer? _pollTimer;
  DeviceCodeRequest? _activeRequest;
  DateTime? _pollDeadline;
  int _pollIntervalSeconds = 5;

  AuthStatus status = AuthStatus.checking;
  DeviceCodeRequest? deviceCodeRequest;
  String? errorMessage;
  CurrentUser? currentUser;
  DriveService? driveService;

  /// Nombre autogenerado que se ofrece como punto de partida en
  /// [AuthStatus.choosingWorkspaceName]; el usuario puede aceptarlo tal
  /// cual o escribir el suyo propio.
  String? suggestedWorkspaceName;

  // Datos de la sesión en curso mientras se espera a que el usuario elija
  // el nombre del espacio (ver [AuthStatus.choosingWorkspaceName]).
  DriveService? _pendingDrive;
  CurrentUser? _pendingUser;
  String? _pendingToken;
  bool _pendingPersist = false;

  /// En modo demo todo el mundo entra con el mismo token compartido, sin
  /// pantalla de login. Ver [GitHubConfig.demoPersonalAccessToken].
  bool get isDemoMode => GitHubConfig.isDemoMode;

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

    if (kIsWeb && _webAuth.hasCallback) {
      status = AuthStatus.preparingWorkspace;
      notifyListeners();
      try {
        final token = await _webAuth.completeCallback();
        if (token != null) {
          await _completeSignIn(token, persist: true);
          return;
        }
      } on WebAuthException catch (e) {
        errorMessage = e.message;
        status = AuthStatus.signedOut;
        notifyListeners();
        return;
      }
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
    if (!GitHubConfig.isGitHubClientIdConfigured) {
      errorMessage =
          'Falta configurar el Client ID de GitHub en '
          'lib/config/github_config.dart (githubClientId) antes de poder '
          'conectar cuentas. Revisa las instrucciones en ese fichero.';
      status = AuthStatus.signedOut;
      notifyListeners();
      return;
    }

    if (kIsWeb) {
      errorMessage = null;
      status = AuthStatus.preparingWorkspace;
      notifyListeners();
      try {
        await _webAuth.startAuthorization();
      } on WebAuthException catch (e) {
        errorMessage = e.message;
        status = AuthStatus.signedOut;
        notifyListeners();
      }
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

    final httpClient = LoggingGitHubClient(http.Client());
    try {
      final github = GitHub(
        auth: Authentication.withToken(token),
        client: httpClient,
      );
      final user = await github.users.getCurrentUser();
      final drive = DriveService(github);

      if (isDemoMode) {
        // El modo demo no debe tener ningún paso manual: todo el mundo
        // comparte la misma cuenta y el mismo repo fijo.
        await drive.ensureDriveRepo(user.login!);
        currentUser = user;
        driveService = drive;
        status = AuthStatus.signedIn;
        notifyListeners();
        return;
      }

      final existingWorkspace = await drive.findWorkspace();
      if (existingWorkspace != null) {
        // Esta cuenta ya tiene un espacio de Versiona (creado antes, quizá
        // desde otro dispositivo): lo reanudamos sin volver a preguntar.
        await drive.switchTo(RepositorySlug.full(existingWorkspace.fullName));
        if (persist) {
          await _storage.saveToken(token);
        }
        currentUser = user;
        driveService = drive;
        status = AuthStatus.signedIn;
        notifyListeners();
        return;
      }

      // Primera vez que se conecta esta cuenta: no existe todavía ningún
      // espacio de Versiona. Antes de crear nada, se deja que el usuario
      // confirme o cambie el nombre sugerido — así nunca se toca en
      // silencio uno de sus proyectos ya existentes.
      _pendingDrive = drive;
      _pendingUser = user;
      _pendingToken = token;
      _pendingPersist = persist;
      suggestedWorkspaceName = autoWorkspaceName(user.login);
      status = AuthStatus.choosingWorkspaceName;
      notifyListeners();
    } on GitHubError catch (e) {
      // GitHub rechazó el token (revocado, expirado o sin permisos): no
      // tiene sentido conservarlo, o cada arranque repetiría este mismo
      // error en lugar de mostrar una pantalla de login limpia.
      if (!isDemoMode) {
        await _storage.clearToken();
      }
      final httpStatus = httpClient.lastErrorStatusCode;
      // El paquete `github` convierte cualquier 401 en la excepción
      // `AccessForbidden`, con el mensaje fijo "Access Forbidden" (no el
      // motivo real de GitHub). Como esta rama ya borra el token inválido,
      // basta con pedir al usuario que vuelva a conectar su cuenta.
      errorMessage = httpStatus == 401
          ? 'Tu sesión de GitHub ha caducado o fue revocada. Vuelve a '
                'conectar tu cuenta para seguir usando Versiona.'
          : 'No se pudo preparar tu espacio en GitHub: '
                '${e.message ?? e.runtimeType}'
                '${httpStatus != null ? ' (HTTP $httpStatus)' : ''}';
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

  /// Confirma (o sustituye) el nombre sugerido en
  /// [AuthStatus.choosingWorkspaceName], crea el repositorio en GitHub y
  /// completa el inicio de sesión. Si algo falla (p.ej. nombre en uso), se
  /// vuelve a [AuthStatus.choosingWorkspaceName] para poder reintentar sin
  /// perder el progreso del login.
  Future<void> confirmWorkspaceName(String rawName) async {
    final drive = _pendingDrive;
    final user = _pendingUser;
    final token = _pendingToken;
    if (drive == null || user == null || token == null) return;

    status = AuthStatus.preparingWorkspace;
    errorMessage = null;
    notifyListeners();

    final slug = slugifyRepoName(rawName);
    final name = slug.isEmpty ? autoWorkspaceName(user.login) : slug;

    try {
      await drive.createRepo(name);

      if (_pendingPersist) {
        await _storage.saveToken(token);
      }

      currentUser = user;
      driveService = drive;
      status = AuthStatus.signedIn;
      _pendingDrive = null;
      _pendingUser = null;
      _pendingToken = null;
      _pendingPersist = false;
      suggestedWorkspaceName = null;
    } on GitHubError catch (e) {
      errorMessage =
          'No se pudo crear "$name" en GitHub: ${e.message ?? e.runtimeType}';
      status = AuthStatus.choosingWorkspaceName;
    } catch (e) {
      errorMessage =
          'No se pudo crear tu espacio de trabajo. Comprueba tu conexión a '
          'internet y vuelve a intentarlo. (${e.runtimeType})';
      status = AuthStatus.choosingWorkspaceName;
    }
    notifyListeners();
  }

  /// Cancela la elección de nombre de espacio (p.ej. el usuario cierra el
  /// paso): descarta el token obtenido y vuelve a la pantalla de login sin
  /// haber creado ni guardado nada.
  void cancelWorkspaceChoice() {
    _pendingDrive = null;
    _pendingUser = null;
    _pendingToken = null;
    _pendingPersist = false;
    suggestedWorkspaceName = null;
    status = AuthStatus.signedOut;
    notifyListeners();
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
