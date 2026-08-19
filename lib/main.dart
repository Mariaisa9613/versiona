import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';

import 'screens/drive_screen.dart';
import 'screens/login_screen.dart';
import 'state/auth_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  runApp(const VersionaApp());
}

class VersionaApp extends StatelessWidget {
  const VersionaApp({super.key, AuthController? authController})
    : _authController = authController;

  /// Permite inyectar un [AuthController] (p.ej. en tests). Si se omite,
  /// se crea uno con la configuración por defecto de la app.
  final AuthController? _authController;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => (_authController ?? AuthController())..bootstrap(),
      child: MaterialApp(
        title: 'Versiona',
        themeMode: ThemeMode.light,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            // Violeta Profundo: el color de marca de Versiona (a juego con
            // el icono de la "canica").
            seedColor: const Color(0xFF8A2BE2),
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xFFF8F5FC),
          useMaterial3: true,
        ),
        home: const _RootScreen(),
      ),
    );
  }
}

class _RootScreen extends StatelessWidget {
  const _RootScreen();

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();

    if (auth.status == AuthStatus.checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (auth.status == AuthStatus.signedIn) {
      return const DriveScreen();
    }

    return const LoginScreen();
  }
}
