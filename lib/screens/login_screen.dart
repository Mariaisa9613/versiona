import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/auth_controller.dart';
import '../utils/platform_info.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Cuando el usuario vuelve a la app (p.ej. tras autorizar el acceso en
    // el navegador), comprobamos el estado al momento en lugar de esperar
    // al siguiente ciclo de sondeo. Es el caso típico en móvil, donde
    // abrir GitHub oculta por completo la app.
    if (state == AppLifecycleState.resumed) {
      context.read<AuthController>().checkNowIfWaiting();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWideWindow = constraints.maxWidth >= 700;
              return ConstrainedBox(
                constraints: BoxConstraints(maxWidth: isWideWindow ? 480 : 420),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Consumer<AuthController>(
                    builder:
                        (context, auth, _) => switch (auth.status) {
                          AuthStatus.awaitingUserCode => _DeviceCodeCard(
                            auth: auth,
                          ),
                          AuthStatus.choosingWorkspaceName =>
                            _ChooseWorkspaceNameCard(auth: auth),
                          AuthStatus.preparingWorkspace =>
                            const _PreparingCard(),
                          _ => _WelcomeCard(auth: auth),
                        },
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard({required this.auth});

  static final Uri _linkedInUrl = Uri.parse(
    'https://www.linkedin.com/in/maria-isabel-martinez-lopez-126528127/',
  );

  final AuthController auth;

  Future<void> _openLinkedIn(BuildContext context) async {
    final opened = await launchUrl(
      _linkedInUrl,
      mode: LaunchMode.externalApplication,
    );
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir LinkedIn.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset('assets/branding/versiona_mark.png', height: 88),
        const SizedBox(height: 20),
        Text(
          'Versiona',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Acerca de',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        const Text(
          'Creada por Maria Isabel Martinez Lopez',
          textAlign: TextAlign.center,
        ),
        TextButton.icon(
          onPressed: () => _openLinkedIn(context),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: const Text('LinkedIn'),
        ),
        const SizedBox(height: 8),
        Text(
          'Guarda tus ficheros y organízalos en carpetas con el historial '
          'de cambios de cada uno, sin complicaciones.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 32),
        if (auth.errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              auth.errorMessage!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        FilledButton.icon(
          onPressed:
              isGitHubLoginSupportedOnThisPlatform ? auth.startSignIn : null,
          icon: const Icon(Icons.link),
          label: const Text('Conectar con GitHub'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ],
    );
  }
}

class _DeviceCodeCard extends StatelessWidget {
  const _DeviceCodeCard({required this.auth});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final request = auth.deviceCodeRequest;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Introduce este código en GitHub',
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          isMobilePlatform
              ? 'Hemos copiado el código. Se abrirá una ventana dentro de '
                  'la app: solo tienes que pegarlo para autorizar el '
                  'acceso de Versiona.'
              : 'Hemos copiado el código. Se abrirá tu navegador: pégalo '
                  'para autorizar el acceso de Versiona.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        if (request == null)
          const CircularProgressIndicator()
        else ...[
          Container(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  request.userCode,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  tooltip: 'Copiar código',
                  icon: const Icon(Icons.copy_outlined),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: request.userCode));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Código copiado')),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed:
                () => launchUrl(
                  Uri.parse(request.verificationUri),
                  mode:
                      isMobilePlatform
                          ? LaunchMode.inAppBrowserView
                          : LaunchMode.externalApplication,
                ),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Abrir GitHub'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 16),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('Esperando confirmación...'),
            ],
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: auth.cancelSignIn,
            child: const Text('Cancelar'),
          ),
        ],
      ],
    );
  }
}

/// Paso previo a crear el primer espacio de Versiona en una cuenta: se
/// muestra solo una vez, cuando no se encuentra ningún repositorio de
/// Versiona ya existente. Deja elegir (o aceptar el sugerido) un nombre
/// antes de crear nada, para no tocar en silencio los repos que el usuario
/// ya tuviera en su cuenta.
class _ChooseWorkspaceNameCard extends StatefulWidget {
  const _ChooseWorkspaceNameCard({required this.auth});

  final AuthController auth;

  @override
  State<_ChooseWorkspaceNameCard> createState() =>
      _ChooseWorkspaceNameCardState();
}

class _ChooseWorkspaceNameCardState extends State<_ChooseWorkspaceNameCard> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.auth.suggestedWorkspaceName ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() => widget.auth.confirmWorkspaceName(_controller.text);

  @override
  Widget build(BuildContext context) {
    final auth = widget.auth;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.drive_folder_upload_outlined,
          size: 64,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'Ponle nombre a tu espacio',
          style: Theme.of(context).textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Es la primera vez que conectas esta cuenta: vamos a crear un '
          'repositorio privado en tu GitHub para guardar tus ficheros. '
          'Puedes usar el nombre que te sugerimos o poner el tuyo.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nombre del espacio de trabajo',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (_) => _confirm(),
        ),
        if (auth.errorMessage != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              auth.errorMessage!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: _confirm,
          icon: const Icon(Icons.check),
          label: const Text('Crear espacio'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: auth.cancelWorkspaceChoice,
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}

class _PreparingCard extends StatelessWidget {
  const _PreparingCard();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 24),
        Text(
          'Preparando tu espacio...',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ],
    );
  }
}
