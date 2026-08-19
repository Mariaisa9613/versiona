import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:github/github.dart';

import '../config/github_config.dart';
import '../models/drive_entry.dart';
import '../models/file_version.dart';

/// Convierte el repositorio privado del usuario en un "Drive": expone
/// operaciones de fichero/carpeta simples por encima de la API de GitHub,
/// para que el resto de la app nunca tenga que hablar en términos de Git.
///
/// Todos los cambios (subir, crear carpeta, borrar, renombrar, mover,
/// restaurar) se escriben en la rama de revisión
/// ([GitHubConfig.reviewBranchName]), nunca directamente en la rama
/// validada. Un fichero está "Validado" cuando su contenido en la rama de
/// revisión coincide con el de la rama validada; en caso contrario está
/// "En revisión" hasta que alguien apruebe los cambios, lo que fusiona la
/// rama de revisión sobre la validada con un commit de fusión real.
class DriveService {
  DriveService(this._github);

  final GitHub _github;
  RepositorySlug? _slug;
  String? _defaultBranch;

  static const String _workingBranch = GitHubConfig.reviewBranchName;

  /// Prefijo con el que Versiona marca la descripción de cada repositorio
  /// que crea, para poder reconocerlos entre el resto de repos del usuario
  /// (y así no confundir uno de sus proyectos con un espacio de Versiona).
  static const String _workspaceMarker = '[Versiona]';

  RepositorySlug get slug {
    final s = _slug;
    if (s == null) {
      throw StateError('El repositorio del Drive todavía no está listo.');
    }
    return s;
  }

  String get _validatedBranch {
    final b = _defaultBranch;
    if (b == null) {
      throw StateError('El repositorio del Drive todavía no está listo.');
    }
    return b;
  }

  /// Nombre del repositorio activo, o `null` si `ensureDriveRepo` todavía
  /// no ha terminado. Pensado para mostrar contexto en la interfaz sin
  /// arriesgarse a lanzar una excepción.
  String? get repoName => _slug?.name;

  /// Busca el repositorio de datos del usuario y lo crea si es la primera
  /// vez que conecta su cuenta. También garantiza que exista la rama de
  /// revisión donde se escriben todos los cambios pendientes de aprobar.
  Future<RepositorySlug> ensureDriveRepo(String ownerLogin) async {
    final candidate = RepositorySlug(ownerLogin, GitHubConfig.driveRepoName);
    Repository repo;
    try {
      repo = await _github.repositories.getRepository(candidate);
    } on RepositoryNotFound {
      repo = await _github.repositories.createRepository(
        CreateRepository(
          GitHubConfig.driveRepoName,
          description:
              '$_workspaceMarker Almacén de datos de Versiona. No lo '
              'edites manualmente.',
          private: true,
          autoInit: true,
          hasIssues: false,
          hasWiki: false,
        ),
      );
    }
    _slug = RepositorySlug.full(repo.fullName);
    _defaultBranch =
        repo.defaultBranch.isNotEmpty ? repo.defaultBranch : 'main';
    await _ensureReviewBranch();
    return _slug!;
  }

  /// Cambia el Drive activo a un repositorio ya existente (elegido por el
  /// usuario entre los suyos), asegurando que también tenga la rama de
  /// revisión antes de empezar a usarlo.
  Future<void> switchTo(RepositorySlug slug) async {
    if (_slug == slug) return;
    final repo = await _github.repositories.getRepository(slug);
    _slug = RepositorySlug.full(repo.fullName);
    _defaultBranch =
        repo.defaultBranch.isNotEmpty ? repo.defaultBranch : 'main';
    await _ensureReviewBranch();
  }

  /// Repositorios (públicos y privados) del usuario entre los que puede
  /// elegir como Drive activo, ordenados alfabéticamente.
  Future<List<Repository>> listAccessibleRepos() =>
      _github.repositories.listRepositories(type: 'owner').toList();

  /// Busca, entre los repositorios del usuario, uno ya creado por Versiona
  /// anteriormente: por la marca en su descripción, o por el nombre fijo
  /// que usaban las versiones antiguas de la app ([GitHubConfig.driveRepoName])
  /// antes de que se pudiera elegir nombre — para no dejar huérfano el
  /// espacio de quien ya usaba la app. Se usa al conectar una cuenta para
  /// saber si hay que reanudar un espacio ya existente o si es la primera
  /// vez y hace falta crear uno, sin arriesgarse nunca a confundir uno de
  /// los proyectos propios del usuario con un espacio de Versiona.
  Future<Repository?> findWorkspace() async {
    final repos = await listAccessibleRepos();
    for (final repo in repos) {
      if (repo.description.startsWith(_workspaceMarker) ||
          repo.name == GitHubConfig.driveRepoName) {
        return repo;
      }
    }
    return null;
  }

  /// Crea un nuevo repositorio privado vacío (con su propia rama de
  /// revisión) y lo deja como Drive activo. Su descripción queda marcada
  /// para que [findWorkspace] pueda reconocerlo más adelante.
  Future<void> createRepo(String name) async {
    final repo = await _github.repositories.createRepository(
      CreateRepository(
        name,
        description: '$_workspaceMarker Espacio de datos de Versiona.',
        private: true,
        autoInit: true,
        hasIssues: false,
        hasWiki: false,
      ),
    );
    _slug = RepositorySlug.full(repo.fullName);
    _defaultBranch =
        repo.defaultBranch.isNotEmpty ? repo.defaultBranch : 'main';
    await _ensureReviewBranch();
  }

  /// Elimina un repositorio de GitHub de forma permanente e irreversible
  /// (ficheros e historial incluidos). Requiere que el token tenga el
  /// scope `delete_repo`. Quien llame a esto debe haber confirmado ya
  /// explícitamente con el usuario: no hay marcha atrás.
  Future<void> deleteRepo(RepositorySlug target) async {
    await _github.repositories.deleteRepository(target);
  }

  Future<void> _ensureReviewBranch() async {
    try {
      await _github.git.getReference(slug, 'heads/$_workingBranch');
    } on NotFound {
      final base = await _github.git.getReference(
        slug,
        'heads/$_validatedBranch',
      );
      await _github.git.createReference(
        slug,
        'refs/heads/$_workingBranch',
        base.object!.sha,
      );
    }
  }

  String _joinPath(String folderPath, String name) =>
      folderPath.isEmpty ? name : '$folderPath/$name';

  /// Lista el contenido (ficheros y carpetas) de [folderPath], con el
  /// estado de aprobación de cada uno. Usa cadena vacía para la raíz.
  Future<List<DriveEntry>> listFolder(String folderPath) async {
    final contents = await _github.repositories.getContents(
      slug,
      folderPath,
      ref: _workingBranch,
    );

    if (contents.isFile) {
      return const [];
    }

    final validatedShaByPath = await _validatedShasFor(folderPath);

    final entries =
        (contents.tree ?? [])
            .where((f) => f.name != GitHubConfig.folderKeepFile)
            .map((f) {
              final isValidated = validatedShaByPath[f.path] == f.sha;
              return DriveEntry.fromGitHubFile(
                f,
                status:
                    isValidated
                        ? ReviewStatus.validated
                        : ReviewStatus.inReview,
              );
            })
            .toList();

    entries.sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return entries;
  }

  /// Rutas -> sha de cada entrada de [folderPath] tal y como está en la
  /// rama validada, para poder comparar con la rama de revisión.
  Future<Map<String, String>> _validatedShasFor(String folderPath) async {
    try {
      final validated = await _github.repositories.getContents(
        slug,
        folderPath,
        ref: _validatedBranch,
      );
      if (!validated.isDirectory) return const {};
      return {
        for (final f in validated.tree ?? const <GitHubFile>[])
          if (f.path != null && f.sha != null) f.path!: f.sha!,
      };
    } on GitHubError {
      // getContents() no conserva el código HTTP real: cualquier error de
      // GitHub con un campo "message" llega aquí como GitHubError genérico
      // en vez del NotFound tipado. En la práctica, para esta llamada
      // concreta, casi siempre significa que esta carpeta todavía no existe
      // en la rama validada: todo lo que haya aquí está pendiente de
      // aprobación.
      return const {};
    }
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
      final current = await _github.repositories.getContents(
        slug,
        path,
        ref: _workingBranch,
      );
      existing = current.isFile ? current.file : null;
    } on GitHubError catch (e) {
      // Igual que en _validatedShasFor: getContents() lanza un GitHubError
      // genérico (no el NotFound tipado) cuando el fichero todavía no
      // existe en la rama de revisión, que es el caso normal al subir algo
      // por primera vez.
      debugPrint(
        '[Versiona] getContents("$path", ref: "$_workingBranch") → '
        '${e.runtimeType}: ${e.message}. Se asume que no existe todavía.',
      );
      existing = null;
    }

    final hasCustomMessage =
        commitMessage != null && commitMessage.trim().isNotEmpty;

    debugPrint(
      '[Versiona] Subiendo "$path" a la rama "$_workingBranch" '
      '(${existing?.sha != null ? "actualizar" : "crear"})',
    );

    try {
      if (existing?.sha != null) {
        await _github.repositories.updateFile(
          slug,
          path,
          hasCustomMessage ? commitMessage.trim() : 'Actualizar $fileName',
          content,
          existing!.sha!,
          branch: _workingBranch,
        );
      } else {
        await _github.repositories.createFile(
          slug,
          CreateFile(
            path: path,
            content: content,
            message:
                hasCustomMessage ? commitMessage.trim() : 'Subir $fileName',
            branch: _workingBranch,
          ),
        );
      }
      debugPrint('[Versiona] Subida de "$path" completada.');
    } catch (e, stackTrace) {
      debugPrint('[Versiona] Fallo al subir "$path": $e\n$stackTrace');
      rethrow;
    }
  }

  /// Crea una carpeta vacía mediante un fichero "placeholder" invisible
  /// para el usuario (Git no versiona directorios vacíos).
  Future<void> createFolder({
    required String folderPath,
    required String name,
  }) async {
    final placeholderPath = _joinPath(
      _joinPath(folderPath, name),
      GitHubConfig.folderKeepFile,
    );
    await _github.repositories.createFile(
      slug,
      CreateFile(
        path: placeholderPath,
        content: base64Encode(
          utf8.encode(
            'Este fichero mantiene la carpeta "$name" en Versiona.\n',
          ),
        ),
        message: 'Crear carpeta $name',
        branch: _workingBranch,
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
        _workingBranch,
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
        _workingBranch,
      );
    }
  }

  Future<List<GitHubFile>> _collectFilesRecursively(String path) async {
    final contents = await _github.repositories.getContents(
      slug,
      path,
      ref: _workingBranch,
    );
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
        await _github.repositories
            .listCommits(slug, path: path, sha: _workingBranch)
            .toList();
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

    final current = await _github.repositories.getContents(
      slug,
      path,
      ref: _workingBranch,
    );
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
      branch: _workingBranch,
    );
  }

  /// Enlace a la vista de GitHub para inspeccionar un fichero en detalle.
  String webUrlFor(String path) =>
      'https://github.com/${slug.fullName}/blob/$_workingBranch/$path';

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
      final current = await _github.repositories.getContents(
        slug,
        entry.path,
        ref: _workingBranch,
      );
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
          branch: _workingBranch,
        ),
      );
      await _github.repositories.deleteFile(
        slug,
        entry.path,
        'Mover ${entry.name}',
        file.sha!,
        _workingBranch,
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
        ref: _workingBranch,
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
          branch: _workingBranch,
        ),
      );
    }
    for (final file in files) {
      await _github.repositories.deleteFile(
        slug,
        file.path!,
        'Mover ${entry.name}',
        file.sha!,
        _workingBranch,
      );
    }
  }

  /// Aprueba todos los cambios pendientes: fusiona la rama de revisión
  /// sobre la rama validada con un commit de fusión real (no se reescribe
  /// ni se pierde historial).
  ///
  /// Nota: fusiona TODO lo que haya en la rama de revisión, no solo el
  /// fichero desde el que se llame a esta acción, porque de momento hay
  /// una única rama compartida para todos los cambios pendientes.
  ///
  /// De momento cualquier persona con la app conectada puede aprobar: no
  /// hay todavía un rol de "supervisor" restringido por permisos.
  Future<void> approveAndConsolidate({String? summary}) async {
    final GitHubComparison comparison;
    try {
      comparison = await _github.repositories.compareCommits(
        slug,
        _validatedBranch,
        _workingBranch,
      );
    } on GitHubError catch (e) {
      throw StateError(
        'No se pudo comprobar los cambios pendientes entre '
        '"$_validatedBranch" y "$_workingBranch": ${e.message}',
      );
    }

    if ((comparison.aheadBy ?? 0) == 0) {
      throw StateError('No hay cambios pendientes de aprobar.');
    }

    try {
      await _github.repositories.merge(
        slug,
        CreateMerge(
          _validatedBranch,
          _workingBranch,
          commitMessage:
              (summary != null && summary.trim().isNotEmpty)
                  ? summary.trim()
                  : 'Aprobar y consolidar cambios pendientes',
        ),
      );
    } on GitHubError catch (e) {
      throw StateError(
        'No se pudo fusionar "$_workingBranch" sobre '
        '"$_validatedBranch": ${e.message}',
      );
    }
  }
}
