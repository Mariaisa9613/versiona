import 'package:flutter/foundation.dart';
import 'package:github/github.dart';

import '../models/drive_entry.dart';
import '../models/file_version.dart';
import '../models/pending_change.dart';
import '../services/drive_service.dart';
import '../utils/error_messages.dart';

enum DriveViewMode { list, kanban }

/// Estado de navegación y contenido de la carpeta actual del Drive.
class DriveController extends ChangeNotifier {
  DriveController(this._service);

  final DriveService _service;

  List<String> _pathSegments = [];
  List<DriveEntry> entries = const [];
  bool loading = true;
  String? error;
  DriveViewMode viewMode = DriveViewMode.list;


  String? get activeRepoName => _service.repoName;

  List<Repository> availableRepos = [];
  bool loadingRepos = false;

  /// Carga la lista de repositorios del usuario para poder elegir entre
  /// ellos como Drive activo. Se llama una vez al abrir el tablero; los
  /// errores se ignoran en silencio porque no es una acción que el usuario
  /// haya pedido explícitamente (el menú simplemente aparecerá vacío).
  Future<void> loadAvailableRepos() async {
    loadingRepos = true;
    notifyListeners();
    try {
      availableRepos = await _service.listAccessibleRepos();
    } catch (_) {
      availableRepos = const [];
    } finally {
      loadingRepos = false;
      notifyListeners();
    }
  }

  /// Cambia el Drive activo a [repo] y recarga el tablero desde su raíz.
  Future<void> switchRepo(Repository repo) async {
    if (_service.repoFullName == repo.fullName) return;
    loading = true;
    error = null;
    notifyListeners();

    try {
      await _service.switchTo(RepositorySlug.full(repo.fullName));
      _pathSegments = [];
      await load();
    } catch (e) {
      error = describeError(
        e,
        fallback: 'No se pudo cambiar al repositorio "${repo.name}".',
      );
      loading = false;
      notifyListeners();
    }
  }

  /// Crea un nuevo repositorio y lo deja como Drive activo. Los fallos (p.ej.
  /// nombre ya usado) se propagan tal cual: quien llame a esto está en un
  /// diálogo propio con su propio manejo de errores, y no debe romper la
  /// vista del repositorio que se estaba usando hasta ahora.
  Future<void> createRepo(String name) async {
    await _service.createRepo(name);
    _pathSegments = [];
    await loadAvailableRepos();
    await load();
  }

  /// Elimina [repo] de GitHub de forma permanente. Si era el Drive activo,
  /// cambia automáticamente a otro de los repositorios restantes (o deja el
  /// tablero vacío con un aviso si no queda ninguno). Igual que
  /// [createRepo], los fallos se propagan para que el diálogo que llama a
  /// esto los muestre por su cuenta.
  Future<void> deleteRepo(Repository repo) async {
    await _service.deleteRepo(RepositorySlug.full(repo.fullName));

    availableRepos =
        availableRepos.where((r) => r.fullName != repo.fullName).toList();

    if (_service.repoFullName == repo.fullName) {
      if (availableRepos.isNotEmpty) {
        await switchRepo(availableRepos.first);
      } else {
        entries = const [];
        _entriesSource = null;
        error =
            'No te queda ningún repositorio. Crea uno nuevo para continuar.';
        loading = false;
      }
    }
    notifyListeners();
  }

  void setViewMode(DriveViewMode mode) {
    if (viewMode == mode) return;
    viewMode = mode;
    notifyListeners();
  }

  List<String> get breadcrumbs => List.unmodifiable(_pathSegments);
  String get currentPath => _pathSegments.join('/');
  bool get isAtRoot => _pathSegments.isEmpty;

  /// De qué repositorio y carpeta es lo que hay ahora mismo en [entries].
  ///
  /// Conservar la lista cuando falla una recarga solo tiene sentido si es de
  /// **este** sitio. Sin distinguirlo, entrar en una carpeta cuya lectura
  /// fallaba dejaba en pantalla los ficheros de la carpeta anterior, sin
  /// ningún aviso: parecían los de la carpeta recién abierta.
  String? _entriesSource;

  String get _currentSource => '${_service.repoName}:$currentPath';

  Future<void> load() async {
    final source = _currentSource;
    if (_entriesSource != source) {
      // Sitio distinto: lo que hubiera ya no describe dónde estamos.
      entries = const [];
      _entriesSource = source;
    }
    loading = true;
    error = null;
    notifyListeners();

    List<DriveEntry>? loaded;
    String? failure;
    try {
      loaded = await _service.listFolder(currentPath);
    } catch (e) {
      failure = describeError(
        e,
        fallback: 'No se pudo cargar el contenido de esta carpeta.',
      );
    }

    // Se pudo cambiar de carpeta o de repositorio mientras se leía: lo que
    // acaba de llegar ya no es de donde estamos, y hay otra carga en marcha
    // que sí lo es.
    if (_currentSource != source) return;

    if (loaded != null) {
      entries = loaded;
    } else {
      // Si ya había una lista válida de esta misma carpeta (p. ej.
      // recargando tras subir un fichero), la conservamos en vez de
      // vaciarla: un fallo transitorio al releer no debería hacer
      // desaparecer contenido que sí se guardó.
      error = failure;
    }
    loading = false;
    notifyListeners();
  }

  Future<void> openFolder(DriveEntry entry) async {
    _pathSegments = [..._pathSegments, entry.name];
    await load();
  }

  /// Navega a un nivel concreto de las migas de pan.
  /// [index] == -1 vuelve a la raíz del Drive.
  Future<void> goToBreadcrumb(int index) async {
    _pathSegments = index < 0 ? [] : _pathSegments.sublist(0, index + 1);
    await load();
  }

  /// Sube [bytes] con el nombre y mensaje de commit que devuelva [prepare].
  ///
  /// La entrada aparece en la lista **al momento**, con [placeholderName] y
  /// su indicador de carga, y el reconocimiento de texto y la subida ocurren
  /// por detrás. Así fotografiar un ticket se siente inmediato aunque el OCR
  /// tarde unos segundos, y mientras tanto se puede seguir usando la app.
  /// Al terminar, la entrada provisional se sustituye por la real (que puede
  /// llamarse distinto, si el OCR ha reconocido un número de factura).
  Future<void> uploadFile(
    List<int> bytes,
    Future<(String fileName, String? commitMessage)> Function() prepare, {
    required String placeholderName,
  }) async {
    final folder = currentPath;
    final placeholder = DriveEntry(
      name: placeholderName,
      path: folder.isEmpty ? placeholderName : '$folder/$placeholderName',
      type: DriveEntryType.file,
      uploading: true,
    );
    _upsertEntry(placeholder);
    notifyListeners();

    try {
      final (fileName, commitMessage) = await prepare();
      final uploaded = await _service.uploadFile(
        folderPath: folder,
        fileName: fileName,
        bytes: bytes,
        commitMessage: commitMessage,
      );
      // Puede haberse cambiado de carpeta mientras tanto: en ese caso lo
      // subido no pinta nada en lo que se está viendo ahora.
      if (folder != currentPath) return;
      _removeEntry(placeholder.path);
      _upsertEntry(uploaded);
    } catch (_) {
      if (folder == currentPath) _removeEntry(placeholder.path);
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  /// Crea la carpeta y la añade a la lista al momento, por el mismo motivo
  /// que [uploadFile].
  Future<void> createFolder(String name) async {
    final folder = await _service.createFolder(
      folderPath: currentPath,
      name: name,
    );
    _upsertEntry(folder);
    notifyListeners();
  }

  /// Inserta o reemplaza (por ruta) una entrada en la lista actual,
  /// manteniendo el mismo orden que usa [DriveService.listFolder]:
  /// carpetas primero, y alfabético dentro de cada grupo.
  void _upsertEntry(DriveEntry entry) {
    entries = [
      ...entries.where((e) => e.path != entry.path),
      entry,
    ]..sort((a, b) {
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  /// Borra [entry] y refleja al momento **cómo queda**, que es lo que dice el
  /// servicio: normalmente sigue en la lista marcada como pendiente de
  /// eliminarse (hasta que se apruebe la baja, la versión aprobada la sigue
  /// teniendo), y solo desaparece del todo si era algo que nunca llegó a
  /// aprobarse.
  ///
  /// La clave es que esto coincida exactamente con lo que se vería al
  /// recargar: si no, la entrada desaparece y vuelve a aparecer sola, que es
  /// justo lo que desconcierta.
  Future<void> deleteEntry(DriveEntry entry) async {
    final result = await _service.deleteEntry(entry);
    if (result == null) {
      entries = entries.where((e) => e.path != entry.path).toList();
    } else {
      _upsertEntry(result);
    }
    notifyListeners();
  }

  /// Renombra [entry] y refleja al momento cómo queda, por el mismo motivo
  /// que [deleteEntry].
  Future<void> rename(DriveEntry entry, String newName) async {
    final renamed = await _service.rename(entry: entry, newName: newName);
    entries = entries.where((e) => e.path != entry.path).toList();
    _upsertEntry(renamed);
    notifyListeners();
  }

  /// Mueve [entry] y, si ha salido de la carpeta actual (el caso normal:
  /// nadie mueve un fichero a la carpeta en la que ya está), lo quita de la
  /// lista al momento; si se queda en la misma carpeta, lo actualiza.
  Future<void> move(DriveEntry entry, String destinationFolderPath) async {
    final moved = await _service.move(
      entry: entry,
      destinationFolderPath: destinationFolderPath,
    );
    entries = entries.where((e) => e.path != entry.path).toList();
    if (destinationFolderPath == currentPath) _upsertEntry(moved);
    notifyListeners();
  }

  /// Un fichero pendiente de eliminarse ya no está en la rama de trabajo:
  /// para verlo hay que ir a la versión aprobada.
  bool _onlyInApproved(DriveEntry entry) =>
      entry.pendingChange?.kind == PendingChangeKind.deleted;

  String webUrlFor(DriveEntry entry) =>
      _service.webUrlFor(entry.path, approved: _onlyInApproved(entry));

  Future<List<FileVersion>> fileHistory(DriveEntry entry) =>
      _service.fileHistory(entry.path);

  Future<Uint8List> fetchFileBytes(DriveEntry entry) =>
      _service.fetchFileBytes(entry.path, approved: _onlyInApproved(entry));

  Future<void> restoreVersion(DriveEntry entry, FileVersion version) async {
    await _service.restoreVersion(
      path: entry.path,
      versionSha: version.sha,
      fileName: entry.name,
    );
    await load();
  }

  /// Cuántas ramas sueltas dejó la versión que guardaba un cambio por rama,
  /// o 0 si no hay nada que recuperar. Se comprueba una sola vez por sesión:
  /// es una situación transitoria que deja de darse al resolverla.
  int leftoverBranches = 0;
  bool _leftoverChecked = false;

  Future<void> checkLeftoverBranches() async {
    if (_leftoverChecked) return;
    _leftoverChecked = true;
    try {
      leftoverBranches = (await _service.leftoverChangeBranches()).length;
    } catch (_) {
      leftoverBranches = 0;
    }
    notifyListeners();
  }

  /// Trae a la rama de trabajo lo que quedara en esas ramas sueltas y las
  /// borra, para dejar el espacio funcionando solo con las dos ramas.
  Future<void> recoverLeftoverBranches() async {
    await _service.recoverLeftoverChangeBranches();
    leftoverBranches = 0;
    await load();
  }

  /// Oculta el aviso sin hacer nada: volverá a aparecer en la próxima sesión
  /// mientras queden ramas sueltas.
  void dismissLeftoverNotice() {
    leftoverBranches = 0;
    notifyListeners();
  }

  /// Aprueba [changes] (uno o varios): cada fichero pasa a la versión
  /// aprobada tal y como está. Devuelve el resultado de cada uno, para poder
  /// avisar si alguno no ha podido aprobarse.
  ///
  /// No se recarga la carpeta: ya sabemos cómo queda cada fichero, y esperar
  /// a que GitHub sirva el contenido nuevo añadía segundos de espera por cada
  /// cambio. Lo que se pinta aquí es exactamente lo que se vería al recargar.
  Future<List<ChangeResult>> approveChanges(
    List<PendingChange> changes, {
    String? summary,
  }) async {
    final results = await _service.approveChanges(changes, summary: summary);
    // Aprobar una baja la hace efectiva: el fichero ya no está en ningún
    // sitio. Aprobar cualquier otro cambio lo deja validado, donde está.
    _applyResolved(
      changes,
      results,
      disappears: (change) => change.kind == PendingChangeKind.deleted,
    );
    return results;
  }

  /// Descarta [changes] (uno o varios): la versión aprobada se queda
  /// exactamente como estaba.
  Future<List<ChangeResult>> rejectChanges(List<PendingChange> changes) async {
    final results = await _service.rejectChanges(changes);
    // Rechazar algo que nunca se aprobó lo hace desaparecer; en el resto de
    // casos el fichero vuelve a como estaba en la versión aprobada.
    _applyResolved(
      changes,
      results,
      disappears: (change) => change.kind == PendingChangeKind.added,
    );
    return results;
  }

  /// Refleja en la lista los cambios que se han resuelto.
  ///
  /// Se recorre lo que se pidió resolver, no los resultados: al aprobar o
  /// rechazar una carpeta, el servicio la sustituye por los ficheros que
  /// tiene dentro, y lo que hay en la lista es la carpeta. Si alguno de esos
  /// ficheros ha fallado, la carpeta se deja como estaba.
  void _applyResolved(
    List<PendingChange> requested,
    List<ChangeResult> results, {
    required bool Function(PendingChange change) disappears,
  }) {
    final failed = results.where((r) => !r.ok).map((r) => r.change.path);

    for (final change in requested) {
      final somethingFailed = failed.any(
        (path) => path == change.path || path.startsWith('${change.path}/'),
      );
      if (somethingFailed) continue;

      if (disappears(change)) {
        _removeEntry(change.path);
      } else {
        _markValidated(change.path);
      }
    }
    notifyListeners();
  }

  void _removeEntry(String path) {
    entries = entries.where((e) => e.path != path).toList();
  }

  void _markValidated(String path) {
    entries = [
      for (final entry in entries)
        if (entry.path == path) entry.asValidated() else entry,
    ];
  }
}
