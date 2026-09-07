import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/drive_entry.dart';
import '../models/file_version.dart';
import '../state/drive_controller.dart';
import '../utils/error_messages.dart';
import '../widgets/review_status_badge.dart';

class VersionHistoryScreen extends StatefulWidget {
  const VersionHistoryScreen({super.key, required this.entry});

  final DriveEntry entry;

  @override
  State<VersionHistoryScreen> createState() => _VersionHistoryScreenState();
}

class _VersionHistoryScreenState extends State<VersionHistoryScreen> {
  late Future<List<FileVersion>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = context.read<DriveController>().fileHistory(widget.entry);
  }

  Future<void> _restore(FileVersion version) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Restaurar esta versión'),
            content: Text(
              'Se creará una nueva versión de "${widget.entry.name}" con el '
              'contenido de esta. El historial actual se conserva.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Restaurar'),
              ),
            ],
          ),
    );

    if (confirmed != true || !mounted) return;

    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await drive.restoreVersion(widget.entry, version);
      if (!mounted) return;
      setState(_load);
      messenger.showSnackBar(
        const SnackBar(content: Text('Versión restaurada')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            describeError(e, fallback: 'No se pudo restaurar la versión.'),
          ),
        ),
      );
    }
  }

  /// Aprueba el cambio pendiente de **este** fichero, sin tocar el resto de
  /// cambios que haya en el espacio: cada uno vive en su propia rama.
  Future<void> _approveChange() async {
    final change = widget.entry.pendingChange;
    if (change == null) return;

    final summaryController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Aprobar cambios'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Se aprobarán los cambios de "${widget.entry.name}" y '
                  'pasarán a ser la versión oficial. El resto de cambios '
                  'pendientes se quedan como están.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: summaryController,
                  decoration: const InputDecoration(
                    labelText: 'Resumen de la aprobación (opcional)',
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
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Aprobar'),
              ),
            ],
          ),
    );

    if (confirmed != true || !mounted) return;

    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      final results = await drive.approveChanges(
        [change],
        summary: summaryController.text,
      );
      if (!mounted) return;
      // Al aprobar una carpeta viene un resultado por cada fichero de
      // dentro, así que lo que interesa es si alguno ha fallado.
      final failure = results.where((r) => !r.ok).firstOrNull;
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            failure == null
                ? 'Cambios aprobados'
                : 'No se pudo aprobar: ${failure.error}',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            describeError(e, fallback: 'No se pudo aprobar los cambios.'),
          ),
        ),
      );
    }
  }

  Future<void> _rejectChanges() async {
    final change = widget.entry.pendingChange;
    if (change == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Rechazar cambios'),
            content: Text(
              'Se descartarán TODOS los cambios pendientes de '
              '"${widget.entry.name}" desde la última aprobación: volverá a '
              'como estaba entonces, o desaparecerá si nunca llegó a '
              'aprobarse. Esto no afecta a otros ficheros, y no se puede '
              'deshacer.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                ),
                child: const Text('Rechazar'),
              ),
            ],
          ),
    );

    if (confirmed != true || !mounted) return;

    final drive = context.read<DriveController>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      final results = await drive.rejectChanges([change]);
      if (!mounted) return;
      final failure = results.where((r) => !r.ok).firstOrNull;
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            failure == null
                ? 'Cambios rechazados'
                : 'No se pudo rechazar: ${failure.error}',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            describeError(e, fallback: 'No se pudo rechazar el cambio.'),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final drive = context.read<DriveController>();
    final isInReview = widget.entry.status == ReviewStatus.inReview;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry.name),
        actions: [
          IconButton(
            tooltip: 'Ver en GitHub',
            icon: const Icon(Icons.open_in_new),
            onPressed:
                () => launchUrl(
                  Uri.parse(drive.webUrlFor(widget.entry)),
                  mode: LaunchMode.externalApplication,
                ),
          ),
        ],
      ),
      bottomNavigationBar:
          isInReview
              ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton.icon(
                        onPressed: _approveChange,
                        icon: const Icon(Icons.task_alt),
                        label: const Text('Aprobar estos cambios'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          backgroundColor: const Color(0xFF1B7A3D),
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: _rejectChanges,
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('Rechazar'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                          foregroundColor: Colors.red.shade700,
                          side: BorderSide(color: Colors.red.shade700),
                        ),
                      ),
                    ],
                  ),
                ),
              )
              : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ReviewStatusBadge(pendingChange: widget.entry.pendingChange),
            ),
          ),
          Expanded(child: _buildVersionList()),
        ],
      ),
    );
  }

  Widget _buildVersionList() {
    return FutureBuilder<List<FileVersion>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const Center(
            child: Text('No se pudo cargar el historial de versiones.'),
          );
        }

        final versions = snapshot.data ?? const [];
        if (versions.isEmpty) {
          return const Center(child: Text('Sin versiones todavía.'));
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: versions.length,
          itemBuilder: (context, index) {
            final version = versions[index];
            final isLatest = index == 0;
            // El historial llega del más reciente al más antiguo; se
            // numera al revés para que la v1 sea siempre la primera
            // versión que existió del fichero.
            final versionNumber = versions.length - index;

            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Column(
                    children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor:
                            isLatest
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                        backgroundImage:
                            version.authorAvatarUrl != null
                                ? NetworkImage(version.authorAvatarUrl!)
                                : null,
                        child:
                            version.authorAvatarUrl == null
                                ? Icon(
                                  Icons.person,
                                  size: 14,
                                  color:
                                      isLatest
                                          ? Theme.of(
                                            context,
                                          ).colorScheme.onPrimary
                                          : Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                )
                                : null,
                      ),
                      if (index != versions.length - 1)
                        Container(
                          width: 2,
                          height: 56,
                          color: Theme.of(context).colorScheme.outlineVariant,
                        ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  'Versión $versionNumber',
                                  style: Theme.of(context).textTheme.labelLarge
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                                if (isLatest) ...[
                                  const SizedBox(width: 8),
                                  Chip(
                                    label: const Text('Actual'),
                                    visualDensity: VisualDensity.compact,
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                ],
                                const Spacer(),
                                Text(
                                  _formatDate(version.date),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              version.message,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(
                                  Icons.person_outline,
                                  size: 16,
                                  color:
                                      Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    version.authorName,
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ),
                                if (!isLatest)
                                  TextButton.icon(
                                    onPressed: () => _restore(version),
                                    icon: const Icon(Icons.restore, size: 18),
                                    label: const Text('Restaurar'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'Fecha desconocida';
    return DateFormat('d MMM y, HH:mm', 'es').format(date.toLocal());
  }
}
