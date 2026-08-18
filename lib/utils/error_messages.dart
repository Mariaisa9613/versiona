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
    return error.message ?? fallback;
  }
  if (error is StateError) {
    return error.message;
  }
  return '$fallback (${error.runtimeType})';
}
