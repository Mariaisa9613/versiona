import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/drive_entry.dart';
import '../state/auth_controller.dart';
import '../state/drive_controller.dart';
import 'folder_picker_screen.dart';
import 'version_history_screen.dart';

class DriveScreen extends StatelessWidget {
  const DriveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) =>
          DriveController(context.read<AuthController>().driveService!)
            ..load(),
      child: const _DriveView(),
    );
  }
}

class _DriveView extends StatelessWidget {
  const _DriveView();

  Future<void> _uploadFile(BuildContext context) async {
    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);

    final result = await showModalBottomSheet<(PlatformFile, String)>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _UploadSheet(),
    );
    if (result == null) return;

    final (file, message) = result;
    if (file.bytes == null) return;

    try {
      await drive.uploadFile(file.name, file.bytes!, commitMessage: message);
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo subir el fichero.')),
      );
    }
  }

  Future<void> _createFolder(BuildContext context) async {
    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nueva carpeta'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Nombre de la carpeta'),
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
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo crear la carpeta.')),
      );
    }
  }

  Future<void> _renameEntry(BuildContext context, DriveEntry entry) async {
    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);
    final controller = TextEditingController(text: entry.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
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
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo renombrar.')),
      );
    }
  }

  Future<void> _moveEntry(BuildContext context, DriveEntry entry) async {
    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);

    final destination = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => FolderPickerScreen(
          entryName: entry.name,
          excludePath: entry.isFolder ? entry.path : null,
        ),
      ),
    );
    if (destination == null) return;

    try {
      await drive.move(entry, destination);
    } catch (e) {
      final message =
          e is StateError ? e.message : 'No se pudo mover.';
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _confirmDelete(BuildContext context, DriveEntry entry) async {
    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo eliminar.')),
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
          child: _StatusBar(auth: auth),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: CircleAvatar(
              radius: 16,
              backgroundImage: auth.currentUser?.avatarUrl != null
                  ? NetworkImage(auth.currentUser!.avatarUrl!)
                  : null,
              child: auth.currentUser?.avatarUrl == null
                  ? const Icon(Icons.person, size: 18)
                  : null,
            ),
            onSelected: (value) {
              if (value == 'signOut') auth.signOut();
            },
            itemBuilder: (context) => [
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
      body: Column(
        children: [
          _Breadcrumbs(drive: drive),
          const Divider(height: 1),
          Expanded(
            child: RefreshIndicator(
              onRefresh: drive.load,
              child: _DriveBody(
                drive: drive,
                onOpenFolder: (entry) => drive.openFolder(entry),
                onOpenFile: (entry) => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChangeNotifierProvider.value(
                      value: drive,
                      child: VersionHistoryScreen(entry: entry),
                    ),
                  ),
                ),
                onRename: (entry) => _renameEntry(context, entry),
                onMove: (entry) => _moveEntry(context, entry),
                onDelete: (entry) => _confirmDelete(context, entry),
              ),
            ),
          ),
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
            heroTag: 'upload',
            onPressed: () => _uploadFile(context),
            icon: const Icon(Icons.upload_file_outlined),
            label: const Text('Subir'),
          ),
        ],
      ),
    );
  }
}

/// Franja bajo el AppBar que responde a "¿dónde se están guardando mis
/// cambios ahora mismo?": modo demo vs. cuenta de GitHub real, y el
/// repositorio activo.
class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.auth});

  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final repoName = auth.activeRepoName;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: 26,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            _StatusChip(
              icon: auth.isDemoMode
                  ? Icons.science_outlined
                  : Icons.cloud_done_outlined,
              label: auth.isDemoMode ? 'Modo demo' : 'Conectado a GitHub',
              backgroundColor:
                  auth.isDemoMode ? colors.tertiaryContainer : colors.primaryContainer,
              foregroundColor: auth.isDemoMode
                  ? colors.onTertiaryContainer
                  : colors.onPrimaryContainer,
            ),
            if (repoName != null) ...[
              const SizedBox(width: 8),
              _StatusChip(
                icon: Icons.storage_outlined,
                label: repoName,
                backgroundColor: colors.surfaceContainerHighest,
                foregroundColor: colors.onSurfaceVariant,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final IconData icon;
  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

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
        ],
      ),
    );
  }
}

/// Formulario de subida: elegir un archivo y describir, en una frase, qué
/// ha cambiado. Pensado para gente sin experiencia con control de
/// versiones: "motivo del cambio" en vez de "mensaje de commit".
class _UploadSheet extends StatefulWidget {
  const _UploadSheet();

  @override
  State<_UploadSheet> createState() => _UploadSheetState();
}

class _UploadSheetState extends State<_UploadSheet> {
  final _messageController = TextEditingController();
  PlatformFile? _file;
  bool _picking = false;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    setState(() => _picking = true);
    try {
      final result = await FilePicker.pickFiles(withData: true);
      final picked = result?.files.single;
      if (picked != null && picked.bytes != null) {
        setState(() => _file = picked);
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
                    child: Text(
                      _file!.name,
                      overflow: TextOverflow.ellipsis,
                    ),
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
    required this.onRename,
    required this.onMove,
    required this.onDelete,
  });

  final DriveController drive;
  final ValueChanged<DriveEntry> onOpenFolder;
  final ValueChanged<DriveEntry> onOpenFile;
  final ValueChanged<DriveEntry> onRename;
  final ValueChanged<DriveEntry> onMove;
  final ValueChanged<DriveEntry> onDelete;

  IconData _iconFor(DriveEntry entry) {
    if (entry.isFolder) return Icons.folder_outlined;
    final ext = entry.name.contains('.')
        ? entry.name.split('.').last.toLowerCase()
        : '';
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'doc':
      case 'docx':
        return Icons.description_outlined;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart_outlined;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
        return Icons.image_outlined;
      case 'zip':
      case 'rar':
        return Icons.folder_zip_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (drive.loading && drive.entries.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (drive.error != null) {
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

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      itemCount: drive.entries.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = drive.entries[index];
        return ListTile(
          leading: CircleAvatar(child: Icon(_iconFor(entry))),
          title: Text(entry.name),
          subtitle: entry.isFolder
              ? const Text('Carpeta')
              : const Text('Toca para ver el historial de versiones'),
          trailing: PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'rename':
                  onRename(entry);
                case 'move':
                  onMove(entry);
                case 'delete':
                  onDelete(entry);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('Renombrar')),
              PopupMenuItem(value: 'move', child: Text('Mover a...')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'delete', child: Text('Eliminar')),
            ],
          ),
          onTap: () =>
              entry.isFolder ? onOpenFolder(entry) : onOpenFile(entry),
        );
      },
    );
  }
}
