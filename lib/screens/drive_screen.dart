import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:github/github.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/drive_entry.dart';
import '../services/ticket_capture_service.dart';
import '../services/ticket_ocr_service.dart';
import '../state/auth_controller.dart';
import '../state/drive_controller.dart';
import '../utils/drive_entry_icons.dart';
import '../utils/error_messages.dart';
import '../utils/repo_naming.dart';
import '../widgets/file_preview_dialog.dart';
import '../widgets/review_status_badge.dart';
import 'folder_picker_screen.dart';
import 'version_history_screen.dart';

/// Prefijo de nombre que marca un fichero como ticket fotografiado desde la
/// cámara, para poder distinguirlo visualmente en el tablero Kanban.
const _ticketFilePrefix = 'TICKET_';

class DriveScreen extends StatelessWidget {
  const DriveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create:
          (context) =>
              DriveController(context.read<AuthController>().driveService!)
                ..load()
                ..loadAvailableRepos(),
      child: const _DriveView(),
    );
  }
}

class _DriveView extends StatelessWidget {
  const _DriveView();

  void _openHistory(
    BuildContext context,
    DriveController drive,
    DriveEntry entry,
  ) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => ChangeNotifierProvider.value(
              value: drive,
              child: VersionHistoryScreen(entry: entry),
            ),
      ),
    );
  }

  Future<void> _uploadFile(BuildContext context) async {
    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);
    final currentUser = context.read<AuthController>().currentUser;
    final userDisplayName =
        (currentUser?.name?.trim().isNotEmpty ?? false)
            ? currentUser!.name!.trim()
            : (currentUser?.login ?? 'Alguien');

    final result = await showModalBottomSheet<(PlatformFile, String)>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _UploadSheet(userDisplayName: userDisplayName),
    );
    if (result == null) return;

    final (file, message) = result;
    if (file.bytes == null) return;

    try {
      await drive.uploadFile(file.name, file.bytes!, commitMessage: message);
      _warnIfReloadStale(drive, messenger);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            describeError(e, fallback: 'No se pudo subir el fichero.'),
          ),
        ),
      );
    }
  }

  /// El fichero puede haberse subido bien aunque la relectura posterior de
  /// la carpeta haya fallado (ver [DriveController.load]): en ese caso la
  /// lista se conserva tal y como estaba, sin el fichero nuevo todavía, así
  /// que avisamos para que el usuario sepa que debe refrescar en vez de
  /// pensar que la subida falló en silencio.
  void _warnIfReloadStale(
    DriveController drive,
    ScaffoldMessengerState messenger,
  ) {
    if (drive.error == null) return;
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Guardado, pero la lista no se ha podido refrescar todavía. Desliza hacia abajo para actualizarla.',
        ),
      ),
    );
  }

  /// Abre la cámara, comprime la foto y la sube directamente a la carpeta
  /// actual como un nuevo ticket. Al entrar por la rama de revisión, aparece
  /// enseguida en la columna "Pendiente de validación" del tablero.
  ///
  /// Antes de subir, intenta reconocer el texto del ticket on-device (ML
  /// Kit, sin conexión) para incluirlo en el mensaje de commit. En web, o si
  /// el reconocimiento falla, se sube igualmente con el mensaje por defecto.
  Future<void> _captureTicket(BuildContext context) async {
    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);
    final ticketService = TicketCaptureService();

    final XFile? photo;
    try {
      photo = await ticketService.capturarTicket();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            describeError(e, fallback: 'No se pudo abrir la cámara.'),
          ),
        ),
      );
      return;
    }
    if (photo == null) return; // El usuario canceló la foto.

    final bytes = await photo.readAsBytes();
    final fileName = ticketService.nombreTicket();
    final extractedText = await TicketOcrService().extractText(photo.path);

    final commitMessage =
        extractedText == null
            ? 'Ticket fotografiado desde el móvil'
            : 'Ticket fotografiado desde el móvil\n\n$extractedText';

    try {
      await drive.uploadFile(fileName, bytes, commitMessage: commitMessage);
      _warnIfReloadStale(drive, messenger);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            describeError(e, fallback: 'No se pudo subir el ticket.'),
          ),
        ),
      );
    }
  }

  Future<void> _createFolder(BuildContext context) async {
    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Nueva carpeta'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Nombre de la carpeta',
              ),
              onSubmitted: (v) => Navigator.of(context).pop(v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(controller.text),
                child: const Text('Crear'),
              ),
            ],
          ),
    );

    if (name == null || name.trim().isEmpty) return;
    try {
      await drive.createFolder(name.trim());
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            describeError(e, fallback: 'No se pudo crear la carpeta.'),
          ),
        ),
      );
    }
  }

  Future<void> _renameEntry(BuildContext context, DriveEntry entry) async {
    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController(text: entry.name);
    final newName = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Renombrar'),
            content: TextField(
              controller: controller,
              autofocus: true,
              onSubmitted: (v) => Navigator.of(context).pop(v),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(controller.text),
                child: const Text('Renombrar'),
              ),
            ],
          ),
    );

    if (newName == null) return;
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == entry.name) return;

    try {
      await drive.rename(entry, trimmed);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(describeError(e, fallback: 'No se pudo renombrar.')),
        ),
      );
    }
  }

  Future<void> _moveEntry(BuildContext context, DriveEntry entry) async {
    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);

    final destination = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder:
            (_) => FolderPickerScreen(
              entryName: entry.name,
              excludePath: entry.isFolder ? entry.path : null,
            ),
      ),
    );
    if (destination == null) return;

    try {
      await drive.move(entry, destination);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(describeError(e, fallback: 'No se pudo mover.')),
        ),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, DriveEntry entry) async {
    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('Eliminar "${entry.name}"'),
            content: Text(
              entry.isFolder
                  ? 'Se eliminará la carpeta y todo su contenido. Seguirá '
                      'estando disponible en el historial de versiones.'
                  : 'Se eliminará el fichero. Seguirá estando disponible en su '
                      'historial de versiones.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Eliminar'),
              ),
            ],
          ),
    );

    if (confirmed != true) return;
    try {
      await drive.deleteEntry(entry);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(describeError(e, fallback: 'No se pudo eliminar.')),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthController>();
    final drive = context.watch<DriveController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Versiona'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: _StatusBar(auth: auth, drive: drive),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: CircleAvatar(
              radius: 16,
              backgroundImage:
                  auth.currentUser?.avatarUrl != null
                      ? NetworkImage(auth.currentUser!.avatarUrl!)
                      : null,
              child:
                  auth.currentUser?.avatarUrl == null
                      ? const Icon(Icons.person, size: 18)
                      : null,
            ),
            onSelected: (value) {
              if (value == 'signOut') auth.signOut();
            },
            itemBuilder:
                (context) => [
                  PopupMenuItem(
                    enabled: false,
                    child: Text(
                      auth.isDemoMode
                          ? 'Cuenta de pruebas compartida'
                          : auth.currentUser?.login ?? '',
                    ),
                  ),
                  if (!auth.isDemoMode) ...[
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'signOut',
                      child: Text('Cerrar sesión'),
                    ),
                  ],
                ],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Row(
                children: [
                  Expanded(child: _Breadcrumbs(drive: drive)),
                  _ViewModeToggle(drive: drive),
                  const SizedBox(width: 12),
                ],
              ),
              const Divider(height: 1),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: drive.load,
                  child: _DriveBody(
                    drive: drive,
                    onOpenFolder: (entry) => drive.openFolder(entry),
                    onOpenFile:
                        (entry) => showFilePreview(
                          context,
                          entry: entry,
                          drive: drive,
                          onOpenHistory:
                              () => _openHistory(context, drive, entry),
                        ),
                    onOpenHistory:
                        (entry) => _openHistory(context, drive, entry),
                    onRename: (entry) => _renameEntry(context, entry),
                    onMove: (entry) => _moveEntry(context, entry),
                    onDelete: (entry) => _confirmDelete(context, entry),
                  ),
                ),
              ),
            ],
          ),
          if (drive.uploading) const _UploadingOverlay(),
        ],
      ),
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'newFolder',
            onPressed: () => _createFolder(context),
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('Carpeta'),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            heroTag: 'ticket',
            onPressed: drive.uploading ? null : () => _captureTicket(context),
            icon: const Icon(Icons.camera_alt_outlined),
            label: const Text('Ticket'),
            backgroundColor: Colors.deepPurple,
            foregroundColor: Colors.white,
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            heroTag: 'upload',
            onPressed: drive.uploading ? null : () => _uploadFile(context),
            icon: const Icon(Icons.upload_file_outlined),
            label: const Text('Subir'),
          ),
        ],
      ),
    );
  }
}

/// Overlay a pantalla completa con un reloj de arena girando, para que la
/// espera durante una subida (ticket fotografiado o fichero) no parezca que
/// la app se ha quedado colgada. Bloquea la interacción con el resto de la
/// pantalla mientras dura.
class _UploadingOverlay extends StatefulWidget {
  const _UploadingOverlay();

  @override
  State<_UploadingOverlay> createState() => _UploadingOverlayState();
}

class _UploadingOverlayState extends State<_UploadingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.35),
        child: Center(
          child: Card(
            elevation: 6,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RotationTransition(
                    turns: _controller,
                    child: const Icon(
                      Icons.hourglass_bottom,
                      size: 40,
                      color: Colors.deepPurple,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text('Subiendo...'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Franja bajo el AppBar que responde a "¿dónde se están guardando mis
/// cambios ahora mismo?": modo demo vs. cuenta de GitHub real, y el
/// repositorio activo.
class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.auth, required this.drive});

  final AuthController auth;
  final DriveController drive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final repoName = drive.activeRepoName;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: 26,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            _StatusChip(
              icon:
                  auth.isDemoMode
                      ? Icons.science_outlined
                      : Icons.cloud_done_outlined,
              label: auth.isDemoMode ? 'Modo demo' : 'Conectado a GitHub',
              backgroundColor:
                  auth.isDemoMode
                      ? colors.tertiaryContainer
                      : colors.primaryContainer,
              foregroundColor:
                  auth.isDemoMode
                      ? colors.onTertiaryContainer
                      : colors.onPrimaryContainer,
            ),
            if (repoName != null) ...[
              const SizedBox(width: 8),
              _RepoSwitcherChip(
                drive: drive,
                repoName: repoName,
                username: auth.currentUser?.login,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Chip del repositorio activo, convertido en menú desplegable: permite
/// cambiar de "Drive" (p.ej. de "Tesorería" a "Facturas") sin salir de la
/// pantalla. Solo lista repositorios propios del usuario (públicos y
/// privados), tal y como los devuelve GitHub.
/// Opción elegida en el menú del chip de repositorio: cambiar a uno
/// existente, o abrir la gestión completa (crear / eliminar).
sealed class _RepoMenuChoice {
  const _RepoMenuChoice();
}

class _SwitchTo extends _RepoMenuChoice {
  const _SwitchTo(this.repo);
  final Repository repo;
}

class _OpenManage extends _RepoMenuChoice {
  const _OpenManage();
}

class _RepoSwitcherChip extends StatelessWidget {
  const _RepoSwitcherChip({
    required this.drive,
    required this.repoName,
    required this.username,
  });

  final DriveController drive;
  final String repoName;
  final String? username;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return PopupMenuButton<_RepoMenuChoice>(
      tooltip: 'Cambiar de repositorio',
      enabled: !drive.loading,
      onSelected: (choice) {
        switch (choice) {
          case _SwitchTo(:final repo):
            drive.switchRepo(repo);
          case _OpenManage():
            showDialog(
              context: context,
              builder:
                  (_) => _ManageReposDialog(drive: drive, username: username),
            );
        }
      },
      itemBuilder: (context) {
        final items = <PopupMenuEntry<_RepoMenuChoice>>[];

        if (drive.loadingRepos && drive.availableRepos.isEmpty) {
          items.add(
            const PopupMenuItem(
              enabled: false,
              child: SizedBox(
                height: 20,
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            ),
          );
        } else {
          for (final repo in drive.availableRepos) {
            items.add(
              PopupMenuItem(
                value: _SwitchTo(repo),
                child: Row(
                  children: [
                    Icon(
                      repo.isPrivate ? Icons.lock_outline : Icons.public,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(repo.name, overflow: TextOverflow.ellipsis),
                    ),
                    if (repo.name == repoName) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.check, size: 16, color: colors.primary),
                    ],
                  ],
                ),
              ),
            );
          }
        }

        items.add(const PopupMenuDivider());
        items.add(
          const PopupMenuItem(
            value: _OpenManage(),
            child: Row(
              children: [
                Icon(Icons.settings_outlined, size: 16),
                SizedBox(width: 8),
                Text('Gestionar repositorios...'),
              ],
            ),
          ),
        );

        return items;
      },
      child: _StatusChip(
        icon: Icons.storage_outlined,
        label: repoName,
        trailingIcon: Icons.arrow_drop_down,
        backgroundColor: colors.surfaceContainerHighest,
        foregroundColor: colors.onSurfaceVariant,
      ),
    );
  }
}

/// Diálogo de gestión de repositorios: crear uno nuevo o eliminar uno
/// existente. Eliminar es irreversible (borra ficheros e historial de
/// GitHub para siempre), así que exige escribir el nombre exacto del
/// repositorio antes de dejar pulsar "Eliminar" — igual que hace GitHub en
/// su propia web, para que no se pueda borrar de un toque accidental.
class _ManageReposDialog extends StatelessWidget {
  const _ManageReposDialog({required this.drive, required this.username});

  final DriveController drive;
  final String? username;

  /// Nombre final del repositorio a partir de lo que el usuario escriba en
  /// "Nombre del proyecto": lo convierte en un nombre válido para GitHub, o
  /// si lo deja en blanco (o no queda nada válido tras limpiarlo), genera
  /// uno inteligente a partir de su usuario y el año actual.
  String _resolveRepoName(String rawInput) {
    final slug = slugifyRepoName(rawInput);
    return slug.isNotEmpty ? slug : autoWorkspaceName(username);
  }

  Future<void> _create(BuildContext context) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder: (context, setState) {
              final preview = _resolveRepoName(controller.text);
              return AlertDialog(
                title: const Text('Nombre del proyecto'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: 'p. ej. Tesorería',
                      ),
                      onSubmitted: (v) => Navigator.of(context).pop(v),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Se creará como "$preview".',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancelar'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(controller.text),
                    child: const Text('Crear'),
                  ),
                ],
              );
            },
          ),
    );

    if (name == null) return;
    if (!context.mounted) return;

    final repoName = _resolveRepoName(name);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await drive.createRepo(repoName);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            describeError(e, fallback: 'No se pudo crear el repositorio.'),
          ),
        ),
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, Repository repo) async {
    final nameController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder: (context, setState) {
              final matches = nameController.text.trim() == repo.name;
              return AlertDialog(
                title: Text('Eliminar "${repo.name}"'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Esto borra el repositorio de GitHub para siempre: '
                      'todos los ficheros y su historial de versiones se '
                      'perderán. No se puede deshacer.',
                    ),
                    const SizedBox(height: 16),
                    Text('Escribe "${repo.name}" para confirmar:'),
                    const SizedBox(height: 8),
                    TextField(
                      controller: nameController,
                      autofocus: true,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancelar'),
                  ),
                  FilledButton(
                    onPressed:
                        matches ? () => Navigator.of(context).pop(true) : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    ),
                    child: const Text('Eliminar definitivamente'),
                  ),
                ],
              );
            },
          ),
    );

    if (confirmed != true) return;
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      await drive.deleteRepo(repo);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            describeError(e, fallback: 'No se pudo eliminar el repositorio.'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Tus repositorios'),
      content: SizedBox(
        width: 420,
        height: 360,
        child: ListenableBuilder(
          listenable: drive,
          builder: (context, _) {
            if (drive.loadingRepos && drive.availableRepos.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            if (drive.availableRepos.isEmpty) {
              return const Center(
                child: Text('Todavía no tienes ningún repositorio.'),
              );
            }
            return ListView.separated(
              itemCount: drive.availableRepos.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final repo = drive.availableRepos[index];
                return ListTile(
                  leading: Icon(
                    repo.isPrivate ? Icons.lock_outline : Icons.public,
                  ),
                  title: Text(repo.name),
                  trailing: IconButton(
                    tooltip: 'Eliminar',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _confirmDelete(context, repo),
                  ),
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () => _create(context),
          icon: const Icon(Icons.add),
          label: const Text('Nuevo repositorio'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
    this.trailingIcon,
  });

  final IconData icon;
  final String label;
  final Color backgroundColor;
  final Color foregroundColor;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: foregroundColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: foregroundColor),
          ),
          if (trailingIcon != null)
            Icon(trailingIcon, size: 16, color: foregroundColor),
        ],
      ),
    );
  }
}

/// Formulario de subida: elegir un archivo y describir, en una frase, qué
/// ha cambiado. Pensado para gente sin experiencia con control de
/// versiones: "motivo del cambio" en vez de "mensaje de commit". El campo
/// llega precargado con un mensaje automático ("Fulanito ha modificado
/// factura.pdf el 19 ago 2026"), pero se puede editar libremente antes de
/// subir.
class _UploadSheet extends StatefulWidget {
  const _UploadSheet({required this.userDisplayName});

  final String userDisplayName;

  @override
  State<_UploadSheet> createState() => _UploadSheetState();
}

class _UploadSheetState extends State<_UploadSheet> {
  final _messageController = TextEditingController();
  PlatformFile? _file;
  bool _picking = false;

  /// Último mensaje generado automáticamente, para saber si el usuario lo
  /// ha dejado tal cual (y así poder actualizarlo si cambia de fichero) o
  /// si lo ha editado a mano (y entonces no tocarlo).
  String _lastAutoMessage = '';

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  String _autoMessageFor(String fileName) {
    final date = DateFormat('d MMM y', 'es').format(DateTime.now());
    return '${widget.userDisplayName} ha modificado $fileName el $date';
  }

  Future<void> _pickFile() async {
    setState(() => _picking = true);
    try {
      final result = await FilePicker.pickFiles(withData: true);
      final picked = result?.files.single;
      if (picked == null) {
        // El usuario cerró el selector sin elegir nada: no es un error.
        return;
      }
      if (picked.bytes == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No se pudo leer el contenido de ese archivo.'),
            ),
          );
        }
        return;
      }
      setState(() {
        _file = picked;
        // Solo autorrellena si el usuario no ha escrito nada propio: si ya
        // hay texto que no es el mensaje automático anterior, se respeta.
        final currentText = _messageController.text.trim();
        if (currentText.isEmpty || currentText == _lastAutoMessage.trim()) {
          _lastAutoMessage = _autoMessageFor(picked.name);
          _messageController.text = _lastAutoMessage;
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              describeError(
                e,
                fallback: 'No se pudo abrir el selector de archivos.',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _submit() {
    final file = _file;
    if (file == null) return;
    Navigator.of(context).pop((file, _messageController.text.trim()));
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Subir fichero', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _picking ? null : _pickFile,
            icon: const Icon(Icons.attach_file),
            label: Text(
              _file == null ? 'Seleccionar archivo' : 'Cambiar archivo',
            ),
          ),
          if (_file != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  const Icon(Icons.insert_drive_file_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_file!.name, overflow: TextOverflow.ellipsis),
                  ),
                  Text(
                    _formatSize(_file!.size),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 20),
          TextField(
            controller: _messageController,
            decoration: const InputDecoration(
              labelText: '¿Qué cambios has realizado?',
              hintText: 'p. ej. Ajuste de IVA proveedor X',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancelar'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _file == null ? null : _submit,
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('Subir'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Selector [ 📄 Lista ] / [ 📊 Tablero ] para cambiar cómo se ven los
/// mismos ficheros: como explorador tradicional o como flujo de trabajo
/// por fases (Kanban).
class _ViewModeToggle extends StatelessWidget {
  const _ViewModeToggle({required this.drive});

  final DriveController drive;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<DriveViewMode>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
          value: DriveViewMode.list,
          icon: Icon(Icons.view_list_outlined),
        ),
        ButtonSegment(
          value: DriveViewMode.kanban,
          icon: Icon(Icons.view_column_outlined),
        ),
      ],
      selected: {drive.viewMode},
      onSelectionChanged: (selection) => drive.setViewMode(selection.first),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.drive});

  final DriveController drive;

  @override
  Widget build(BuildContext context) {
    final crumbs = drive.breadcrumbs;
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          TextButton.icon(
            onPressed: crumbs.isEmpty ? null : () => drive.goToBreadcrumb(-1),
            icon: const Icon(Icons.home_outlined, size: 18),
            label: const Text('Mi Drive'),
          ),
          for (var i = 0; i < crumbs.length; i++) ...[
            const Icon(Icons.chevron_right, size: 18),
            TextButton(
              onPressed:
                  i == crumbs.length - 1 ? null : () => drive.goToBreadcrumb(i),
              child: Text(crumbs[i]),
            ),
          ],
        ],
      ),
    );
  }
}

class _DriveBody extends StatelessWidget {
  const _DriveBody({
    required this.drive,
    required this.onOpenFolder,
    required this.onOpenFile,
    required this.onOpenHistory,
    required this.onRename,
    required this.onMove,
    required this.onDelete,
  });

  final DriveController drive;
  final ValueChanged<DriveEntry> onOpenFolder;
  final ValueChanged<DriveEntry> onOpenFile;
  final ValueChanged<DriveEntry> onOpenHistory;
  final ValueChanged<DriveEntry> onRename;
  final ValueChanged<DriveEntry> onMove;
  final ValueChanged<DriveEntry> onDelete;

  @override
  Widget build(BuildContext context) {
    if (drive.loading && drive.entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    // Solo tapamos la pantalla con el error de pantalla completa si además
    // no hay ninguna entrada que mostrar. Si la carga anterior sí trajo
    // contenido válido, un fallo puntual al recargar (p. ej. justo tras
    // subir un fichero) no debe hacerlo desaparecer de la vista.
    if (drive.error != null && drive.entries.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Icon(
            Icons.cloud_off_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(height: 12),
          Center(child: Text(drive.error!)),
        ],
      );
    }

    if (drive.entries.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 120),
          Icon(
            Icons.folder_open_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          const Center(child: Text('Esta carpeta está vacía')),
        ],
      );
    }

    if (drive.viewMode == DriveViewMode.kanban) {
      return _KanbanBoard(
        drive: drive,
        onOpenFolder: onOpenFolder,
        onOpenFile: onOpenFile,
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      itemCount: drive.entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = drive.entries[index];
        return ListTile(
          leading: CircleAvatar(child: Icon(iconForDriveEntry(entry))),
          title: Text(entry.name),
          subtitle:
              entry.isFolder
                  ? const Text('Carpeta')
                  : const Text('Toca para previsualizarlo'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ReviewStatusBadge(status: entry.status),
              const SizedBox(width: 4),
              PopupMenuButton<String>(
                onSelected: (value) {
                  switch (value) {
                    case 'history':
                      onOpenHistory(entry);
                    case 'rename':
                      onRename(entry);
                    case 'move':
                      onMove(entry);
                    case 'delete':
                      onDelete(entry);
                  }
                },
                itemBuilder:
                    (context) => [
                      if (!entry.isFolder)
                        const PopupMenuItem(
                          value: 'history',
                          child: Text('Ver historial'),
                        ),
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('Renombrar'),
                      ),
                      const PopupMenuItem(
                        value: 'move',
                        child: Text('Mover a...'),
                      ),
                      const PopupMenuDivider(),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Eliminar'),
                      ),
                    ],
              ),
            ],
          ),
          onTap: () => entry.isFolder ? onOpenFolder(entry) : onOpenFile(entry),
        );
      },
    );
  }
}

/// Vista de tablero: los mismos ficheros de la carpeta actual, agrupados
/// por fase en vez de en una lista. Tocar una tarjeta abre lo mismo que en
/// la lista (la carpeta, o el historial de versiones del fichero); mover
/// algo de "Pendiente de validación" a "Aprobado" se hace con el mismo
/// botón "Aprobar y consolidar" que ya existe ahí, no hay arrastrar y
/// soltar.
class _KanbanBoard extends StatelessWidget {
  const _KanbanBoard({
    required this.drive,
    required this.onOpenFolder,
    required this.onOpenFile,
  });

  final DriveController drive;
  final ValueChanged<DriveEntry> onOpenFolder;
  final ValueChanged<DriveEntry> onOpenFile;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final inReview =
        drive.entries.where((e) => e.status == ReviewStatus.inReview).toList();
    final validated =
        drive.entries.where((e) => e.status == ReviewStatus.validated).toList();

    void openEntry(DriveEntry entry) =>
        entry.isFolder ? onOpenFolder(entry) : onOpenFile(entry);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KanbanColumn(
            title: 'En preparación',
            icon: Icons.edit_note_outlined,
            accentColor: colors.outline,
            entries: const [],
            emptyHint:
                'Todavía no hay un paso de borrador separado: cada subida '
                'entra directamente en "Pendiente de validación".',
            onTap: openEntry,
          ),
          const SizedBox(width: 16),
          _KanbanColumn(
            title: 'Pendiente de validación',
            icon: Icons.hourglass_top_outlined,
            accentColor: const Color(0xFF8A5A00),
            entries: inReview,
            emptyHint: 'No hay nada pendiente de aprobar ahora mismo.',
            onTap: openEntry,
          ),
          const SizedBox(width: 16),
          _KanbanColumn(
            title: 'Aprobado',
            icon: Icons.verified_outlined,
            accentColor: const Color(0xFF1B7A3D),
            entries: validated,
            emptyHint: 'Todavía no hay nada aprobado en esta carpeta.',
            onTap: openEntry,
          ),
        ],
      ),
    );
  }
}

class _KanbanColumn extends StatelessWidget {
  const _KanbanColumn({
    required this.title,
    required this.icon,
    required this.accentColor,
    required this.entries,
    required this.emptyHint,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final Color accentColor;
  final List<DriveEntry> entries;
  final String emptyHint;
  final ValueChanged<DriveEntry> onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 280,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: accentColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(color: accentColor),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${entries.length}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (entries.isEmpty)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                emptyHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else
            ...entries.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _KanbanCard(entry: entry, onTap: () => onTap(entry)),
              ),
            ),
        ],
      ),
    );
  }
}

class _KanbanCard extends StatelessWidget {
  const _KanbanCard({required this.entry, required this.onTap});

  final DriveEntry entry;
  final VoidCallback onTap;

  bool get _isTicket => entry.name.startsWith(_ticketFilePrefix);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    iconForDriveEntry(entry),
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(entry.name, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              if (_isTicket) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.deepPurple.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    '[Ticket]',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.deepPurple,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
