import 'package:github/github.dart';

/// Qué le pasa a un fichero o carpeta respecto a la versión aprobada.
enum PendingChangeKind {
  /// No existe en la versión aprobada: es nuevo.
  added,

  /// Existe y se ha modificado su contenido.
  modified,

  /// Existe en la versión aprobada y está pendiente de eliminarse.
  deleted,
}

/// Un cambio pendiente de aprobación: la diferencia entre cómo está un
/// fichero en la rama de trabajo (lo que se ve en el Drive) y cómo está en
/// la versión aprobada.
///
/// Solo los ficheros tienen cambios. Una carpeta no cambia por sí misma: lo
/// que cambia es lo que hay dentro.
///
/// Da igual cuántas veces se haya tocado el fichero: lo que cuenta es la
/// diferencia final, y se aprueba o se rechaza entera.
class PendingChange {
  const PendingChange({
    required this.path,
    required this.kind,
    this.authors = const [],
    this.updatedAt,
    this.message,
    this.commitCount = 0,
  });

  /// Ruta del fichero afectado.
  final String path;

  final PendingChangeKind kind;

  /// Quién ha participado en este cambio, de lo más reciente a lo más
  /// antiguo. Pueden ser varias personas.
  final List<String> authors;

  /// Cuándo se tocó por última vez.
  final DateTime? updatedAt;

  /// Mensaje del commit más reciente (el motivo que escribió quien lo hizo).
  final String? message;

  final int commitCount;

  String get name {
    final index = path.lastIndexOf('/');
    return index == -1 ? path : path.substring(index + 1);
  }

  String get parentPath {
    final index = path.lastIndexOf('/');
    return index == -1 ? '' : path.substring(0, index);
  }

  /// El mismo cambio con los datos de quién y cuándo, que se consultan
  /// aparte porque la comparación entre ramas no los trae por fichero.
  PendingChange withHistory(List<RepositoryCommit> commits) {
    final authors = <String>[];
    for (final commit in commits) {
      final login = commit.author?.login ?? commit.commit?.author?.name;
      if (login != null && !authors.contains(login)) authors.add(login);
    }

    final latest = commits.isEmpty ? null : commits.first;
    return PendingChange(
      path: path,
      kind: kind,
      authors: authors,
      updatedAt:
          latest?.commit?.committer?.date ?? latest?.commit?.author?.date,
      message: latest?.commit?.message,
      commitCount: commits.length,
    );
  }

  /// Los cambios pendientes que salen de comparar los ficheros de la versión
  /// aprobada con los de la rama de trabajo. Cada mapa va de ruta al sha de
  /// su contenido, así que dos rutas con el mismo sha son el mismo fichero
  /// byte a byte.
  ///
  /// Se comparan **los ficheros que hay ahora en cada rama**, no el
  /// historial. La API de comparación de GitHub (`base...head`) mide contra
  /// la *base de fusión* de las dos ramas, no contra la punta de la base; y
  /// como aprobar no fusiona nada, esa base nunca avanza. Con ella, un
  /// fichero ya aprobado seguía contando como pendiente para siempre
  /// (llegando a bloquear el borrado de su carpeta), y la baja de un
  /// fichero que se había aprobado no aparecía en absoluto.
  ///
  /// Un renombrado o un movimiento aparecen como dos cambios: el fichero
  /// nuevo en su sitio y la baja del anterior. Es lo que de verdad ha
  /// pasado, y así cada mitad se puede aprobar o rechazar por separado.
  static List<PendingChange> fromTrees({
    required Map<String, String> approved,
    required Map<String, String> working,
  }) {
    final changes = <PendingChange>[];

    for (final entry in working.entries) {
      final approvedSha = approved[entry.key];
      if (approvedSha == entry.value) continue; // Idéntico: nada que revisar.
      changes.add(
        PendingChange(
          path: entry.key,
          kind:
              approvedSha == null
                  ? PendingChangeKind.added
                  : PendingChangeKind.modified,
        ),
      );
    }

    // Lo que está aprobado y ya no está en la rama de trabajo es una baja
    // pendiente de aprobarse.
    for (final path in approved.keys) {
      if (working.containsKey(path)) continue;
      changes.add(PendingChange(path: path, kind: PendingChangeKind.deleted));
    }

    changes.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return changes;
  }
}
