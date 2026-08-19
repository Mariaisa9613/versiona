const Map<String, String> _accentReplacements = {
  'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', 'ã': 'a',
  'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e',
  'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i',
  'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', 'õ': 'o',
  'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
  'ñ': 'n', 'ç': 'c',
};

/// Convierte texto libre (p.ej. "Tesorería 2026") en un nombre válido de
/// repositorio de GitHub: minúsculas, sin acentos ni espacios, solo
/// `[a-z0-9-]`. Devuelve cadena vacía si no queda ningún carácter útil.
String slugifyRepoName(String input) {
  var result = input.toLowerCase();
  _accentReplacements.forEach((accented, plain) {
    result = result.replaceAll(accented, plain);
  });
  result = result.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  result = result.replaceAll(RegExp(r'^-+|-+$'), '');
  if (result.length > 90) result = result.substring(0, 90);
  return result;
}
