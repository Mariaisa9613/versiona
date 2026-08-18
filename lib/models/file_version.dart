import 'package:github/github.dart';

/// Una versión (commit) concreta de un fichero.
class FileVersion {
  FileVersion({
    required this.sha,
    required this.message,
    required this.authorName,
    this.authorAvatarUrl,
    this.date,
  });

  final String sha;
  final String message;
  final String authorName;
  final String? authorAvatarUrl;
  final DateTime? date;

  factory FileVersion.fromCommit(RepositoryCommit commit) {
    final gitAuthor = commit.commit?.author;
    return FileVersion(
      sha: commit.sha ?? '',
      message:
          (commit.commit?.message ?? '').trim().isEmpty
              ? '(sin mensaje)'
              : commit.commit!.message!.trim(),
      authorName:
          commit.author?.login ?? gitAuthor?.name ?? 'Colaborador desconocido',
      authorAvatarUrl: commit.author?.avatarUrl,
      date: gitAuthor?.date,
    );
  }
}
