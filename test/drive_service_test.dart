import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github/github.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:versiona/models/drive_entry.dart';
import 'package:versiona/models/pending_change.dart';
import 'package:versiona/services/drive_service.dart';
import 'package:versiona/state/drive_controller.dart';

/// Un repositorio de GitHub de mentira, con las dos ramas que usa Versiona y
/// solo los endpoints que toca el servicio.
///
/// Guarda el contenido de cada fichero por rama y deriva el sha de ese
/// contenido, que es lo que hace Git: dos ficheros con el mismo contenido
/// tienen el mismo sha, y de ahí sale todo el estado de aprobación.
class _FakeGitHub {
  _FakeGitHub({
    Map<String, String> validated = const {},
    Map<String, String> working = const {},
  }) : branches = {
         'main': Map.of(validated),
         'en-revision': Map.of(working),
       };

  /// rama -> (ruta -> contenido).
  final Map<String, Map<String, String>> branches;

  Map<String, String> get validated => branches['main']!;
  Map<String, String> get working => branches['en-revision']!;

  static String _sha(String content) => md5.convert(utf8.encode(content)).toString();

  DriveService build() {
    final github = GitHub(client: MockClient(_handle));
    return DriveService(github);
  }

  http.Response _json(Object body, [int status = 200]) => http.Response(
    jsonEncode(body),
    status,
    headers: const {'content-type': 'application/json'},
  );

  Map<String, dynamic> _fileJson(String path, String content) {
    final name = path.contains('/') ? path.split('/').last : path;
    return {
      'name': name,
      'path': path,
      'sha': _sha(content),
      'size': content.length,
      'type': 'file',
      'encoding': 'base64',
      'content': base64Encode(utf8.encode(content)),
    };
  }

  /// Lo que hay directamente dentro de [folder] en [branch]: los ficheros de
  /// ese nivel y las carpetas que se deducen de las rutas más profundas.
  List<Map<String, dynamic>> _dirJson(String folder, Map<String, String> tree) {
    final prefix = folder.isEmpty ? '' : '$folder/';
    final entries = <String, Map<String, dynamic>>{};

    for (final path in tree.keys) {
      if (!path.startsWith(prefix)) continue;
      final rest = path.substring(prefix.length);
      if (rest.isEmpty) continue;

      if (rest.contains('/')) {
        final name = rest.split('/').first;
        entries['$prefix$name'] ??= {
          'name': name,
          'path': '$prefix$name',
          'sha': 'tree-$prefix$name',
          'type': 'dir',
        };
      } else {
        entries[path] = _fileJson(path, tree[path]!);
      }
    }
    return entries.values.toList();
  }

  /// Peticiones recibidas, como "MÉTODO ruta".
  final List<String> requests = [];

  /// Cuántas peticiones ha llegado a haber en vuelo a la vez.
  int maxInFlight = 0;
  int _inFlight = 0;

  /// Si devuelve `true` para una petición, se contesta con el 403 del límite
  /// secundario de GitHub.
  bool Function(http.Request request)? rateLimited;

  Future<http.Response> _handle(http.Request request) async {
    requests.add('${request.method} ${request.url.path}');
    if (rateLimited?.call(request) ?? false) {
      return _json({
        'message':
            'You have exceeded a secondary rate limit. Please wait a few '
            'minutes before you try again.',
      }, 403);
    }

    _inFlight++;
    if (_inFlight > maxInFlight) maxInFlight = _inFlight;
    try {
      // Un respiro para que las peticiones lanzadas a la vez coincidan en
      // vuelo, como pasaría contra GitHub de verdad.
      await Future<void>.delayed(Duration.zero);
      return await _route(request);
    } finally {
      _inFlight--;
    }
  }

  Future<http.Response> _route(http.Request request) async {
    final path = request.url.path;
    final query = request.url.queryParameters;

    // Repositorio, para que switchTo pueda adoptarlo.
    if (path == '/repos/o/r' && request.method == 'GET') {
      return _json({
        'name': 'r',
        'full_name': 'o/r',
        'default_branch': 'main',
        'private': true,
      });
    }

    // Punta de una rama. Una rama que no existe se responde sin "commit",
    // que es como se comporta el paquete `github` ante un 404 aquí.
    if (path.startsWith('/repos/o/r/branches/')) {
      final branch = path.substring('/repos/o/r/branches/'.length);
      if (!branches.containsKey(branch)) return _json(const {});
      return _json({
        'name': branch,
        'commit': {'sha': 'tip-$branch'},
      });
    }

    // Árbol completo de una rama.
    if (path.startsWith('/repos/o/r/git/trees/')) {
      final tip = path.substring('/repos/o/r/git/trees/'.length);
      final tree = branches[tip.replaceFirst('tip-', '')] ?? const {};
      return _json({
        'sha': tip,
        'truncated': false,
        'tree': [
          for (final entry in tree.entries)
            {
              'path': entry.key,
              'type': 'blob',
              'sha': _sha(entry.value),
              'size': entry.value.length,
            },
        ],
      });
    }

    // El historial no aporta nada a estos tests.
    if (path == '/repos/o/r/commits') return _json(const []);

    if (path.startsWith('/repos/o/r/contents/')) {
      final target = Uri.decodeComponent(
        path.substring('/repos/o/r/contents/'.length),
      );
      final body =
          request.body.isEmpty
              ? const <String, dynamic>{}
              : jsonDecode(request.body) as Map<String, dynamic>;
      final branch = query['ref'] ?? body['branch'] as String? ?? 'main';
      final tree = branches[branch];
      if (tree == null) return _json({'message': 'Branch not found'}, 404);

      switch (request.method) {
        case 'GET':
          final content = tree[target];
          if (content != null) return _json(_fileJson(target, content));
          final children = _dirJson(target, tree);
          // La raíz de una rama siempre existe, aunque esté vacía: GitHub
          // responde con una lista vacía, no con un 404.
          if (children.isNotEmpty || target.isEmpty) return _json(children);
          return _json({'message': 'Not Found'}, 404);

        case 'PUT':
          final content = utf8.decode(
            base64Decode(body['content'] as String),
          );
          tree[target] = content;
          return _json({'content': _fileJson(target, content)});

        case 'DELETE':
          tree.remove(target);
          return _json({'content': null});
      }
    }

    return _json({'message': 'Sin ruta para ${request.method} $path'}, 404);
  }
}

Future<DriveService> _driveOn(_FakeGitHub github) async {
  final service = github.build();
  await service.switchTo(RepositorySlug('o', 'r'));
  return service;
}

void main() {
  group('Qué está pendiente de aprobación', () {
    test('un fichero ya aprobado deja de estar pendiente', () async {
      // Aprobar copia el fichero a la rama aprobada sin fusionar nada. La
      // comparación de GitHub (base...head) mide contra la base de fusión,
      // que nunca avanza, y por eso lo seguía dando por pendiente para
      // siempre: llegaba a bloquear el borrado de su carpeta sin salida.
      final github = _FakeGitHub(
        validated: {'factura.pdf': 'contenido aprobado'},
        working: {'factura.pdf': 'contenido aprobado'},
      );
      final drive = await _driveOn(github);

      expect(await drive.pendingChanges(), isEmpty);
    });

    test('un fichero modificado sin aprobar sí está pendiente', () async {
      final github = _FakeGitHub(
        validated: {'factura.pdf': 'v1'},
        working: {'factura.pdf': 'v2'},
      );
      final drive = await _driveOn(github);

      final pending = await drive.pendingChanges();
      expect(pending.single.path, 'factura.pdf');
      expect(pending.single.kind, PendingChangeKind.modified);
    });

    test('borrar un fichero ya aprobado sale como baja pendiente', () async {
      // Este era el peor: el fichero había llegado a la rama aprobada por una
      // aprobación, así que no estaba en la base de fusión y su borrado no
      // aparecía en la comparación. En pantalla volvía a salir "Validado",
      // sin ninguna baja que aprobar.
      final github = _FakeGitHub(
        validated: {'factura.pdf': 'contenido'},
        working: const {},
      );
      final drive = await _driveOn(github);

      final pending = await drive.pendingChanges();
      expect(pending.single.path, 'factura.pdf');
      expect(pending.single.kind, PendingChangeKind.deleted);

      final entry = (await drive.listFolder('')).single;
      expect(entry.name, 'factura.pdf');
      expect(entry.status, ReviewStatus.inReview);
      expect(entry.pendingChange!.kind, PendingChangeKind.deleted);
    });

    test('el fichero interno de las carpetas no cuenta como cambio', () async {
      final github = _FakeGitHub(
        validated: const {},
        working: {'Facturas/.versiona-keep': 'marcador'},
      );
      final drive = await _driveOn(github);

      expect(await drive.pendingChanges(), isEmpty);
    });
  });

  group('Carpetas con todo aprobado', () {
    test('se pueden borrar: no quedan cambios pendientes dentro', () async {
      final github = _FakeGitHub(
        validated: {'Facturas/enero.pdf': 'igual', 'Facturas/febrero.pdf': 'igual'},
        working: {'Facturas/enero.pdf': 'igual', 'Facturas/febrero.pdf': 'igual'},
      );
      final drive = await _driveOn(github);

      final folder = DriveEntry(
        name: 'Facturas',
        path: 'Facturas',
        type: DriveEntryType.folder,
      );

      // Antes esto lanzaba "esta carpeta tiene 2 cambios pendientes dentro",
      // aunque estuvieran los dos aprobados, y no había forma de resolverlo.
      final result = await drive.deleteEntry(folder);

      expect(github.working, isEmpty);
      expect(result, isNotNull);
      expect(result!.pendingChange!.kind, PendingChangeKind.deleted);
    });

    test('con algo sin aprobar dentro, sigue sin poder borrarse', () async {
      final github = _FakeGitHub(
        validated: {'Facturas/enero.pdf': 'v1'},
        working: {'Facturas/enero.pdf': 'v2'},
      );
      final drive = await _driveOn(github);

      await expectLater(
        drive.deleteEntry(
          DriveEntry(
            name: 'Facturas',
            path: 'Facturas',
            type: DriveEntryType.folder,
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('cambio pendiente'),
          ),
        ),
      );
    });
  });

  group('Aprobar y rechazar una carpeta', () {
    test('aprobar su baja borra de verdad los ficheros de dentro', () async {
      // La carpeta se borró de la rama de trabajo y está pendiente de que se
      // apruebe la baja. Antes, aprobarla no escribía nada (una ruta de
      // carpeta no es ningún fichero) y aun así decía que había ido bien: la
      // carpeta desaparecía de la vista y reaparecía al recargar.
      final github = _FakeGitHub(
        validated: {'Facturas/enero.pdf': 'a', 'Facturas/febrero.pdf': 'b'},
        working: const {},
      );
      final drive = await _driveOn(github);

      final results = await drive.approveChanges([
        const PendingChange(path: 'Facturas', kind: PendingChangeKind.deleted),
      ]);

      expect(results, hasLength(2));
      expect(results.every((r) => r.ok), isTrue);
      expect(results.map((r) => r.change.path), containsAll(<String>[
        'Facturas/enero.pdf',
        'Facturas/febrero.pdf',
      ]));
      expect(github.validated, isEmpty);
    });

    test('rechazar su baja devuelve los ficheros a la rama de trabajo',
        () async {
      final github = _FakeGitHub(
        validated: {'Facturas/enero.pdf': 'a', 'Facturas/febrero.pdf': 'b'},
        working: const {},
      );
      final drive = await _driveOn(github);

      final results = await drive.rejectChanges([
        const PendingChange(path: 'Facturas', kind: PendingChangeKind.deleted),
      ]);

      expect(results.every((r) => r.ok), isTrue);
      expect(github.working, {
        'Facturas/enero.pdf': 'a',
        'Facturas/febrero.pdf': 'b',
      });
      expect(github.validated, hasLength(2));
    });

    test('aprobar una carpeta nueva la lleva entera a la versión aprobada',
        () async {
      final github = _FakeGitHub(
        validated: const {},
        working: {'Facturas/enero.pdf': 'a', 'Facturas/febrero.pdf': 'b'},
      );
      final drive = await _driveOn(github);

      final results = await drive.approveChanges([
        const PendingChange(path: 'Facturas', kind: PendingChangeKind.added),
      ]);

      expect(results.every((r) => r.ok), isTrue);
      expect(github.validated, {
        'Facturas/enero.pdf': 'a',
        'Facturas/febrero.pdf': 'b',
      });
      expect(await drive.pendingChanges(forceRefresh: true), isEmpty);
    });

    test('una carpeta que no resuelve a ningún fichero se reporta, no se da '
        'por buena', () async {
      final github = _FakeGitHub(
        validated: {'Facturas/enero.pdf': 'a'},
        working: {'Facturas/enero.pdf': 'a'},
      );
      final drive = await _driveOn(github);

      // No hay nada pendiente dentro, así que no hay nada que expandir y la
      // ruta llega tal cual: es una carpeta, y decirlo es mejor que informar
      // de un éxito que no ha ocurrido.
      final results = await drive.approveChanges([
        const PendingChange(path: 'Facturas', kind: PendingChangeKind.deleted),
      ]);

      expect(results.single.ok, isFalse);
      // Con el nombre dentro: el mensaje va tal cual a la interfaz.
      expect(results.single.error, '"Facturas" es una carpeta, no un fichero: '
          'aprueba o rechaza lo que tiene dentro.');
      expect(github.validated, hasLength(1));
    });
  });

  group('Aprobar y rechazar un fichero', () {
    test('aprobar una modificación la lleva a la versión aprobada', () async {
      final github = _FakeGitHub(
        validated: {'factura.pdf': 'v1'},
        working: {'factura.pdf': 'v2'},
      );
      final drive = await _driveOn(github);

      final results = await drive.approveChanges([
        const PendingChange(
          path: 'factura.pdf',
          kind: PendingChangeKind.modified,
        ),
      ]);

      expect(results.single.ok, isTrue);
      expect(github.validated['factura.pdf'], 'v2');
      expect(await drive.pendingChanges(forceRefresh: true), isEmpty);
    });

    test('rechazar una modificación la devuelve a como estaba', () async {
      final github = _FakeGitHub(
        validated: {'factura.pdf': 'v1'},
        working: {'factura.pdf': 'v2'},
      );
      final drive = await _driveOn(github);

      final results = await drive.rejectChanges([
        const PendingChange(
          path: 'factura.pdf',
          kind: PendingChangeKind.modified,
        ),
      ]);

      expect(results.single.ok, isTrue);
      expect(github.working['factura.pdf'], 'v1');
      expect(await drive.pendingChanges(forceRefresh: true), isEmpty);
    });

    test('rechazar algo que nunca se aprobó lo quita del todo', () async {
      final github = _FakeGitHub(
        validated: const {},
        working: {'borrador.pdf': 'x'},
      );
      final drive = await _driveOn(github);

      final results = await drive.rejectChanges([
        const PendingChange(path: 'borrador.pdf', kind: PendingChangeKind.added),
      ]);

      expect(results.single.ok, isTrue);
      expect(github.working, isEmpty);
    });
  });

  group('Mover y renombrar', () {
    DriveEntry file(String path) => DriveEntry(
      name: path.split('/').last,
      path: path,
      type: DriveEntryType.file,
    );

    final folder = DriveEntry(
      name: 'F',
      path: 'F',
      type: DriveEntryType.folder,
    );

    Iterable<String> writes(_FakeGitHub github) => github.requests.where(
      (r) => r.startsWith('PUT ') || r.startsWith('DELETE '),
    );

    test('sobre un fichero con el mismo nombre se para antes de tocar nada',
        () async {
      // Antes se intentaba crear la copia sin sha, GitHub la rechazaba, y
      // con una carpeta quedaba parte duplicada y nada borrado.
      final files = {'a.pdf': 'mío', 'Destino/a.pdf': 'otro'};
      final github = _FakeGitHub(validated: files, working: files);
      final drive = await _driveOn(github);

      await expectLater(
        drive.move(entry: file('a.pdf'), destinationFolderPath: 'Destino'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Ya existe "a.pdf" en esa carpeta.',
          ),
        ),
      );
      expect(github.working, files);
      expect(writes(github), isEmpty);
    });

    test('renombrar a un nombre en uso tampoco pisa nada', () async {
      final files = {'a.pdf': 'uno', 'b.pdf': 'dos'};
      final github = _FakeGitHub(validated: files, working: files);
      final drive = await _driveOn(github);

      await expectLater(
        drive.rename(entry: file('a.pdf'), newName: 'b.pdf'),
        throwsA(isA<StateError>()),
      );
      expect(github.working, files);
      expect(writes(github), isEmpty);
    });

    test('una carpeta sobre otra con el mismo nombre, igual', () async {
      final files = {
        'F/uno.pdf': '1',
        'F/dos.pdf': '2',
        'Destino/F/tres.pdf': '3',
      };
      final github = _FakeGitHub(validated: files, working: files);
      final drive = await _driveOn(github);

      await expectLater(
        drive.move(entry: folder, destinationFolderPath: 'Destino'),
        throwsA(isA<StateError>()),
      );
      expect(github.working, files);
      expect(writes(github), isEmpty);
    });

    test('con el destino libre, se mueve', () async {
      final github = _FakeGitHub(working: {'a.pdf': 'mío'});
      final drive = await _driveOn(github);

      await drive.move(entry: file('a.pdf'), destinationFolderPath: 'Destino');

      expect(github.working, {'Destino/a.pdf': 'mío'});
    });
  });

  group('Subir', () {
    test('un fichero demasiado grande se rechaza antes de enviar nada',
        () async {
      final github = _FakeGitHub();
      final drive = await _driveOn(github);

      await expectLater(
        drive.uploadFile(
          folderPath: '',
          fileName: 'enorme.zip',
          bytes: Uint8List(DriveService.maxUploadBytes + 1),
        ),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', contains('25 MB')),
        ),
      );
      expect(github.requests.where((r) => r.startsWith('PUT ')), isEmpty);
    });
  });

  group('Un fichero pendiente de eliminarse', () {
    test('se previsualiza y se enlaza desde la versión aprobada', () async {
      // Ya no está en la rama de trabajo: leerlo de ahí daba error en la
      // vista previa y un 404 en "Ver en GitHub", justo cuando quien revisa
      // necesita verlo para decidir si aprueba la baja.
      final github = _FakeGitHub(
        validated: {'factura.pdf': 'lo aprobado'},
        working: const {},
      );
      final controller = DriveController(await _driveOn(github));
      final entry = DriveEntry(
        name: 'factura.pdf',
        path: 'factura.pdf',
        type: DriveEntryType.file,
        pendingChange: const PendingChange(
          path: 'factura.pdf',
          kind: PendingChangeKind.deleted,
        ),
      );

      expect(utf8.decode(await controller.fetchFileBytes(entry)), 'lo aprobado');
      expect(
        controller.webUrlFor(entry),
        'https://github.com/o/r/blob/main/factura.pdf',
      );
    });
  });

  group('Ráfagas de peticiones', () {
    final many = {for (var i = 0; i < 30; i++) 'F/$i.pdf': 'contenido $i'};

    test('mover una carpeta grande no lanza todas las lecturas a la vez',
        () async {
      final github = _FakeGitHub(validated: many, working: many);
      final drive = await _driveOn(github);

      await drive.move(
        entry: DriveEntry(
          name: 'F',
          path: 'F',
          type: DriveEntryType.folder,
        ),
        destinationFolderPath: 'Destino',
      );

      expect(github.working, hasLength(30));
      expect(github.working.keys, everyElement(startsWith('Destino/F/')));
      expect(github.maxInFlight, lessThanOrEqualTo(5));
    });

    test('el detalle de muchos cambios pendientes tampoco', () async {
      final github = _FakeGitHub(working: many);
      final drive = await _driveOn(github);

      expect(await drive.pendingChanges(), hasLength(30));
      expect(github.maxInFlight, lessThanOrEqualTo(5));
    });

    test('un límite de peticiones no se reintenta', () async {
      final github = _FakeGitHub(
        validated: {'a.pdf': 'x'},
        working: {'a.pdf': 'x'},
      );
      final drive = await _driveOn(github);
      github.rateLimited = (r) => r.url.path.endsWith('/contents/a.pdf');

      await expectLater(
        drive.fetchFileBytes('a.pdf'),
        throwsA(isA<GitHubError>()),
      );
      // Reintentarlo solo sumaba peticiones a un límite ya superado.
      expect(
        github.requests.where((r) => r == 'GET /repos/o/r/contents/a.pdf'),
        hasLength(1),
      );
    });
  });
}
