import 'dart:convert';

import 'package:github/github.dart';

import '../config/github_config.dart';
import '../models/drive_entry.dart';
import '../models/file_version.dart';

/// Convierte el repositorio privado del usuario en un "Drive": expone
/// operaciones de fichero/carpeta simples por encima de la API de GitHub,
/// para que el resto de la app nunca tenga que hablar en términos de Git.
class DriveService {
  DriveService(this._github);

  final GitHub _github;
  RepositorySlug? _slug;

  RepositorySlug get slug {
    final s = _slug;
    if (s == null) {
      throw StateError('El repositorio del Drive todavía no está listo.');
    }
    return s;
  }

  /// Nombre del repositorio activo, o `null` si `ensureDriveRepo` todavía
  /// no ha terminado. Pensado para mostrar contexto en la interfaz sin
  /// arriesgarse a lanzar una excepción.
  String? get repoName => _slug?.name;

  /// Busca el repositorio de datos del usuario y lo crea si es la primera
  /// vez que conecta su cuenta.
  Future<RepositorySlug> ensureDriveRepo(String ownerLogin) async {
    final candidate = RepositorySlug(ownerLogin, GitHubConfig.driveRepoName);
    try {
      final repo = await _github.repositories.getRepository(candidate);
      _slug = RepositorySlug.full(repo.fullName);
    } on RepositoryNotFound {
      final created = await _github.repositories.createRepository(
        CreateRepository(
          GitHubConfig.driveRepoName,
          description:
              'Almacén de datos de Versiona. No lo edites manualmente.',
          private: true,
          autoInit: true,
          hasIssues: false,
          hasWiki: false,
        ),
      );
      _slug = RepositorySlug.full(created.fullName);
    }
    return _slug!;
  }

  String _joinPath(String folderPath, String name) =>
      folderPath.isEmpty ? name : '$folderPath/$name';

  /// Lista el contenido (ficheros y carpetas) de [folderPath].
  /// Usa cadena vacía para la raíz del Drive.
  Future<List<DriveEntry>> listFolder(String folderPath) async {
    final contents = await _github.repositories.getContents(
      slug,
      folderPath,
    );

    if (contents.isFile) {
      return const [];
    }

    final entries = (contents.tree ?? [])
        .where((f) => f.name != GitHubConfig.folderKeepFile)
        .map(DriveEntry.fromGitHubFile)
        .toList();

    entries.sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return entries;
  }

  /// Sube (crea o actualiza) un fichero dentro de [folderPath].
  ///
  /// [commitMessage] es el motivo del cambio que ve el usuario (p.ej. "Ajuste
  /// de IVA proveedor X"). Si se omite o queda vacío, se usa un mensaje
  /// genérico.
  Future<void> uploadFile({
    required String folderPath,
    required String fileName,
    required List<int> bytes,
    String? commitMessage,
  }) async {
    final path = _joinPath(folderPath, fileName);
    final content = base64Encode(bytes);

    GitHubFile? existing;
    try {
      final current = await _github.repositories.getContents(slug, path);
      existing = current.isFile ? current.file : null;
    } on NotFound {
      existing = null;
    }

    final hasCustomMessage =
        commitMessage != null && commitMessage.trim().isNotEmpty;

    if (existing?.sha != null) {
      await _github.repositories.updateFile(
        slug,
        path,
        hasCustomMessage ? commitMessage.trim() : 'Actualizar $fileName',
        content,
        existing!.sha!,
      );
    } else {
      await _github.repositories.createFile(
        slug,
        CreateFile(
          path: path,
          content: content,
          message: hasCustomMessage ? commitMessage.trim() : 'Subir $fileName',
        ),
      );
    }
  }

  /// Crea una carpeta vacía mediante un fichero "placeholder" invisible
  /// para el usuario (Git no versiona directorios vacíos).
  Future<void> createFolder({
    required String folderPath,
    required String name,
  }) async {
    final placeholderPath =
        _joinPath(_joinPath(folderPath, name), GitHubConfig.folderKeepFile);
    await _github.repositories.createFile(
      slug,
      CreateFile(
        path: placeholderPath,
        content: base64Encode(utf8.encode(
          'Este fichero mantiene la carpeta "$name" en Versiona.\n',
        )),
        message: 'Crear carpeta $name',
      ),
    );
  }

  /// Elimina un fichero, o una carpeta entera (y todo su contenido).
  Future<void> deleteEntry(DriveEntry entry) async {
    if (!entry.isFolder) {
      await _github.repositories.deleteFile(
        slug,
        entry.path,
        'Eliminar ${entry.name}',
        entry.sha!,
        '',
      );
      return;
    }

    final files = await _collectFilesRecursively(entry.path);
    for (final file in files) {
      await _github.repositories.deleteFile(
        slug,
        file.path!,
        'Eliminar carpeta ${entry.name}',
        file.sha!,
        '',
      );
    }
  }

  Future<List<GitHubFile>> _collectFilesRecursively(String path) async {
    final contents = await _github.repositories.getContents(slug, path);
    if (contents.isFile) {
      return contents.file != null ? [contents.file!] : [];
    }

    final result = <GitHubFile>[];
    for (final entry in contents.tree ?? <GitHubFile>[]) {
      if (entry.type == 'dir') {
        result.addAll(await _collectFilesRecursively(entry.path!));
      } else {
        result.add(entry);
      }
    }
    return result;
  }

  /// Historial de versiones (commits) que han afectado a [path], del más
  /// reciente al más antiguo.
  Future<List<FileVersion>> fileHistory(String path) async {
    final commits =
        await _github.repositories.listCommits(slug, path: path).toList();
    return commits.map(FileVersion.fromCommit).toList();
  }

  /// Restaura el contenido de [path] tal y como estaba en la versión
  /// [versionSha], creando una nueva versión (nunca se reescribe historial).
  Future<void> restoreVersion({
    required String path,
    required String versionSha,
    required String fileName,
  }) async {
    final oldContents = await _github.repositories.getContents(
      slug,
      path,
      ref: versionSha,
    );
    final oldFile = oldContents.file;
    if (oldFile?.content == null) {
      throw StateError('No se pudo leer esa versión del fichero.');
    }

    final current = await _github.repositories.getContents(slug, path);
    final currentSha = current.file?.sha;
    if (currentSha == null) {
      throw StateError('El fichero ya no existe en su ubicación actual.');
    }

    final rawContent = oldFile!.content!.replaceAll('\n', '');
    await _github.repositories.updateFile(
      slug,
      path,
      'Restaurar $fileName a una versión anterior',
      rawContent,
      currentSha,
    );
  }

  /// Enlace a la vista de GitHub para inspeccionar un fichero en detalle.
  String webUrlFor(String path) =>
      'https://github.com/${slug.fullName}/blob/HEAD/$path';

  String _parentPath(String path) {
    final index = path.lastIndexOf('/');
    return index == -1 ? '' : path.substring(0, index);
  }

  /// Cambia el nombre de [entry] manteniéndolo en la misma carpeta.
  Future<void> rename({
    required DriveEntry entry,
    required String newName,
  }) async {
    final newPath = _joinPath(_parentPath(entry.path), newName);
    await _movePath(entry: entry, newPath: newPath);
  }

  /// Mueve [entry] a la carpeta [destinationFolderPath] (cadena vacía para
  /// la raíz), conservando su nombre.
  Future<void> move({
    required DriveEntry entry,
    required String destinationFolderPath,
  }) async {
    if (entry.isFolder &&
        (destinationFolderPath == entry.path ||
            destinationFolderPath.startsWith('${entry.path}/'))) {
      throw StateError('No puedes mover una carpeta dentro de sí misma.');
    }

    final newPath = _joinPath(destinationFolderPath, entry.name);
    await _movePath(entry: entry, newPath: newPath);
  }

  /// Mueve/renombra [entry] a [newPath], recorriendo recursivamente su
  /// contenido si es una carpeta. GitHub no tiene una operación nativa de
  /// mover: se recrea cada fichero en la ruta nueva y se borra el original.
  Future<void> _movePath({
    required DriveEntry entry,
    required String newPath,
  }) async {
    if (newPath == entry.path) return;

    if (!entry.isFolder) {
      final current = await _github.repositories.getContents(slug, entry.path);
      final file = current.file;
      if (file?.content == null || file?.sha == null) {
        throw StateError('No se pudo leer el fichero.');
      }
      await _github.repositories.createFile(
        slug,
        CreateFile(
          path: newPath,
          content: file!.content!.replaceAll('\n', ''),
          message: 'Mover ${entry.name}',
        ),
      );
      await _github.repositories.deleteFile(
        slug,
        entry.path,
        'Mover ${entry.name}',
        file.sha!,
        '',
      );
      return;
    }

    final files = await _collectFilesRecursively(entry.path);
    final basePath = entry.path;
    final pendingCreations = <MapEntry<String, String>>[];

    for (final file in files) {
      final relative = file.path!.substring(basePath.length + 1);
      final destinationPath = '$newPath/$relative';
      final contents = await _github.repositories.getContents(
        slug,
        file.path!,
      );
      final content = contents.file?.content;
      if (content == null) continue;
      pendingCreations.add(
        MapEntry(destinationPath, content.replaceAll('\n', '')),
      );
    }

    // Primero se crean todas las copias nuevas y solo después se borran los
    // originales, para no perder datos si algo falla a mitad de camino.
    for (final creation in pendingCreations) {
      await _github.repositories.createFile(
        slug,
        CreateFile(
          path: creation.key,
          content: creation.value,
          message: 'Mover ${entry.name}',
        ),
      );
    }
    for (final file in files) {
      await _github.repositories.deleteFile(
        slug,
        file.path!,
        'Mover ${entry.name}',
        file.sha!,
        '',
      );
    }
  }
}
