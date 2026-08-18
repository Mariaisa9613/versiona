import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Envoltorio fino sobre almacenamiento seguro (Keychain/Keystore) para
/// guardar el token de acceso de GitHub en el dispositivo.
class SecureStorageService {
  SecureStorageService()
    : _storage = const FlutterSecureStorage(
        // El keychain "con protección de datos" (el que usa por defecto)
        // exige que la app esté firmada con un certificado de desarrollador
        // real y la entitlement de grupos de keychain — algo que quitamos
        // a propósito para poder compilar en local sin cuenta de Apple
        // Developer. El keychain clásico funciona igual de bien para nuestro
        // caso (un único valor, sin compartirlo entre apps) sin ese
        // requisito.
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      );

  final FlutterSecureStorage _storage;

  static const _tokenKey = 'github_access_token';

  Future<String?> readToken() => _storage.read(key: _tokenKey);

  Future<void> saveToken(String token) =>
      _storage.write(key: _tokenKey, value: token);

  Future<void> clearToken() => _storage.delete(key: _tokenKey);
}
