String? readSessionValue(String key) => null;

void writeSessionValue(String key, String value) {}

void removeSessionValue(String key) {}

void navigateBrowser(String url) {
  throw UnsupportedError(
    'La navegación OAuth web solo está disponible en web.',
  );
}

void replaceBrowserUrl(String url) {}
