import 'package:github/github.dart';

enum DriveEntryType { file, folder }

/// Estado de aprobación de un fichero o carpeta frente a la versión
/// validada (la rama por defecto del repositorio).
enum ReviewStatus {
  /// El contenido coincide con la versión validada: es la versión oficial.
  validated,

  /// Hay cambios sin aprobar (la rama de revisión difiere de la validada
  /// en esta ruta).
  inReview,
}

/// Representa un fichero o carpeta dentro del "Drive" del usuario.
///
/// Las carpetas no existen como tal en Git: se infieren de los prefijos de
/// ruta de los ficheros (p.ej. "Fotos/verano.jpg" implica la carpeta "Fotos").
class DriveEntry {
  DriveEntry({
    required this.name,
    required this.path,
    required this.type,
    this.sha,
    this.size,
    this.status = ReviewStatus.validated,
  });

  final String name;
  final String path;
  final DriveEntryType type;
  final String? sha;
  final int? size;
  final ReviewStatus status;

  bool get isFolder => type == DriveEntryType.folder;

  factory DriveEntry.fromGitHubFile(
    GitHubFile file, {
    ReviewStatus status = ReviewStatus.validated,
  }) {
    return DriveEntry(
      name: file.name ?? '',
      path: file.path ?? '',
      type: file.type == 'dir' ? DriveEntryType.folder : DriveEntryType.file,
      sha: file.sha,
      size: file.size,
      status: status,
    );
  }
}
