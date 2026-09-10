import 'package:github/github.dart';

/// Convierte una excepción en un mensaje legible para el usuario.
///
/// Siempre que la excepción traiga un motivo real (de GitHub, o uno nuestro
/// mediante [StateError]) se muestra tal cual, en vez de un genérico
/// "algo ha fallado" que obliga a adivinar la causa cada vez.
String describeError(
  Object error, {
  String fallback = 'Ha ocurrido un error inesperado.',
}) {
  if (error is GitHubError) {
    if (isRateLimitError(error)) {
      return 'GitHub está limitando las peticiones de tu cuenta por un '
          'momento. Espera un minuto y vuelve a intentarlo.';
    }
    return error.message ?? fallback;
  }
  if (error is StateError) {
    return error.message;
  }
  return '$fallback (${error.runtimeType})';
}

/// Si [error] es GitHub diciendo que se han hecho demasiadas peticiones (el
/// límite por hora, o el "secundario" contra las ráfagas). El paquete
/// `github` no tiene una excepción propia para el 403 con que responde, así
/// que se reconoce por el mensaje.
bool isRateLimitError(GitHubError error) =>
    error is RateLimitHit ||
    (error.message?.toLowerCase().contains('rate limit') ?? false);
