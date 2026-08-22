import 'package:flutter/foundation.dart';

/// true en Android/iOS nativos. En web siempre es false (no hay "vista
/// dentro de la app": el navegador ya es la propia app), incluso si el
/// navegador corre sobre un móvil.
bool get isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Las apps nativas usan Device Flow y la web usa Authorization Code + PKCE
/// mediante el proxy OAuth configurado al compilar.
bool get isGitHubLoginSupportedOnThisPlatform => true;
