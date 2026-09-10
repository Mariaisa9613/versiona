import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:github/github.dart';

import '../config/github_config.dart';
import '../models/drive_entry.dart';
import '../models/file_version.dart';
import '../models/pending_change.dart';

/// Resultado de aprobar o rechazar un cambio, para poder informar de éxitos
/// parciales cuando se procesan varios de una vez.
class ChangeResult {
  const ChangeResult(this.change, {this.error});

  final PendingChange change;

  /// `null` si salió bien; el motivo del fallo si no.
  final String? error;

  bool get ok => error == null;
}

/// Convierte el repositorio privado del usuario en un "Drive": expone
/// operaciones de fichero/carpeta simples por encima de la API de GitHub,
/// para que el resto de la app nunca tenga que hablar en términos de Git.
///
/// ## Las dos ramas
///
/// - La **rama de trabajo** ([GitHubConfig.workBranchName]) es el Drive tal y
///   como está ahora: ahí se escribe todo y de ahí se lista lo que se ve.
/// - La **rama por defecto** del repositorio guarda la versión **aprobada**, y
///   solo cambia cuando alguien aprueba algo.
///
/// Un fichero está "Validado" cuando su contenido coincide en las dos; si no,
/// tiene un cambio pendiente de revisar.
///
/// ## Aprobar y rechazar
///
/// Aprobar un fichero **no fusiona ramas**: copia ese fichero concreto de la
/// rama de trabajo a la aprobada, o lo borra allí si lo pendiente era una
/// baja. Rechazarlo hace lo contrario: devuelve el fichero a como estaba en la
/// versión aprobada, o lo quita de la rama de trabajo si nunca llegó a
/// aprobarse.
///
/// Como en todo el flujo no hay ni una fusión, no pueden aparecer conflictos,
/// y se puede aprobar o rechazar cualquier combinación de ficheros en el orden
/// que sea.
class DriveService {
  DriveService(this._github);

  final GitHub _github;
  RepositorySlug? _slug;
  String? _defaultBranch;

  /// Cambios pendientes del espacio, cacheados para no recalcularlos cada vez
  /// que se navega. Se invalida solo, desde dentro de este servicio, en cuanto
  /// algo puede haberlos cambiado.
  List<PendingChange>? _pendingCache;

  /// Las diferencias entre las dos ramas, cacheadas aparte: el listado de
  /// una carpeta las necesita, pero no necesita el "quién y cuándo" de cada
  /// cambio, que cuesta una llamada más por fichero.
  List<PendingChange>? _diffCache;

  static const String _workBranch = GitHubConfig.workBranchName;

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

  /// Igual que [repoName], con el propietario delante ("usuario/repo"): es
  /// lo que identifica de verdad a un repositorio.
  String? get repoFullName => _slug?.fullName;

  /// Tamaño máximo de un fichero que se puede subir. La API de "contents"
  /// de GitHub rechaza lo que pasa de 100 MB, pero va mal mucho antes: el
  /// fichero viaja entero en base64 (un tercio más grande) en una sola
  /// petición, y en web el navegador tiene las dos copias en memoria a la
  /// vez.
  static const int maxUploadBytes = 25 * 1024 * 1024;

  /// Por qué no se puede subir [fileName], para decirlo igual desde el
  /// formulario de subida que desde aquí.
  static String tooLargeMessage(String fileName) =>
      '"$fileName" ocupa más de ${maxUploadBytes ~/ (1024 * 1024)} MB, que '
      'es lo máximo que se puede subir.';

  /// Busca el repositorio de datos del usuario y lo crea si es la primera
  /// vez que conecta su cuenta. También garantiza que exista la rama de
  /// trabajo.
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
    _adoptRepo(repo);
    await _ensureWorkBranch();
    return _slug!;
  }

  /// Cambia el Drive activo a un repositorio ya existente (elegido por el
  /// usuario entre los suyos), asegurando que tenga su rama de trabajo.
  Future<void> switchTo(RepositorySlug slug) async {
    if (_slug == slug) return;
    final repo = await _github.repositories.getRepository(slug);
    _adoptRepo(repo);
    await _ensureWorkBranch();
  }

  void _adoptRepo(Repository repo) {
    _slug = RepositorySlug.full(repo.fullName);
    _defaultBranch =
        repo.defaultBranch.isNotEmpty ? repo.defaultBranch : 'main';
    _invalidatePending();
  }

  /// Repositorios (públicos y privados) del usuario entre los que puede
  /// elegir como Drive activo, ordenados alfabéticamente.
  Future<List<Repository>> listAccessibleRepos() =>
      _github.repositories.listRepositories(type: 'owner').toList();

  /// Busca, entre los repositorios del usuario, uno ya creado por Versiona
  /// anteriormente: por la marca en su descripción, o por el nombre fijo
  /// que usaban las versiones antiguas de la app ([GitHubConfig.driveRepoName])
  /// antes de que se pudiera elegir nombre — para no dejar huérfano el
  /// espacio de quien ya usaba la app.
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

  /// Crea un nuevo repositorio privado vacío (con su rama de trabajo) y lo
  /// deja como Drive activo. Su descripción queda marcada para que
  /// [findWorkspace] pueda reconocerlo más adelante.
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
    _adoptRepo(repo);
    // GitHub responde a "crear repositorio" antes de terminar de prepararlo,
    // así que durante un instante no existe ninguna rama.
    await _waitForInitialCommit();
    await _ensureWorkBranch();
  }

  Future<void> _waitForInitialCommit() async {
    for (final delay in _retryDelays) {
      if (await _branchTipSha(_validatedBranch) != null) return;
      await Future.delayed(delay);
    }
  }

  /// Elimina un repositorio de GitHub de forma permanente e irreversible
  /// (ficheros e historial incluidos). Requiere que el token tenga el
  /// scope `delete_repo`. Quien llame a esto debe haber confirmado ya
  /// explícitamente con el usuario: no hay marcha atrás.
  Future<void> deleteRepo(RepositorySlug target) async {
    await _github.repositories.deleteRepository(target);
  }

  Future<void> _ensureWorkBranch() async {
    if (await _branchTipSha(_workBranch) != null) return;

    final baseSha = await _branchTipSha(_validatedBranch);
    if (baseSha == null) return; // Repositorio sin commits todavía.

    try {
      await _github.git.createReference(
        slug,
        'refs/heads/$_workBranch',
        baseSha,
      );
    } on GitHubError catch (e) {
      debugPrint('[Versiona] No se pudo crear "$_workBranch": ${e.message}');
    }
  }

  /// Sha de la punta de [branch], o `null` si esa rama no existe.
  ///
  /// `repositories.getBranch` no lanza excepción con un 404: devuelve un
  /// objeto con los campos a nulo (no le pasa a la petición el código que
  /// espera), así que aquí se mira el contenido, no la excepción.
  Future<String?> _branchTipSha(String branch) async {
    try {
      final result = await _github.repositories.getBranch(slug, branch);
      return result.commit?.sha;
    } catch (_) {
      return null;
    }
  }

  String _joinPath(String folderPath, String name) =>
      folderPath.isEmpty ? name : '$folderPath/$name';

  String _parentPath(String path) {
    final index = path.lastIndexOf('/');
    return index == -1 ? '' : path.substring(0, index);
  }

  /// Espera entre reintentos al releer justo después de escribir: la API de
  /// "contents" de GitHub es eventualmente consistente y puede devolver un
  /// error o contenido antiguo durante un instante.
  static const _retryDelays = [
    Duration(milliseconds: 400),
    Duration(milliseconds: 900),
    Duration(milliseconds: 1500),
  ];

  Future<T> _withRetry<T>(Future<T> Function() action) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await action();
      } on GitHubError {
        if (attempt >= _retryDelays.length) rethrow;
        await Future.delayed(_retryDelays[attempt]);
      }
    }
  }

  void _invalidatePending() {
    _pendingCache = null;
    _diffCache = null;
  }

  // ---------------------------------------------------------------------
  // Listado
  // ---------------------------------------------------------------------

  /// Lista el contenido (ficheros y carpetas) de [folderPath], con el estado
  /// de aprobación de cada uno. Usa cadena vacía para la raíz.
  ///
  /// Lo que se ve es la rama de trabajo, que es el Drive tal y como está
  /// ahora. Comparándola con la versión aprobada se sabe qué está validado y
  /// qué tiene cambios sin aprobar, y qué hay pendiente de eliminarse (sigue
  /// existiendo en la versión aprobada aunque ya no esté aquí).
  Future<List<DriveEntry>> listFolder(String folderPath) async {
    // Sin rama de trabajo no se puede saber qué está pendiente: se enseña la
    // versión aprobada tal cual. Sin esta comprobación, una rama de trabajo
    // que no existiera haría parecer que TODO el espacio está pendiente de
    // eliminarse, que es justo la impresión que no se puede dar.
    if (await _branchTipSha(_workBranch) == null) {
      await _ensureWorkBranch();
      if (await _branchTipSha(_workBranch) == null) {
        return _asEntries(await _treeOf(folderPath, _validatedBranch));
      }
    }

    final working = await _treeOf(folderPath, _workBranch, retry: true);
    final validated = await _treeOf(folderPath, _validatedBranch);
    // Qué se ha borrado de verdad lo dice la comparación entre las dos ramas,
    // no la ausencia en el listado: si la lectura de la rama de trabajo viene
    // vacía o incompleta, deducirlo por ausencia haría parecer que está todo
    // pendiente de eliminarse.
    final removedPaths = await _removedPaths();

    debugPrint(
      '[Versiona] "$folderPath": ${working.length} en "$_workBranch", '
      '${validated.length} en "$_validatedBranch", '
      '${removedPaths.length} borrados pendientes en el espacio.',
    );

    final validatedByPath = {
      for (final f in validated)
        if (f.path != null) f.path!: f,
    };

    final entries = <DriveEntry>[];
    final seen = <String>{};

    for (final file in working) {
      if (file.name == GitHubConfig.folderKeepFile) continue;
      final path = file.path;
      if (path == null) continue;
      seen.add(path);

      // Solo los ficheros llevan marca de cambio. Una carpeta no cambia por
      // sí misma: lo que cambia es lo que hay dentro, y ahí es donde se
      // aprueba o se rechaza.
      final approved = validatedByPath[path];
      final isValidated = approved != null && approved.sha == file.sha;
      entries.add(
        DriveEntry.fromGitHubFile(
          file,
          pendingChange:
              (isValidated || file.type == 'dir')
                  ? null
                  : PendingChange(
                    path: path,
                    kind:
                        approved == null
                            ? PendingChangeKind.added
                            : PendingChangeKind.modified,
                  ),
        ),
      );
    }

    // Lo que está en la versión aprobada pero ya no en la de trabajo está
    // pendiente de eliminarse: se sigue enseñando, marcado, hasta que se
    // apruebe la baja. Si desapareciera sin más, borrar parecería definitivo
    // cuando en realidad todavía hay que aprobarlo.
    for (final file in validated) {
      final path = file.path;
      if (path == null || seen.contains(path)) continue;
      if (file.name == GitHubConfig.folderKeepFile) continue;

      // Solo si GitHub confirma que se ha borrado, y solo para ficheros: una
      // carpeta que ya no está en la rama de trabajo se sigue enseñando para
      // poder entrar y resolver lo que hay dentro.
      final isDeletion = file.type != 'dir' && removedPaths.contains(path);
      if (!isDeletion) {
        debugPrint(
          '[Versiona] "$path" está en "$_validatedBranch" pero no en '
          '"$_workBranch", y la comparación no lo da por borrado: se enseña '
          'como validado.',
        );
      }
      entries.add(
        DriveEntry.fromGitHubFile(
          file,
          pendingChange:
              isDeletion
                  ? PendingChange(path: path, kind: PendingChangeKind.deleted)
                  : null,
        ),
      );
    }

    entries.sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// Entradas sin ningún cambio pendiente, ya ordenadas.
  List<DriveEntry> _asEntries(List<GitHubFile> files) {
    final entries = [
      for (final file in files)
        if (file.name != GitHubConfig.folderKeepFile)
          DriveEntry.fromGitHubFile(file),
    ];
    entries.sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// Contenido de [folderPath] en [ref]. Si la carpeta no existe ahí, o la
  /// rama todavía no tiene nada, devuelve una lista vacía.
  Future<List<GitHubFile>> _treeOf(
    String folderPath,
    String ref, {
    bool retry = false,
  }) async {
    Future<RepositoryContents> read() =>
        _github.repositories.getContents(slug, folderPath, ref: ref);

    try {
      final contents = retry ? await _withRetry(read) : await read();
      if (!contents.isDirectory) return const [];
      return contents.tree ?? const [];
    } on GitHubError catch (e) {
      // getContents() no conserva el código HTTP real, así que no se puede
      // distinguir "no existe" de "ha fallado". Si la rama sí existe, un
      // error aquí es de verdad: devolver una lista vacía dejaría la carpeta
      // como si se hubieran perdido los ficheros.
      if (await _branchTipSha(ref) == null) return const [];
      debugPrint(
        '[Versiona] No se pudo leer "$folderPath" en "$ref": ${e.message}',
      );
      if (ref == _validatedBranch) return const [];
      rethrow;
    }
  }

  // ---------------------------------------------------------------------
  // Cambios pendientes
  // ---------------------------------------------------------------------

  /// Todo lo que está pendiente de aprobación en el espacio.
  ///
  /// Sale de comparar los ficheros de las dos ramas ([_diff]). El "quién y
  /// cuándo" de cada fichero se consulta aparte (la comparación no lo trae
  /// por fichero), en paralelo y solo para lo que ha cambiado.
  Future<List<PendingChange>> pendingChanges({bool forceRefresh = false}) async {
    final cached = _pendingCache;
    if (!forceRefresh && cached != null) return cached;

    final changes = await _diff(forceRefresh: forceRefresh);
    final detailed = await Future.wait(
      changes.map((change) async {
        try {
          final commits =
              await _github.repositories
                  .listCommits(slug, path: change.path, sha: _workBranch)
                  .take(20)
                  .toList();
          return change.withHistory(commits);
        } catch (_) {
          return change;
        }
      }),
    );

    _pendingCache = detailed;
    return detailed;
  }

  /// En qué se diferencian ahora mismo la versión aprobada y la de trabajo.
  /// Son **dos** llamadas (el árbol de cada rama), y de aquí sale tanto la
  /// lista de cambios pendientes como qué está pendiente de borrarse.
  ///
  /// No se usa la API de comparación de GitHub a propósito: mide contra la
  /// base de fusión de las dos ramas, y aprobar no fusiona nada, así que esa
  /// base se quedaba congelada en el punto en el que se separaron. Ver
  /// [PendingChange.fromTrees].
  Future<List<PendingChange>> _diff({bool forceRefresh = false}) async {
    final cached = _diffCache;
    if (!forceRefresh && cached != null) return cached;

    try {
      final [approved, working] = await Future.wait([
        _blobsOf(_validatedBranch),
        _blobsOf(_workBranch),
      ]);
      final changes = PendingChange.fromTrees(
        approved: approved,
        working: working,
      );
      _diffCache = changes;
      return changes;
    } on GitHubError catch (e) {
      debugPrint('[Versiona] No se pudo comparar las ramas: ${e.message}');
      return const [];
    }
  }

  /// Todos los ficheros de [ref], de ruta al sha de su contenido. Dos rutas
  /// con el mismo sha guardan exactamente lo mismo.
  ///
  /// Se pide el árbol completo de una vez (`recursive=1`) en lugar de
  /// recorrer carpeta a carpeta: es una sola llamada para todo el espacio.
  Future<Map<String, String>> _blobsOf(String ref) async {
    final tip = await _branchTipSha(ref);
    if (tip == null) return const {};

    final tree = await _github.git.getTree(slug, tip, recursive: true);
    if (tree.truncated == true) {
      // Solo pasa en espacios enormes (decenas de miles de ficheros). Con el
      // árbol incompleto, lo que falte parecería borrado, así que es mejor
      // no marcar nada que marcar bajas que nadie ha pedido.
      throw StateError(
        'Este espacio tiene demasiados ficheros para revisarlos de una vez.',
      );
    }

    return {
      for (final entry in tree.entries ?? const <GitTreeEntry>[])
        // Fuera el fichero interno que mantiene vivas las carpetas vacías:
        // no es un cambio que nadie tenga que revisar (ni siquiera se ve),
        // pero contaba como pendiente y llegaba a bloquear el borrado de una
        // carpeta recién creada, sin forma de desbloquearlo.
        if (entry.type == 'blob' &&
            entry.path != null &&
            entry.sha != null &&
            !_isFolderKeepFile(entry.path))
          entry.path!: entry.sha!,
    };
  }

  bool _isFolderKeepFile(String? path) =>
      path != null &&
      (path == GitHubConfig.folderKeepFile ||
          path.endsWith('/${GitHubConfig.folderKeepFile}'));

  /// Rutas que están en la versión aprobada y ya no en la de trabajo: bajas
  /// pendientes de aprobarse.
  Future<Set<String>> _removedPaths({bool forceRefresh = false}) async {
    return {
      for (final change in await _diff(forceRefresh: forceRefresh))
        if (change.kind == PendingChangeKind.deleted) change.path,
    };
  }

  Future<PendingChange?> pendingChangeFor(String path) async {
    for (final change in await pendingChanges()) {
      if (change.path == path) return change;
    }
    return null;
  }

  /// Impide mover o borrar una carpeta que tenga cambios pendientes dentro,
  /// para no dejar a medias algo que alguien está revisando.
  Future<void> _assertNoPendingInside(String folderPath) async {
    final inside =
        (await pendingChanges())
            .where((c) => c.path.startsWith('$folderPath/'))
            .toList();
    if (inside.isEmpty) return;

    final names = inside.take(3).map((c) => c.name).join(', ');
    final rest = inside.length > 3 ? ' y ${inside.length - 3} más' : '';
    throw StateError(
      'Esta carpeta tiene ${inside.length} '
      '${inside.length == 1 ? "cambio pendiente" : "cambios pendientes"} '
      'dentro ($names$rest). Apruébalos o recházalos antes de moverla o '
      'eliminarla.',
    );
  }

  // ---------------------------------------------------------------------
  // Escrituras (siempre sobre la rama de trabajo)
  // ---------------------------------------------------------------------

  /// Sube (crea o actualiza) un fichero dentro de [folderPath]. Devuelve la
  /// entrada resultante para poder reflejarla en la vista al momento, sin
  /// esperar a una relectura que puede tardar en ponerse al día.
  ///
  /// [commitMessage] es el motivo del cambio que ve el usuario (p.ej. "Ajuste
  /// de IVA proveedor X"). Si se omite o queda vacío, se usa un mensaje
  /// genérico.
  Future<DriveEntry> uploadFile({
    required String folderPath,
    required String fileName,
    required List<int> bytes,
    String? commitMessage,
  }) async {
    if (bytes.length > maxUploadBytes) {
      throw StateError(tooLargeMessage(fileName));
    }
    final path = _joinPath(folderPath, fileName);
    final content = base64Encode(bytes);

    final existing = await _fileAt(path, _workBranch);
    final approved = await _fileAt(path, _validatedBranch);

    final hasCustomMessage =
        commitMessage != null && commitMessage.trim().isNotEmpty;
    final isUpdate = existing?.sha != null;

    final uploaded = await _writeFile(
      path: path,
      base64Content: content,
      message:
          hasCustomMessage
              ? commitMessage.trim()
              : (isUpdate ? 'Actualizar $fileName' : 'Subir $fileName'),
      branch: _workBranch,
      sha: isUpdate ? existing!.sha : null,
    );
    _invalidatePending();

    return DriveEntry.fromGitHubFile(
      uploaded,
      pendingChange: PendingChange(
        path: path,
        // Lo que decide el tipo es la comparación con la versión aprobada,
        // no la última acción: volver a subir algo que aún era nuevo lo deja
        // nuevo.
        kind:
            approved == null
                ? PendingChangeKind.added
                : PendingChangeKind.modified,
        message: hasCustomMessage ? commitMessage.trim() : null,
        commitCount: 1,
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// Crea o actualiza un fichero, comprobando que GitHub lo haya aceptado.
  ///
  /// `createFile` y `updateFile` del paquete **no lanzan excepción cuando la
  /// escritura falla**: no le dicen a la petición qué código HTTP esperan, así
  /// que un 404/409/422 se convierte en una respuesta que se intenta
  /// interpretar igualmente. Sin esta comprobación, aprobar un cambio podría
  /// decir "hecho" sin haber escrito nada, y el cambio seguiría pendiente.
  Future<GitHubFile> _writeFile({
    required String path,
    required String base64Content,
    required String message,
    required String branch,
    String? sha,
  }) async {
    final ContentCreation creation;
    if (sha == null) {
      creation = await _github.repositories.createFile(
        slug,
        CreateFile(
          path: path,
          content: base64Content,
          message: message,
          branch: branch,
        ),
      );
    } else {
      creation = await _github.repositories.updateFile(
        slug,
        path,
        message,
        base64Content,
        sha,
        branch: branch,
      );
    }

    final written = creation.content;
    if (written?.sha == null) {
      throw StateError(
        'GitHub no ha aceptado guardar "$path" en la rama "$branch".',
      );
    }
    debugPrint('[Versiona] Escrito "$path" en "$branch".');
    return written!;
  }

  /// Contenido de [file] en base64 y sin saltos de línea, listo para volver a
  /// escribirlo tal cual.
  ///
  /// La API de "contents" de GitHub **no devuelve el contenido de los ficheros
  /// de más de 1 MB**: contesta con la cadena vacía y hay que pedir el blob
  /// por su sha. Sin esto, copiar un fichero grande (al aprobarlo, al moverlo
  /// o al rechazarlo) guardaba un fichero vacío, y como el contenido ya no
  /// coincidía se quedaba "Modificado" para siempre por mucho que se aprobara.
  Future<String> _contentOf(GitHubFile file) async {
    final inline = file.content;
    if (inline != null && inline.trim().isNotEmpty) {
      return inline.replaceAll('\n', '');
    }

    final sha = file.sha;
    if (sha == null) {
      throw StateError('No se pudo leer el contenido de "${file.path}".');
    }

    debugPrint(
      '[Versiona] "${file.path}" no viene con contenido (${file.size} bytes): '
      'se pide el blob $sha.',
    );
    final blob = await _github.git.getBlob(slug, sha);
    final content = blob.content;
    if (content == null || content.trim().isEmpty) {
      throw StateError('No se pudo leer el contenido de "${file.path}".');
    }
    return content.replaceAll('\n', '');
  }

  /// El fichero en [path] dentro de [ref], o `null` si no está ahí.
  Future<GitHubFile?> _fileAt(String path, String ref) async {
    try {
      final contents = await _github.repositories.getContents(
        slug,
        path,
        ref: ref,
      );
      return contents.isFile ? contents.file : null;
    } on GitHubError {
      return null;
    }
  }

  /// Si hay algo (fichero o carpeta) en [path] dentro de [ref].
  ///
  /// A diferencia de [_fileAt], un fallo que no sea "no existe" se propaga:
  /// quien pregunta esto va a escribir ahí, y dar por libre una ruta que no
  /// se ha podido comprobar es justo lo que se quiere evitar.
  Future<bool> _existsAt(String path, String ref) async {
    try {
      await _github.repositories.getContents(slug, path, ref: ref);
      return true;
    } on GitHubError catch (e) {
      // getContents() no conserva el código HTTP: un 404 llega como un
      // GitHubError con el mensaje de la API.
      if (e is NotFound || e.message == 'Not Found') return false;
      rethrow;
    }
  }

  /// Crea una carpeta vacía mediante un fichero "placeholder" invisible para
  /// el usuario (Git no versiona carpetas vacías).
  Future<DriveEntry> createFolder({
    required String folderPath,
    required String name,
  }) async {
    final path = _joinPath(folderPath, name);
    await _writeFile(
      path: _joinPath(path, GitHubConfig.folderKeepFile),
      base64Content: base64Encode(
        utf8.encode('Este fichero mantiene la carpeta "$name" en Versiona.\n'),
      ),
      message: 'Crear carpeta $name',
      branch: _workBranch,
    );
    _invalidatePending();

    return DriveEntry(
      name: name,
      path: path,
      type: DriveEntryType.folder,
      pendingChange: PendingChange(
        path: path,
        kind: PendingChangeKind.added,
        message: 'Crear carpeta $name',
        commitCount: 1,
        updatedAt: DateTime.now(),
      ),
    );
  }

  /// Elimina un fichero, o una carpeta entera (y todo su contenido), de la
  /// rama de trabajo.
  ///
  /// La versión aprobada **no se toca**: mientras no se apruebe la baja, la
  /// entrada se sigue viendo marcada como pendiente de eliminarse. Devuelve
  /// cómo queda, o `null` si desaparece del todo (era algo que nunca llegó a
  /// aprobarse, así que no queda nada que revisar).
  Future<DriveEntry?> deleteEntry(DriveEntry entry) async {
    if (entry.isFolder) await _assertNoPendingInside(entry.path);

    final files =
        entry.isFolder
            ? await _collectFilesRecursively(entry.path, ref: _workBranch)
            : [
              await _fileAt(entry.path, _workBranch),
            ].whereType<GitHubFile>().toList();

    // Uno detrás de otro, no en paralelo: la API de "contents" crea un commit
    // por llamada a partir de la punta de la rama, así que varias escrituras
    // simultáneas sobre la misma rama se pisan y dan conflictos (409).
    for (final file in files) {
      await _github.repositories.deleteFile(
        slug,
        file.path!,
        entry.isFolder ? 'Eliminar carpeta ${entry.name}' : 'Eliminar ${entry.name}',
        file.sha!,
        _workBranch,
      );
    }
    _invalidatePending();

    // Si tampoco existe en la versión aprobada, no hay ninguna baja que
    // revisar: simplemente ya no está.
    final approved = await _fileAt(entry.path, _validatedBranch);
    final existsApproved =
        entry.isFolder
            ? (await _treeOf(entry.path, _validatedBranch)).isNotEmpty
            : approved != null;
    if (!existsApproved) return null;

    return entry.withPendingChange(
      PendingChange(
        path: entry.path,
        kind: PendingChangeKind.deleted,
        message: 'Eliminar ${entry.name}',
        commitCount: 1,
        updatedAt: DateTime.now(),
      ),
    );
  }

  Future<List<GitHubFile>> _collectFilesRecursively(
    String path, {
    required String ref,
  }) async {
    final RepositoryContents contents;
    try {
      contents = await _github.repositories.getContents(slug, path, ref: ref);
    } on GitHubError {
      return const [];
    }
    if (contents.isFile) {
      return contents.file != null ? [contents.file!] : [];
    }

    final result = <GitHubFile>[];
    for (final entry in contents.tree ?? <GitHubFile>[]) {
      if (entry.type == 'dir') {
        result.addAll(await _collectFilesRecursively(entry.path!, ref: ref));
      } else {
        result.add(entry);
      }
    }
    return result;
  }

  /// Contenido en bruto de [path] para poder previsualizarlo (imagen, PDF,
  /// hoja de cálculo...) sin necesidad de descargarlo primero.
  Future<Uint8List> fetchFileBytes(String path) async {
    final contents = await _withRetry(
      () => _github.repositories.getContents(slug, path, ref: _workBranch),
    );
    final file = contents.file;
    if (file == null) {
      throw StateError('No se pudo leer el contenido de este fichero.');
    }
    return base64Decode(await _contentOf(file));
  }

  /// Historial de versiones (commits) que han afectado a [path], del más
  /// reciente al más antiguo.
  Future<List<FileVersion>> fileHistory(String path) async {
    final commits =
        await _github.repositories
            .listCommits(slug, path: path, sha: _workBranch)
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
    if (oldFile == null) {
      throw StateError('No se pudo leer esa versión del fichero.');
    }

    final current = await _fileAt(path, _workBranch);
    if (current?.sha == null) {
      throw StateError('El fichero ya no existe en su ubicación actual.');
    }

    await _writeFile(
      path: path,
      base64Content: await _contentOf(oldFile),
      message: 'Restaurar $fileName a una versión anterior',
      branch: _workBranch,
      sha: current!.sha,
    );
    _invalidatePending();
  }

  /// Enlace a la vista de GitHub para inspeccionar un fichero en detalle.
  String webUrlFor(String path) =>
      'https://github.com/${slug.fullName}/blob/$_workBranch/$path';

  /// Cambia el nombre de [entry] manteniéndolo en la misma carpeta.
  Future<DriveEntry> rename({
    required DriveEntry entry,
    required String newName,
  }) async {
    final newPath = _joinPath(_parentPath(entry.path), newName);
    return _movePath(
      entry: entry,
      newPath: newPath,
      message:
          entry.isFolder
              ? 'Renombrar la carpeta "${entry.name}" a "$newName"'
              : 'Renombrar "${entry.name}" a "$newName"',
    );
  }

  /// Mueve [entry] a la carpeta [destinationFolderPath] (cadena vacía para
  /// la raíz), conservando su nombre.
  Future<DriveEntry> move({
    required DriveEntry entry,
    required String destinationFolderPath,
  }) async {
    if (entry.isFolder &&
        (destinationFolderPath == entry.path ||
            destinationFolderPath.startsWith('${entry.path}/'))) {
      throw StateError('No puedes mover una carpeta dentro de sí misma.');
    }

    final newPath = _joinPath(destinationFolderPath, entry.name);
    final destination =
        destinationFolderPath.isEmpty
            ? 'la carpeta principal'
            : '"$destinationFolderPath"';
    return _movePath(
      entry: entry,
      newPath: newPath,
      message:
          entry.isFolder
              ? 'Mover la carpeta "${entry.name}" a $destination'
              : 'Mover "${entry.name}" a $destination',
    );
  }

  /// Mueve/renombra [entry] a [newPath] dentro de la rama de trabajo. GitHub
  /// no tiene una operación nativa de mover: se recrea cada fichero en la
  /// ruta nueva y se borra el original.
  Future<DriveEntry> _movePath({
    required DriveEntry entry,
    required String newPath,
    required String message,
  }) async {
    if (newPath == entry.path) return entry;
    if (entry.isFolder) await _assertNoPendingInside(entry.path);

    // Antes de tocar nada: GitHub no deja crear un fichero donde ya hay otro,
    // así que con el destino ocupado la copia fallaba a mitad, con parte de
    // los ficheros ya duplicados y ninguno de los originales borrado.
    if (await _existsAt(newPath, _workBranch)) {
      final name = newPath.substring(newPath.lastIndexOf('/') + 1);
      throw StateError('Ya existe "$name" en esa carpeta.');
    }

    final files =
        entry.isFolder
            ? await _collectFilesRecursively(entry.path, ref: _workBranch)
            : [
              await _fileAt(entry.path, _workBranch),
            ].whereType<GitHubFile>().toList();
    if (files.isEmpty) {
      throw StateError('No se pudo leer lo que se quiere mover.');
    }

    // Las lecturas van en paralelo (son GET independientes). Las escrituras,
    // una detrás de otra: la API de "contents" crea un commit por llamada
    // desde la punta de la rama y varias a la vez se pisan. Primero se crean
    // las copias nuevas y solo después se borran los originales, para no
    // perder datos si algo falla a mitad.
    final contents = await Future.wait(
      files.map(
        (file) => _github.repositories.getContents(
          slug,
          file.path!,
          ref: _workBranch,
        ),
      ),
    );

    for (var i = 0; i < files.length; i++) {
      final file = contents[i].file;
      if (file == null) continue;
      final destination =
          entry.isFolder
              ? '$newPath/${files[i].path!.substring(entry.path.length + 1)}'
              : newPath;
      await _writeFile(
        path: destination,
        base64Content: await _contentOf(file),
        message: message,
        branch: _workBranch,
      );
    }
    for (final file in files) {
      await _github.repositories.deleteFile(
        slug,
        file.path!,
        message,
        file.sha!,
        _workBranch,
      );
    }
    _invalidatePending();

    final index = newPath.lastIndexOf('/');
    return DriveEntry(
      name: index == -1 ? newPath : newPath.substring(index + 1),
      path: newPath,
      type: entry.type,
      sha: entry.sha,
      size: entry.size,
      pendingChange:
          entry.isFolder
              ? null
              : PendingChange(
                path: newPath,
                kind: PendingChangeKind.added,
                message: message,
                commitCount: 1,
                updatedAt: DateTime.now(),
              ),
    );
  }

  // ---------------------------------------------------------------------
  // Aprobar / rechazar
  // ---------------------------------------------------------------------

  /// Sustituye cada carpeta de [changes] por los cambios que tiene dentro,
  /// que es lo único que se sabe aprobar o rechazar: un fichero.
  ///
  /// Una carpeta puede llegar aquí porque en la lista se ve la carpeta, no
  /// sus ficheros (p.ej. al borrarla entera). Sin esto, aprobarla acababa en
  /// [_publish] con una ruta que no es ningún fichero, no se escribía nada y
  /// aun así se informaba de que había ido bien: la carpeta desaparecía de
  /// la vista y volvía a aparecer en la siguiente recarga.
  Future<List<PendingChange>> _expandAll(List<PendingChange> changes) async {
    final pending = await pendingChanges();
    final expanded = <String, PendingChange>{};

    for (final change in changes) {
      final inside =
          pending.where((c) => c.path.startsWith('${change.path}/')).toList();
      if (inside.isEmpty) {
        expanded[change.path] = change;
        continue;
      }
      debugPrint(
        '[Versiona] "${change.path}" es una carpeta: se resuelven los '
        '${inside.length} cambios que tiene dentro.',
      );
      for (final child in inside) {
        expanded[child.path] = child;
      }
    }

    return expanded.values.toList();
  }

  /// Aprueba [changes]: lleva cada fichero a la versión aprobada tal y como
  /// está en la rama de trabajo, o lo borra allí si lo pendiente era una baja.
  ///
  /// No hay fusión de ramas: es un commit por fichero sobre la rama aprobada,
  /// así que no pueden aparecer conflictos. Se procesan **en serie** porque
  /// cada commit parte de la punta de la rama. Devuelve el resultado de cada
  /// uno por separado, para poder informar de éxitos parciales.
  Future<List<ChangeResult>> approveChanges(
    List<PendingChange> changes, {
    String? summary,
  }) async {
    final hasSummary = summary != null && summary.trim().isNotEmpty;
    final results = <ChangeResult>[];

    for (final change in await _expandAll(changes)) {
      try {
        final message =
            hasSummary
                ? summary.trim()
                : 'Aprobar ${change.kind == PendingChangeKind.deleted ? "la baja de " : ""}${change.name}';
        await _publish(change, message);
        results.add(ChangeResult(change));
      } catch (e) {
        results.add(ChangeResult(change, error: _describeFailure(e)));
      }
    }
    _invalidatePending();
    return results;
  }

  /// Lleva un cambio concreto a la versión aprobada.
  Future<void> _publish(PendingChange change, String message) async {
    // Las dos lecturas a la vez: son independientes y así se ahorra un viaje
    // de ida y vuelta, que es lo que más se nota al aprobar varios seguidos.
    final [approved, working] = await Future.wait([
      _fileAt(change.path, _validatedBranch),
      _fileAt(change.path, _workBranch),
    ]);

    if (change.kind == PendingChangeKind.deleted) {
      if (approved?.sha == null) {
        await _assertResolvesToFile(change);
        return; // Ya no estaba: nada que hacer.
      }
      await _github.repositories.deleteFile(
        slug,
        change.path,
        message,
        approved!.sha!,
        _validatedBranch,
      );
      return;
    }

    if (working == null) {
      throw StateError('El fichero ya no está en la rama de trabajo.');
    }
    final raw = await _contentOf(working);

    await _writeFile(
      path: change.path,
      base64Content: raw,
      message: message,
      branch: _validatedBranch,
      sha: approved?.sha,
    );
  }

  /// Rechaza [changes]: devuelve cada fichero a como estaba en la versión
  /// aprobada, o lo quita de la rama de trabajo si nunca llegó a aprobarse.
  Future<List<ChangeResult>> rejectChanges(List<PendingChange> changes) async {
    final results = <ChangeResult>[];
    for (final change in await _expandAll(changes)) {
      try {
        await _revert(change);
        results.add(ChangeResult(change));
      } catch (e) {
        results.add(ChangeResult(change, error: _describeFailure(e)));
      }
    }
    _invalidatePending();
    return results;
  }

  Future<void> _revert(PendingChange change) async {
    final [approved, working] = await Future.wait([
      _fileAt(change.path, _validatedBranch),
      _fileAt(change.path, _workBranch),
    ]);
    final message = 'Rechazar los cambios de ${change.name}';

    // Nunca se aprobó: rechazarlo es quitarlo de la rama de trabajo.
    if (approved == null) {
      if (working?.sha == null) {
        await _assertResolvesToFile(change);
        return;
      }
      await _github.repositories.deleteFile(
        slug,
        change.path,
        message,
        working!.sha!,
        _workBranch,
      );
      return;
    }

    final raw = await _contentOf(approved);

    // Estaba pendiente de borrarse: rechazar esa baja lo devuelve.
    if (working?.sha == null) {
      await _writeFile(
        path: change.path,
        base64Content: raw,
        message: 'Rechazar la baja de ${change.name}',
        branch: _workBranch,
      );
      return;
    }

    await _writeFile(
      path: change.path,
      base64Content: raw,
      message: message,
      branch: _workBranch,
      sha: working!.sha,
    );
  }

  /// Comprueba que [change] sea de verdad un fichero que ya no está en
  /// ninguna de las dos ramas, y no una carpeta que se ha colado hasta aquí.
  ///
  /// Aprobar o rechazar una carpeta se resuelve antes, en [_expandAll], así
  /// que llegar aquí con una es un error: sin esta comprobación, [_fileAt]
  /// devolvía `null` para un directorio y el cambio se daba por resuelto sin
  /// haber escrito nada.
  Future<void> _assertResolvesToFile(PendingChange change) async {
    for (final ref in [_validatedBranch, _workBranch]) {
      if ((await _treeOf(change.path, ref)).isNotEmpty) {
        throw StateError(
          '"${change.name}" es una carpeta, no un fichero: aprueba o rechaza '
          'lo que tiene dentro.',
        );
      }
    }
  }

  /// Motivo legible de un fallo, sin el "Bad state:" que antepone Dart.
  String _describeFailure(Object error) {
    if (error is GitHubError) return error.message ?? '$error';
    if (error is StateError) return error.message;
    return '$error';
  }

  // ---------------------------------------------------------------------
  // Recuperación de las ramas por cambio de la versión anterior
  // ---------------------------------------------------------------------

  /// Ramas sueltas que dejó la versión que guardaba un cambio por rama.
  Future<List<String>> leftoverChangeBranches() async {
    try {
      final branches = await _github.repositories.listBranches(slug).toList();
      return branches
          .map((b) => b.name)
          .whereType<String>()
          .where((n) => n.startsWith(GitHubConfig.legacyChangeBranchPrefix))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Trae a la rama de trabajo lo que quedara en esas ramas sueltas y las
  /// borra, para dejar el espacio funcionando solo con las dos ramas.
  Future<void> recoverLeftoverChangeBranches() async {
    for (final branch in await leftoverChangeBranches()) {
      try {
        await _github.repositories.merge(
          slug,
          CreateMerge(
            _workBranch,
            branch,
            commitMessage: 'Recuperar un cambio pendiente suelto',
          ),
        );
      } catch (e) {
        // Puede que no hubiera nada que traer; se borra igualmente.
        debugPrint('[Versiona] Nada que fusionar de "$branch": $e');
      }
      await _github.git.deleteReference(slug, 'heads/$branch');
    }
    _invalidatePending();
  }
}
