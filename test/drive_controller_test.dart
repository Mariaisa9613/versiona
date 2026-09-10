import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:versiona/models/drive_entry.dart';
import 'package:versiona/services/drive_service.dart';
import 'package:versiona/state/drive_controller.dart';

/// Servicio guionizado: a cada carpeta responde lo que se le haya puesto en
/// [folders] (una lista, o el error que debe lanzar), y permite dejar una
/// lectura en el aire para probar qué pasa mientras tanto.
class _ScriptedDriveService implements DriveService {
  _ScriptedDriveService(this.folders);

  /// ruta -> lo que devuelve `listFolder`, o el error que lanza.
  final Map<String, Object> folders;

  @override
  String? repoName = 'tesoreria';

  /// Si no es `null`, `listFolder` espera a que se complete.
  Completer<void>? gate;

  @override
  Future<List<DriveEntry>> listFolder(String folderPath) async {
    final blocker = gate;
    if (blocker != null) await blocker.future;

    final answer = folders[folderPath];
    if (answer is Error) throw answer;
    if (answer is Exception) throw answer;
    return (answer as List<DriveEntry>?) ?? const [];
  }

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} no se usa aquí');
}

DriveEntry _file(String name) =>
    DriveEntry(name: name, path: name, type: DriveEntryType.file);

DriveEntry _folder(String name) =>
    DriveEntry(name: name, path: name, type: DriveEntryType.folder);

void main() {
  group('Navegar a una carpeta que falla', () {
    test('no deja en pantalla los ficheros de la carpeta anterior', () async {
      final drive = DriveController(
        _ScriptedDriveService({
          '': [_file('raiz.pdf')],
          'Facturas': StateError('GitHub no responde'),
        }),
      );
      addTearDown(drive.dispose);

      await drive.load();
      expect(drive.entries.map((e) => e.name), ['raiz.pdf']);

      await drive.openFolder(_folder('Facturas'));

      // Lo importante: la lista no se queda con "raiz.pdf", que es de la
      // carpeta anterior y aquí parecería el contenido de "Facturas".
      expect(drive.currentPath, 'Facturas');
      expect(drive.entries, isEmpty);
      expect(drive.error, 'GitHub no responde');
      expect(drive.loading, isFalse);
    });

    test('volver atrás vuelve a cargar bien', () async {
      final drive = DriveController(
        _ScriptedDriveService({
          '': [_file('raiz.pdf')],
          'Facturas': StateError('GitHub no responde'),
        }),
      );
      addTearDown(drive.dispose);

      await drive.load();
      await drive.openFolder(_folder('Facturas'));
      await drive.goToBreadcrumb(-1);

      expect(drive.entries.map((e) => e.name), ['raiz.pdf']);
      expect(drive.error, isNull);
    });
  });

  group('Recargar la misma carpeta', () {
    test('un fallo puntual no borra lo que ya se había cargado', () async {
      final service = _ScriptedDriveService({
        '': [_file('raiz.pdf')],
      });
      final drive = DriveController(service);
      addTearDown(drive.dispose);

      await drive.load();
      expect(drive.entries, hasLength(1));

      service.folders[''] = StateError('Fallo al releer');
      await drive.load();

      // Es la misma carpeta: lo que ya estaba se conserva (p. ej. al releer
      // justo tras subir un fichero) y el error se enseña sin vaciarla.
      expect(drive.entries.map((e) => e.name), ['raiz.pdf']);
      expect(drive.error, 'Fallo al releer');
    });
  });

  group('Cambiar de sitio mientras se está leyendo', () {
    test('la respuesta que llega tarde no pisa a la carpeta actual', () async {
      final service = _ScriptedDriveService({
        '': [_file('raiz.pdf')],
        'Facturas': [_file('enero.pdf')],
      });
      final drive = DriveController(service);
      addTearDown(drive.dispose);

      // La lectura de la raíz se queda en el aire.
      final gate = Completer<void>();
      service.gate = gate;
      final slowRoot = drive.load();

      // Mientras tanto se entra en "Facturas", que sí responde.
      service.gate = null;
      await drive.openFolder(_folder('Facturas'));
      expect(drive.entries.map((e) => e.name), ['enero.pdf']);

      // Ahora contesta la lectura antigua: no debe reemplazar lo que se ve.
      gate.complete();
      await slowRoot;

      expect(drive.currentPath, 'Facturas');
      expect(drive.entries.map((e) => e.name), ['enero.pdf']);
      expect(drive.error, isNull);
    });

    test('cambiar de repositorio no arrastra los ficheros del anterior',
        () async {
      final service = _ScriptedDriveService({
        '': [_file('tesoreria.pdf')],
      });
      final drive = DriveController(service);
      addTearDown(drive.dispose);

      await drive.load();
      expect(drive.entries, hasLength(1));

      // Otro repositorio cuya raíz falla: la raíz es la misma ruta, pero no
      // es el mismo sitio.
      service.repoName = 'contratos';
      service.folders[''] = StateError('GitHub no responde');
      await drive.load();

      expect(drive.entries, isEmpty);
      expect(drive.error, 'GitHub no responde');
    });
  });
}
