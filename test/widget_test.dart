import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:versiona/main.dart';
import 'package:versiona/screens/login_screen.dart';
import 'package:versiona/services/github_device_auth_service.dart';
import 'package:versiona/services/secure_storage_service.dart';
import 'package:versiona/state/auth_controller.dart';

/// Pumpea directamente [LoginScreen] con un [AuthController] ya en el
/// estado deseado, sin pasar por [VersionaApp.bootstrap] (que sobrescribiría
/// ese estado en cuanto resuelva la sesión guardada).
Future<void> _pumpLoginScreen(WidgetTester tester, AuthController auth) {
  return tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: auth,
      child: const MaterialApp(home: LoginScreen()),
    ),
  );
}

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
    'Sin sesión guardada, muestra la pantalla para empezar',
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
      expect(find.text('Continuar con GitHub'), findsOneWidget);

      await expectLater(
        find.byType(VersionaApp),
        matchesGoldenFile('golden/login_welcome.png'),
      );
    },
  );

  testWidgets('Estado esperando código de dispositivo', (tester) async {
    final auth = AuthController(storage: _FakeSecureStorageService())
      ..status = AuthStatus.awaitingUserCode
      ..deviceCodeRequest = DeviceCodeRequest(
        deviceCode: 'device-code',
        userCode: 'ABCD-1234',
        verificationUri: 'https://github.com/login/device',
        expiresIn: 900,
        interval: 5,
      );

    // No usa pumpAndSettle: el "Esperando confirmación..." lleva un
    // CircularProgressIndicator que anima sin parar.
    await _pumpLoginScreen(tester, auth);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Confirma tu código para activar tu cuenta'), findsOneWidget);
    expect(find.text('Confirmar código'), findsOneWidget);
    expect(find.text('ABCD-1234'), findsOneWidget);

    await expectLater(
      find.byType(LoginScreen),
      matchesGoldenFile('golden/login_device_code.png'),
    );
  });

  testWidgets('Estado eligiendo nombre de espacio', (tester) async {
    final auth = AuthController(storage: _FakeSecureStorageService())
      ..status = AuthStatus.choosingWorkspaceName
      ..suggestedWorkspaceName = 'versiona-drive';

    await _pumpLoginScreen(tester, auth);
    await tester.pumpAndSettle();

    expect(find.text('Ponle nombre a tu espacio'), findsOneWidget);
    expect(find.textContaining('espacio privado en Versiona'), findsOneWidget);
    expect(find.textContaining('repositorio'), findsNothing);

    await expectLater(
      find.byType(LoginScreen),
      matchesGoldenFile('golden/login_workspace_name.png'),
    );
  });
}
