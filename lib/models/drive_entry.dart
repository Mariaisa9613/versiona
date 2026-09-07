import 'package:github/github.dart';

import 'pending_change.dart';

enum DriveEntryType { file, folder }

/// Estado de aprobación de un fichero o carpeta frente a la versión
/// validada (la rama por defecto del repositorio).
enum ReviewStatus {
  /// El contenido coincide con la versión validada: es la versión oficial.
  validated,

  /// Hay cambios sin aprobar: existe una rama de cambio pendiente para esta
  /// ruta (ver [DriveEntry.pendingChange]).
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
    this.pendingChange,
    this.uploading = false,
  });

  final String name;
  final String path;
  final DriveEntryType type;
  final String? sha;
  final int? size;

  /// Se está subiendo ahora mismo: se enseña ya en la lista (con su
  /// indicador) mientras por detrás se reconoce el texto y se guarda, para
  /// que la acción se sienta inmediata. Todavía no existe en el repositorio.
  final bool uploading;

  /// El cambio sin aprobar que afecta a esta entrada, o `null` si lo que se
  /// ve aquí es exactamente la versión aprobada.
  final PendingChange? pendingChange;

  bool get isFolder => type == DriveEntryType.folder;

  ReviewStatus get status =>
      pendingChange == null ? ReviewStatus.validated : ReviewStatus.inReview;

  /// La misma entrada, marcada con el cambio pendiente que la afecta.
  DriveEntry withPendingChange(PendingChange change) => DriveEntry(
    name: name,
    path: path,
    type: type,
    sha: sha,
    size: size,
    pendingChange: change,
  );

  /// La misma entrada, ya sin nada pendiente: es la versión aprobada.
  DriveEntry asValidated() =>
      DriveEntry(name: name, path: path, type: type, sha: sha, size: size);

  factory DriveEntry.fromGitHubFile(
    GitHubFile file, {
    PendingChange? pendingChange,
  }) {
    return DriveEntry(
      name: file.name ?? '',
      path: file.path ?? '',
      type: file.type == 'dir' ? DriveEntryType.folder : DriveEntryType.file,
      sha: file.sha,
      size: file.size,
      pendingChange: pendingChange,
    );
  }
}
