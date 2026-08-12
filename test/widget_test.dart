import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:versiona/main.dart';

void main() {
  testWidgets('Muestra el listado de documentos y abre su historial', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const VersionaApp());

    expect(find.text('Versiona'), findsOneWidget);
    expect(find.text('Informe anual.docx'), findsOneWidget);

    await tester.tap(find.text('Informe anual.docx'));
    await tester.pumpAndSettle();

    expect(find.text('Añadidos gráficos y conclusiones'), findsOneWidget);
  });

  testWidgets('El botón flotante añade un nuevo documento', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const VersionaApp());

    final initialTiles = find.byType(ListTile);
    final initialCount = tester.widgetList(initialTiles).length;

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();

    expect(
      tester.widgetList(find.byType(ListTile)).length,
      initialCount + 1,
    );
  });
}
