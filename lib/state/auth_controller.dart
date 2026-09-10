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
    http.Client? httpClient,
  }) : _storage = storage ?? SecureStorageService(),
       _deviceAuth = deviceAuth ?? GitHubDeviceAuthService(),
       _webAuth = webAuth ?? GitHubWebAuthService(),
       _httpClient = httpClient ?? http.Client();

  final SecureStorageService _storage;
  final GitHubDeviceAuthService _deviceAuth;
  final GitHubWebAuthService _webAuth;

  /// Cliente con el que se habla con la API de GitHub. Inyectable para
  /// poder probar en los tests qué pasa ante cada respuesta suya.
  final http.Client _httpClient;

  Timer? _pollTimer;
  DeviceCodeRequest? _activeRequest;
  DateTime? _pollDeadline;
  int _pollIntervalSeconds = 5;

  /// Hay una comprobación del código en vuelo. Cancelar el temporizador no
  /// cancela la petición, así que sin esto volver a primer plano podía
  /// dejar dos sondeos vivos, cada uno reprogramando el suyo.
  bool _pollInFlight = false;

  AuthStatus status = AuthStatus.checking;
  DeviceCodeRequest? deviceCodeRequest;
  String? errorMessage;
  CurrentUser? currentUser;
  DriveService? driveService;

  /// `true` cuando el último intento falló por algo pasajero (GitHub caído,
  /// límite de peticiones, sin conexión) y no por un token rechazado: la
  /// sesión guardada sigue siendo válida y se puede reintentar con
  /// [retrySavedSession], sin repetir el inicio de sesión entero.
  bool canRetrySavedSession = false;

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

  /// Aviso para enseñar una sola vez al entrar, cuando el inicio de sesión
  /// ha ido bien pero algo secundario no (p.ej. el llavero no ha podido
  /// guardar la sesión). Se consume con [takeSignInNotice].
  String? _signInNotice;

  /// Devuelve el aviso pendiente, si lo hay, y lo borra para que no se
  /// vuelva a enseñar.
  String? takeSignInNotice() {
    final notice = _signInNotice;
    _signInNotice = null;
    return notice;
  }

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
    // Se empieza un login nuevo: la sesión guardada anterior ya no es lo
    // que se está reintentando.
    canRetrySavedSession = false;
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
      //
      // Es una comodidad, no un requisito: ni se espera a que termine ni se
      // deja que su fallo tumbe el login. Esperarlo dentro del try hacía que
      // un portapapeles no disponible (pasa en algunos escritorios) abortara
      // el inicio de sesión entero con un "no se pudo conectar con GitHub"
      // que no tenía nada que ver. El código sigue en pantalla para
      // teclearlo a mano, y hay un botón de copiar al lado.
      unawaited(
        Clipboard.setData(ClipboardData(text: request.userCode)).catchError((
          Object e,
        ) {
          debugPrint('[Versiona] No se pudo copiar el código al '
              'portapapeles: $e');
        }),
      );

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
    // Ya hay una comprobación en vuelo (p.ej. checkNowIfWaiting se ha
    // adelantado al temporizador): dejarla terminar. Sea cual sea su
    // desenlace, vuelve a programar el sondeo, lo completa o lo cancela,
    // así que no hace falta hacer nada aquí. Sin este guardia se sondeaba
    // al doble de ritmo y GitHub respondía "slow_down".
    if (_pollInFlight) return;

    final request = _activeRequest;
    final deadline = _pollDeadline;
    if (request == null || deadline == null) return;

    if (DateTime.now().isAfter(deadline)) {
      _failSignIn('El código ha expirado. Vuelve a intentarlo.');
      return;
    }

    final DevicePollResult result;
    _pollInFlight = true;
    try {
      result = await _deviceAuth.checkAccessToken(request);
    } catch (e) {
      // Un corte de red o una respuesta rara de GitHub no invalidan el
      // código: se reintenta en el siguiente ciclo, y si la cosa no se
      // arregla acabará caducando por su cuenta con un mensaje claro.
      //
      // Antes esta excepción escapaba del callback del Timer sin que nadie
      // la capturase: el sondeo no se volvía a programar y la pantalla se
      // quedaba esperando el código para siempre.
      debugPrint('[Versiona] No se pudo comprobar el código de acceso: $e');
      if (_activeRequest == request) {
        _schedulePoll(Duration(seconds: _pollIntervalSeconds));
      }
      return;
    } finally {
      _pollInFlight = false;
    }

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
    canRetrySavedSession = false;
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
    canRetrySavedSession = false;
    status = AuthStatus.preparingWorkspace;
    notifyListeners();

    final httpClient = LoggingGitHubClient(_httpClient);
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
        if (persist) await _rememberSession(token);
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
      final httpStatus = httpClient.lastErrorStatusCode;
      // Solo un 401 significa que GitHub ha rechazado el token (revocado o
      // caducado): ese sí hay que borrarlo, o cada arranque repetiría el
      // mismo error en vez de una pantalla de login limpia.
      //
      // Cualquier otro fallo (un 5xx de GitHub, un 403 por límite de
      // peticiones, una caída de red que el paquete envuelve en GitHubError)
      // es pasajero y no dice nada del token. Borrarlo ahí obligaba a
      // repetir el device flow entero por una incidencia de unos minutos.
      final tokenRejected = httpStatus == 401;
      if (tokenRejected && !isDemoMode) {
        await _storage.clearToken();
      }
      canRetrySavedSession = !tokenRejected;
      // El paquete `github` convierte cualquier 401 en la excepción
      // `AccessForbidden`, con el mensaje fijo "Access Forbidden" (no el
      // motivo real de GitHub). Como esa rama ya borra el token inválido,
      // basta con pedir al usuario que vuelva a conectar su cuenta.
      errorMessage = tokenRejected
          ? 'Tu sesión de GitHub ha caducado o fue revocada. Vuelve a '
                'conectar tu cuenta para seguir usando Versiona.'
          : 'No se pudo preparar tu espacio en GitHub: '
                '${e.message ?? e.runtimeType}'
                '${httpStatus != null ? ' (HTTP $httpStatus)' : ''}'
                '. Tu sesión sigue guardada: vuelve a intentarlo en un '
                'momento.';
      status = AuthStatus.signedOut;
      notifyListeners();
    } catch (e) {
      // Sin red, DNS caído, certificado... nada de esto invalida el token:
      // se conserva y se ofrece reintentar.
      canRetrySavedSession = true;
      errorMessage =
          'No se pudo preparar tu espacio en GitHub. Comprueba tu conexión '
          'a internet y vuelve a intentarlo. (${e.runtimeType})';
      status = AuthStatus.signedOut;
      notifyListeners();
    }
  }

  /// Vuelve a intentar preparar el espacio con la sesión que ya está
  /// guardada en el dispositivo, tras un fallo pasajero
  /// ([canRetrySavedSession]). Evita repetir el device flow entero por una
  /// incidencia de unos minutos en GitHub.
  Future<void> retrySavedSession() async {
    if (isDemoMode) {
      await _completeSignIn(
        GitHubConfig.demoPersonalAccessToken!,
        persist: false,
      );
      return;
    }

    final token = await _storage.readToken();
    if (token == null) {
      canRetrySavedSession = false;
      errorMessage =
          'Ya no hay ninguna sesión guardada en este dispositivo. Conecta '
          'tu cuenta de GitHub para continuar.';
      status = AuthStatus.signedOut;
      notifyListeners();
      return;
    }
    await _completeSignIn(token, persist: false);
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

      if (_pendingPersist) await _rememberSession(token);

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

  /// Guarda el token en el llavero del dispositivo.
  ///
  /// Un fallo aquí no se propaga: el inicio de sesión ya ha ido bien, y
  /// tratarlo como un error dejaba al usuario fuera. Peor aún justo después
  /// de crear el espacio, porque volvía a pedirle el nombre y reintentar
  /// chocaba con el repositorio que ya se había creado. Lo único que se
  /// pierde es que la próxima vez habrá que volver a conectar la cuenta, y
  /// eso se avisa.
  Future<void> _rememberSession(String token) async {
    try {
      await _storage.saveToken(token);
    } catch (e) {
      final reason = e is PlatformException ? e.message ?? e.code : '$e';
      debugPrint('[Versiona] No se pudo guardar la sesión: $reason');
      _signInNotice =
          'Has entrado, pero este dispositivo no ha podido guardar la sesión '
          'de forma segura ($reason): la próxima vez tendrás que volver a '
          'conectar tu cuenta.';
    }
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
    canRetrySavedSession = false;
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
