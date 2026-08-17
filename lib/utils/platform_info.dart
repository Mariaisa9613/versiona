import 'package:flutter/foundation.dart';

/// true en Android/iOS nativos. En web siempre es false (no hay "vista
/// dentro de la app": el navegador ya es la propia app), incluso si el
/// navegador corre sobre un móvil.
bool get isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// GitHub no envía cabeceras CORS en los endpoints del Device Flow
/// (`/login/device/code`, `/login/oauth/access_token`): un navegador los
/// bloquea antes de que la petición llegue a ningún sitio. No hay forma de
/// evitarlo desde una app 100% cliente sin un servidor intermedio, así que
/// el login real de GitHub solo puede funcionar en las apps nativas
/// (Android, iOS, macOS, Windows, Linux), nunca en la versión web.
bool get isGitHubLoginSupportedOnThisPlatform => !kIsWeb;
