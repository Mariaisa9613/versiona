import 'package:github/github.dart';

enum DriveEntryType { file, folder }

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
  });

  final String name;
  final String path;
  final DriveEntryType type;
  final String? sha;
  final int? size;

  bool get isFolder => type == DriveEntryType.folder;

  factory DriveEntry.fromGitHubFile(GitHubFile file) {
    return DriveEntry(
      name: file.name ?? '',
      path: file.path ?? '',
      type: file.type == 'dir' ? DriveEntryType.folder : DriveEntryType.file,
      sha: file.sha,
      size: file.size,
    );
  }
}
