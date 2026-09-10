import 'package:flutter/foundation.dart';

/// true en Android/iOS nativos. En web siempre es false (no hay "vista
/// dentro de la app": el navegador ya es la propia app), incluso si el
/// navegador corre sobre un móvil.
bool get isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Si tiene sentido ofrecer "fotografiar un ticket": image_picker solo sabe
/// abrir la cámara en Android/iOS y en el navegador (que en un ordenador cae
/// en el selector de archivos). En macOS/Windows/Linux no la soporta, y el
/// botón solo servía para acabar en un error.
bool get canCaptureTicket => kIsWeb || isMobilePlatform;

/// Las apps nativas usan Device Flow y la web usa Authorization Code + PKCE
/// mediante el proxy OAuth configurado al compilar.
bool get isGitHubLoginSupportedOnThisPlatform => true;
