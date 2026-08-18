import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/drive_entry.dart';
import '../state/auth_controller.dart';
import '../state/drive_controller.dart';
import '../utils/error_messages.dart';
import '../widgets/review_status_badge.dart';
import 'folder_picker_screen.dart';
import 'version_history_screen.dart';

class DriveScreen extends StatelessWidget {
  const DriveScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create:
          (context) =>
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
          child: _StatusBar(auth: auth),
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
      body: Column(
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
                    (entry) => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder:
                            (_) => ChangeNotifierProvider.value(
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
      setState(() => _file = picked);
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

/// Icono representativo de un fichero (según su extensión) o carpeta.
/// Compartido entre la vista de lista y la de tablero.
IconData iconForDriveEntry(DriveEntry entry) {
  if (entry.isFolder) return Icons.folder_outlined;
  final ext =
      entry.name.contains('.') ? entry.name.split('.').last.toLowerCase() : '';
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
                  : const Text('Toca para ver el historial de versiones'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ReviewStatusBadge(status: entry.status),
              const SizedBox(width: 4),
              PopupMenuButton<String>(
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
                itemBuilder:
                    (context) => const [
                      PopupMenuItem(value: 'rename', child: Text('Renombrar')),
                      PopupMenuItem(value: 'move', child: Text('Mover a...')),
                      PopupMenuDivider(),
                      PopupMenuItem(value: 'delete', child: Text('Eliminar')),
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

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
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
        ),
      ),
    );
  }
}
