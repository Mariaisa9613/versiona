import 'package:flutter/foundation.dart';
import 'package:github/github.dart';

import '../models/drive_entry.dart';
import '../models/file_version.dart';
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
    if (_service.repoName == repo.name) return;
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

    if (_service.repoName == repo.name) {
      if (availableRepos.isNotEmpty) {
        await switchRepo(availableRepos.first);
      } else {
        entries = const [];
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

  Future<void> load() async {
    loading = true;
    error = null;
    notifyListeners();

    try {
      entries = await _service.listFolder(currentPath);
    } catch (e) {
      error = describeError(
        e,
        fallback: 'No se pudo cargar el contenido de esta carpeta.',
      );
      entries = const [];
    } finally {
      loading = false;
      notifyListeners();
    }
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

  Future<void> uploadFile(
    String fileName,
    List<int> bytes, {
    String? commitMessage,
  }) async {
    await _service.uploadFile(
      folderPath: currentPath,
      fileName: fileName,
      bytes: bytes,
      commitMessage: commitMessage,
    );
    await load();
  }

  Future<void> createFolder(String name) async {
    await _service.createFolder(folderPath: currentPath, name: name);
    await load();
  }

  Future<void> deleteEntry(DriveEntry entry) async {
    await _service.deleteEntry(entry);
    await load();
  }

  Future<void> rename(DriveEntry entry, String newName) async {
    await _service.rename(entry: entry, newName: newName);
    await load();
  }

  Future<void> move(DriveEntry entry, String destinationFolderPath) async {
    await _service.move(
      entry: entry,
      destinationFolderPath: destinationFolderPath,
    );
    await load();
  }

  String webUrlFor(DriveEntry entry) => _service.webUrlFor(entry.path);

  Future<List<FileVersion>> fileHistory(DriveEntry entry) =>
      _service.fileHistory(entry.path);

  Future<void> restoreVersion(DriveEntry entry, FileVersion version) async {
    await _service.restoreVersion(
      path: entry.path,
      versionSha: version.sha,
      fileName: entry.name,
    );
    await load();
  }

  /// Aprueba TODOS los cambios pendientes en revisión (no solo un fichero
  /// concreto) y los consolida como la versión oficial.
  Future<void> approveAndConsolidate({String? summary}) async {
    await _service.approveAndConsolidate(summary: summary);
    await load();
  }
}
