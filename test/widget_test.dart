import 'package:flutter_test/flutter_test.dart';
import 'package:versiona/main.dart';
import 'package:versiona/services/secure_storage_service.dart';
import 'package:versiona/state/auth_controller.dart';

/// Evita tocar canales de plataforma (Keychain/Keystore) durante el test.
class _FakeSecureStorageService extends SecureStorageService {
  @override
  Future<String?> readToken() async => null;

  @override
  Future<void> saveToken(String token) async {}

  @override
  Future<void> clearToken() async {}
}

void main() {
  testWidgets(
    'Sin sesión guardada, muestra la pantalla para conectar con GitHub',
    (tester) async {
      final auth = AuthController(storage: _FakeSecureStorageService());

      await tester.pumpWidget(VersionaApp(authController: auth));
      await tester.pumpAndSettle();

      expect(find.text('Versiona'), findsOneWidget);
      expect(find.text('Acerca de'), findsOneWidget);
      expect(
        find.text('Creada por Maria Isabel Martinez Lopez'),
        findsOneWidget,
      );
      expect(find.text('LinkedIn'), findsOneWidget);
      expect(find.text('Conectar con GitHub'), findsOneWidget);
    },
  );
}
