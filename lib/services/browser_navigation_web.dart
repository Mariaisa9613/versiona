import 'package:web/web.dart' as web;

String? readSessionValue(String key) => web.window.sessionStorage.getItem(key);

void writeSessionValue(String key, String value) =>
    web.window.sessionStorage.setItem(key, value);

void removeSessionValue(String key) =>
    web.window.sessionStorage.removeItem(key);

void navigateBrowser(String url) => web.window.location.assign(url);

void replaceBrowserUrl(String url) =>
    web.window.history.replaceState(null, '', url);
