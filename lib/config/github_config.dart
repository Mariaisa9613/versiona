/// Configuración de la integración con GitHub.
///
/// Hay dos modos, mutuamente excluyentes:
///
/// ## Modo demo (pruebas rápidas, sin login)
/// Pensado para que gente sin cuenta de GitHub pueda abrir la app y probar
/// la idea al instante, sin ningún paso previo. Todo el mundo que use ese
/// build comparte la misma cuenta/repositorio de GitHub.
/// 1. Ve a https://github.com/settings/tokens?type=beta > "Generate new token"
///    (o, más simple, "Tokens (classic)" > "Generate new token (classic)").
/// 2. Dale acceso al scope "repo" (o, en fine-grained, permisos de
///    lectura/escritura sobre "Contents" y "Administration").
/// 3. Copia el token y pégalo en [demoPersonalAccessToken].
///
/// ⚠️ Ese token queda dentro del binario de la app: cualquiera que la
/// instale puede extraerlo y usarlo para leer/escribir en esa cuenta de
/// GitHub. Úsalo solo para repartir la app a un grupo cerrado de testers de
/// confianza, nunca para publicarla o para gente que no conozcas. Antes de
/// lanzar de verdad, vuelve a dejar este valor en `null`.
///
/// ## Modo real (Device Flow, una cuenta de GitHub por persona)
/// Se activa automáticamente en cuanto [demoPersonalAccessToken] es `null`.
/// Requiere crear una OAuth App (la creas tú una vez; tus usuarios no la
/// tocan ni la ven):
/// 1. Ve a https://github.com/settings/developers > "New OAuth App".
/// 2. Rellena cualquier nombre y "Homepage URL" (p.ej. https://example.com).
/// 3. Marca la casilla "Enable Device Flow" (imprescindible).
/// 4. "Authorization callback URL" no se usa en este flujo: pon la misma
///    Homepage URL.
/// 5. Copia el "Client ID" generado y pégalo abajo en [githubClientId].
///
/// No hace falta ningún "Client Secret": el Device Flow está pensado para
/// apps que no pueden guardar secretos de forma segura (como esta).
class GitHubConfig {
  GitHubConfig._();

  /// Si tiene un valor, la app entra directamente con este token (modo
  /// demo) y se salta la pantalla de login por completo. Déjalo en `null`
  /// para usar el login real (Device Flow).
  static const String? demoPersonalAccessToken = null;

  static bool get isDemoMode =>
      demoPersonalAccessToken != null && demoPersonalAccessToken!.isNotEmpty;

  /// Client ID público de la OAuth App. Sustitúyelo por el tuyo.
  /// Solo se usa cuando [demoPersonalAccessToken] es `null`.
  static const String githubClientId = 'Ov23liV3MqUyzESsKWT9';

  /// URL del endpoint que intercambia el código OAuth por un token en web.
  /// Se inyecta al compilar para no ligar la app a un despliegue concreto.
  static const String webOAuthProxyUrl = String.fromEnvironment(
    'OAUTH_PROXY_URL',
  );

  static bool get isWebOAuthConfigured => webOAuthProxyUrl.isNotEmpty;

  static const String _placeholderClientId = 'REEMPLAZA_CON_TU_CLIENT_ID';

  /// `false` mientras [githubClientId] siga siendo el valor de ejemplo: sin
  /// esto, GitHub responde 404 a cualquier intento de login y la pantalla
  /// de código de dispositivo nunca llega a aparecer.
  static bool get isGitHubClientIdConfigured =>
      githubClientId != _placeholderClientId && githubClientId.isNotEmpty;

  /// Permisos solicitados: acceso completo a repos (privados incluidos)
  /// para poder crear el repositorio de datos y leer/escribir ficheros, más
  /// "delete_repo" porque el menú "Gestionar repositorios" permite
  /// eliminarlos desde la app. Si conectaste tu cuenta antes de añadirse
  /// "delete_repo", cierra sesión y vuelve a conectar para que GitHub te
  /// pida también ese permiso.
  static const String scopes = 'repo delete_repo';

  /// Nombre del repositorio privado que la app crea automáticamente para
  /// guardar los ficheros del usuario.
  static const String driveRepoName = 'versiona-drive';

  /// Rama donde se escriben todos los cambios (subir, borrar, renombrar,
  /// mover, restaurar) antes de ser aprobados. La rama por defecto del
  /// repositorio (normalmente "main") solo se actualiza cuando alguien
  /// pulsa "Aprobar y consolidar", que fusiona esta rama sobre ella.
  static const String reviewBranchName = 'en-revision';

  /// Nombre del fichero "placeholder" usado para poder crear carpetas
  /// vacías (Git no versiona carpetas vacías).
  static const String folderKeepFile = '.versiona-keep';
}
