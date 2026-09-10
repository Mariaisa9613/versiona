import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:versiona/models/pending_change.dart';

void main() {
  RepositoryCommit commit(String author, String message, DateTime date) {
    return RepositoryCommit(
      commit: GitCommit(
        message: message,
        author: GitCommitUser(author, '$author@example.com', date),
        committer: GitCommitUser(author, '$author@example.com', date),
      ),
    );
  }

  /// Atajo: los cambios que salen de comparar los ficheros de las dos ramas.
  List<PendingChange> diff({
    Map<String, String> approved = const {},
    Map<String, String> working = const {},
  }) => PendingChange.fromTrees(approved: approved, working: working);

  group('Cambios pendientes deducidos de comparar las dos ramas', () {
    test('cada estado se traduce a lo que ve el usuario', () {
      final changes = diff(
        approved: {'vieja.pdf': 'sha-vieja', 'corregida.pdf': 'sha-antes'},
        working: {'nueva.pdf': 'sha-nueva', 'corregida.pdf': 'sha-despues'},
      );

      expect(changes.map((c) => c.path), [
        'corregida.pdf',
        'nueva.pdf',
        'vieja.pdf',
      ]);
      expect(
        changes.firstWhere((c) => c.path == 'nueva.pdf').kind,
        PendingChangeKind.added,
      );
      expect(
        changes.firstWhere((c) => c.path == 'vieja.pdf').kind,
        PendingChangeKind.deleted,
      );
      expect(
        changes.firstWhere((c) => c.path == 'corregida.pdf').kind,
        PendingChangeKind.modified,
      );
    });

    test('sin diferencias no hay nada que revisar', () {
      expect(diff(), isEmpty);
    });

    test('un fichero idéntico en las dos ramas no está pendiente', () {
      // El caso que la comparación de GitHub se comía: aprobar copia el
      // fichero a la rama aprobada sin fusionar nada, así que la base de
      // fusión se queda atrás y `base...head` lo seguía dando por pendiente
      // para siempre. Lo que cuenta es que el contenido ya coincide.
      expect(
        diff(
          approved: {'factura.pdf': 'mismo-sha'},
          working: {'factura.pdf': 'mismo-sha'},
        ),
        isEmpty,
      );
    });

    test('borrar un fichero ya aprobado sí es una baja pendiente', () {
      // Antes esto no salía: el fichero llegó a la rama aprobada por una
      // aprobación, no estaba en la base de fusión, y al borrarlo de la rama
      // de trabajo la comparación no lo daba por eliminado. En pantalla
      // volvía a salir como "Validado", sin baja que aprobar.
      final changes = diff(approved: {'factura.pdf': 'sha'}, working: const {});

      expect(changes.single.path, 'factura.pdf');
      expect(changes.single.kind, PendingChangeKind.deleted);
    });

    test('mover un fichero son dos cambios: el alta y la baja', () {
      final changes = diff(
        approved: {'factura.pdf': 'sha'},
        working: {'Facturas/factura.pdf': 'sha'},
      );

      // Van ordenados por ruta, y "." va antes que "s".
      expect(changes.map((c) => c.path), ['factura.pdf', 'Facturas/factura.pdf']);
      expect(
        changes.firstWhere((c) => c.path == 'Facturas/factura.pdf').kind,
        PendingChangeKind.added,
      );
      expect(
        changes.firstWhere((c) => c.path == 'factura.pdf').kind,
        PendingChangeKind.deleted,
      );
    });

    test('separa el nombre de la carpeta que lo contiene', () {
      final change = diff(working: {'Facturas/2026/enero.pdf': 'sha'}).single;

      expect(change.name, 'enero.pdf');
      expect(change.parentPath, 'Facturas/2026');
    });

    test('un fichero en la raíz no tiene carpeta padre', () {
      final change = diff(working: {'factura.pdf': 'sha'}).single;

      expect(change.name, 'factura.pdf');
      expect(change.parentPath, '');
    });
  });

  group('Quién y cuándo', () {
    test('recoge a todas las personas que lo han tocado, sin repetir, y se '
        'queda con lo más reciente', () {
      final change =
          diff(
            approved: {'factura.pdf': 'antes'},
            working: {'factura.pdf': 'despues'},
          ).single;

      // listCommits los devuelve del más reciente al más antiguo.
      final withHistory = change.withHistory([
        commit('maria', 'Ajuste final', DateTime(2026, 9, 3)),
        commit('juan', 'Corregir el IVA', DateTime(2026, 9, 2)),
        commit('maria', 'Primera versión', DateTime(2026, 9, 1)),
      ]);

      expect(withHistory.authors, ['maria', 'juan']);
      expect(withHistory.message, 'Ajuste final');
      expect(withHistory.updatedAt, DateTime(2026, 9, 3));
      expect(withHistory.commitCount, 3);
      // El cambio en sí no se altera.
      expect(withHistory.path, 'factura.pdf');
      expect(withHistory.kind, PendingChangeKind.modified);
    });

    test('sin historial se queda como estaba', () {
      final change = diff(working: {'factura.pdf': 'sha'}).single;

      final withHistory = change.withHistory(const []);

      expect(withHistory.authors, isEmpty);
      expect(withHistory.updatedAt, isNull);
      expect(withHistory.commitCount, 0);
    });
  });
}
