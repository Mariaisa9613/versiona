import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:versiona/models/pending_change.dart';

void main() {
  CommitFile file(String name, String status) =>
      CommitFile(name: name, status: status);

  RepositoryCommit commit(String author, String message, DateTime date) {
    return RepositoryCommit(
      commit: GitCommit(
        message: message,
        author: GitCommitUser(author, '$author@example.com', date),
        committer: GitCommitUser(author, '$author@example.com', date),
      ),
    );
  }

  group('Cambios pendientes deducidos de comparar las dos ramas', () {
    test('cada estado se traduce a lo que ve el usuario', () {
      final changes = PendingChange.fromComparison([
        file('nueva.pdf', 'added'),
        file('vieja.pdf', 'removed'),
        file('corregida.pdf', 'modified'),
      ]);

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

    test('un estado que no conocemos se trata como modificación, que es lo '
        'que menos sorprende', () {
      final changes = PendingChange.fromComparison([
        file('algo.pdf', 'changed'),
      ]);

      expect(changes.single.kind, PendingChangeKind.modified);
    });

    test('sin diferencias no hay nada que revisar', () {
      expect(PendingChange.fromComparison(const []), isEmpty);
    });

    test('separa el nombre de la carpeta que lo contiene', () {
      final change =
          PendingChange.fromComparison([
            file('Facturas/2026/enero.pdf', 'added'),
          ]).single;

      expect(change.name, 'enero.pdf');
      expect(change.parentPath, 'Facturas/2026');
    });

    test('un fichero en la raíz no tiene carpeta padre', () {
      final change =
          PendingChange.fromComparison([file('factura.pdf', 'added')]).single;

      expect(change.name, 'factura.pdf');
      expect(change.parentPath, '');
    });
  });

  group('Quién y cuándo', () {
    test('recoge a todas las personas que lo han tocado, sin repetir, y se '
        'queda con lo más reciente', () {
      final change = PendingChange.fromComparison([
        file('factura.pdf', 'modified'),
      ]).single;

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
      final change =
          PendingChange.fromComparison([file('factura.pdf', 'added')]).single;

      final withHistory = change.withHistory(const []);

      expect(withHistory.authors, isEmpty);
      expect(withHistory.updatedAt, isNull);
      expect(withHistory.commitCount, 0);
    });
  });
}
