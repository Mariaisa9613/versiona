import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/drive_entry.dart';
import '../services/drive_service.dart';
import '../state/auth_controller.dart';
import '../utils/error_messages.dart';

/// Selector de carpeta destino para mover un fichero o carpeta.
///
/// Devuelve (vía [Navigator.pop]) la ruta de la carpeta elegida, o `null`
/// si el usuario cancela.
class FolderPickerScreen extends StatefulWidget {
  const FolderPickerScreen({
    super.key,
    required this.entryName,
    this.excludePath,
  });

  /// Nombre del elemento que se está moviendo (solo para el título).
  final String entryName;

  /// Ruta a excluir de la navegación: la propia carpeta que se mueve, para
  /// no poder moverla dentro de sí misma.
  final String? excludePath;

  @override
  State<FolderPickerScreen> createState() => _FolderPickerScreenState();
}

class _FolderPickerScreenState extends State<FolderPickerScreen> {
  late final DriveService _service;
  List<String> _pathSegments = [];
  List<DriveEntry> _folders = [];
  bool _loading = true;
  String? _error;

  String get _currentPath => _pathSegments.join('/');

  @override
  void initState() {
    super.initState();
    _service = context.read<AuthController>().driveService!;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _service.listFolder(_currentPath);
      setState(() {
        _folders =
            entries
                .where((e) => e.isFolder && e.path != widget.excludePath)
                .toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = describeError(
          e,
          fallback: 'No se pudo cargar el contenido de esta carpeta.',
        );
        _loading = false;
      });
    }
  }

  void _open(DriveEntry folder) {
    setState(() => _pathSegments = [..._pathSegments, folder.name]);
    _load();
  }

  void _goToBreadcrumb(int index) {
    setState(
      () =>
          _pathSegments = index < 0 ? [] : _pathSegments.sublist(0, index + 1),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final crumbs = _pathSegments;

    return Scaffold(
      appBar: AppBar(title: Text('Mover "${widget.entryName}"')),
      body: Column(
        children: [
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                TextButton.icon(
                  onPressed: crumbs.isEmpty ? null : () => _goToBreadcrumb(-1),
                  icon: const Icon(Icons.home_outlined, size: 18),
                  label: const Text('Mi Drive'),
                ),
                for (var i = 0; i < crumbs.length; i++) ...[
                  const Icon(Icons.chevron_right, size: 18),
                  TextButton(
                    onPressed:
                        i == crumbs.length - 1
                            ? null
                            : () => _goToBreadcrumb(i),
                    child: Text(crumbs[i]),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildBody()),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(_currentPath),
            icon: const Icon(Icons.drive_file_move_outlined),
            label: Text(
              _currentPath.isEmpty
                  ? 'Mover aquí (Mi Drive)'
                  : 'Mover aquí (${crumbs.last})',
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_folders.isEmpty) {
      return const Center(child: Text('No hay carpetas aquí'));
    }
    return ListView.separated(
      itemCount: _folders.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final folder = _folders[index];
        return ListTile(
          leading: const CircleAvatar(child: Icon(Icons.folder_outlined)),
          title: Text(folder.name),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(folder),
        );
      },
    );
  }
}
