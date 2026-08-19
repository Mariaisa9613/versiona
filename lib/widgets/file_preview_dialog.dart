import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as xls;
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/drive_entry.dart';
import '../state/drive_controller.dart';
import '../utils/drive_entry_icons.dart';
import '../utils/error_messages.dart';
import '../utils/office_text_extractor.dart';

enum _PreviewKind {
  image,
  pdf,
  csv,
  excel,
  text,
  markdown,
  wordDoc,
  slides,

  /// Formatos binarios antiguos de Office (.doc, .ppt, .xls): no hay forma
  /// razonable de extraer su contenido sin una librería mucho más pesada.
  legacyOffice,
  unsupported,
}

_PreviewKind _kindFor(String fileName) {
  final ext =
      fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
  switch (ext) {
    case 'png':
    case 'jpg':
    case 'jpeg':
    case 'gif':
    case 'webp':
    case 'bmp':
      return _PreviewKind.image;
    case 'pdf':
      return _PreviewKind.pdf;
    case 'csv':
      return _PreviewKind.csv;
    case 'xlsx':
    case 'xlsm':
      return _PreviewKind.excel;
    case 'txt':
      return _PreviewKind.text;
    case 'md':
    case 'markdown':
      return _PreviewKind.markdown;
    case 'docx':
    case 'odt':
      return _PreviewKind.wordDoc;
    case 'pptx':
    case 'odp':
      return _PreviewKind.slides;
    case 'doc':
    case 'ppt':
    case 'xls':
      return _PreviewKind.legacyOffice;
    default:
      return _PreviewKind.unsupported;
  }
}

/// Abre una previsualización rápida de [entry] en un diálogo grande, sin
/// navegar a una pantalla nueva. El visor se elige según la extensión:
/// imágenes, PDF y hojas de cálculo (CSV/Excel) tienen un visor propio; el
/// resto cae en un aviso con enlace a GitHub. [onOpenHistory] se llama tras
/// cerrar este diálogo si el usuario pide ver el historial de versiones.
Future<void> showFilePreview(
  BuildContext context, {
  required DriveEntry entry,
  required DriveController drive,
  required VoidCallback onOpenHistory,
}) {
  return showDialog(
    context: context,
    builder:
        (_) => _FilePreviewDialog(
          entry: entry,
          drive: drive,
          onOpenHistory: onOpenHistory,
        ),
  );
}

class _FilePreviewDialog extends StatefulWidget {
  const _FilePreviewDialog({
    required this.entry,
    required this.drive,
    required this.onOpenHistory,
  });

  final DriveEntry entry;
  final DriveController drive;
  final VoidCallback onOpenHistory;

  @override
  State<_FilePreviewDialog> createState() => _FilePreviewDialogState();
}

class _FilePreviewDialogState extends State<_FilePreviewDialog> {
  late final Future<Uint8List> _future = widget.drive.fetchFileBytes(
    widget.entry,
  );

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = math.min(size.width * 0.85, 900.0);
    final height = math.min(size.height * 0.85, 800.0);

    return Dialog(
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            _PreviewHeader(
              entry: widget.entry,
              onOpenHistory: () {
                Navigator.of(context).pop();
                widget.onOpenHistory();
              },
              onOpenInGitHub:
                  () => launchUrl(
                    Uri.parse(widget.drive.webUrlFor(widget.entry)),
                    mode: LaunchMode.externalApplication,
                  ),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<Uint8List>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return _PreviewMessage(
                      icon: Icons.error_outline,
                      message: describeError(
                        snapshot.error!,
                        fallback: 'No se pudo cargar la vista previa.',
                      ),
                    );
                  }
                  return _PreviewBody(
                    fileName: widget.entry.name,
                    bytes: snapshot.data!,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewHeader extends StatelessWidget {
  const _PreviewHeader({
    required this.entry,
    required this.onOpenHistory,
    required this.onOpenInGitHub,
  });

  final DriveEntry entry;
  final VoidCallback onOpenHistory;
  final VoidCallback onOpenInGitHub;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        children: [
          Icon(iconForDriveEntry(entry)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              entry.name,
              style: Theme.of(context).textTheme.titleMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            onPressed: onOpenHistory,
            icon: const Icon(Icons.history),
            label: const Text('Historial'),
          ),
          IconButton(
            tooltip: 'Ver en GitHub',
            icon: const Icon(Icons.open_in_new),
            onPressed: onOpenInGitHub,
          ),
          IconButton(
            tooltip: 'Cerrar',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({required this.fileName, required this.bytes});

  final String fileName;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    switch (_kindFor(fileName)) {
      case _PreviewKind.image:
        return InteractiveViewer(
          child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
        );
      case _PreviewKind.pdf:
        return PdfPreview(
          build: (format) async => bytes,
          canChangeOrientation: false,
          canChangePageFormat: false,
          canDebug: false,
          allowPrinting: false,
          allowSharing: false,
        );
      case _PreviewKind.csv:
        return _CsvPreview(bytes: bytes);
      case _PreviewKind.excel:
        return _ExcelPreview(bytes: bytes);
      case _PreviewKind.text:
        return _TextPreview(bytes: bytes);
      case _PreviewKind.markdown:
        return _MarkdownPreview(bytes: bytes);
      case _PreviewKind.wordDoc:
        return _WordDocPreview(fileName: fileName, bytes: bytes);
      case _PreviewKind.slides:
        return _SlidesPreview(fileName: fileName, bytes: bytes);
      case _PreviewKind.legacyOffice:
        return const _PreviewMessage(
          icon: Icons.visibility_off_outlined,
          message:
              'Los formatos antiguos de Office (.doc, .ppt, .xls) no se '
              'pueden previsualizar. Ábrelo en GitHub o descárgalo.',
        );
      case _PreviewKind.unsupported:
        return const _PreviewMessage(
          icon: Icons.visibility_off_outlined,
          message:
              'No hay vista previa disponible para este tipo de fichero. '
              'Puedes abrirlo en GitHub con el botón de arriba.',
        );
    }
  }
}

class _TextPreview extends StatelessWidget {
  const _TextPreview({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    final text = utf8.decode(bytes, allowMalformed: true);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: SelectableText(
        text,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

class _MarkdownPreview extends StatelessWidget {
  const _MarkdownPreview({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    final text = utf8.decode(bytes, allowMalformed: true);
    return Markdown(
      data: text,
      padding: const EdgeInsets.all(20),
      selectable: true,
    );
  }
}

/// Solo texto: sin negrita, cursiva, tablas ni imágenes. Suficiente para
/// leer de un vistazo, no para reproducir el documento tal cual.
class _WordDocPreview extends StatelessWidget {
  const _WordDocPreview({required this.fileName, required this.bytes});

  final String fileName;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    final String text;
    try {
      text =
          fileName.toLowerCase().endsWith('.odt')
              ? extractOdtText(bytes)
              : extractDocxText(bytes);
    } catch (e) {
      return _PreviewMessage(
        icon: Icons.error_outline,
        message: describeError(e, fallback: 'No se pudo leer este documento.'),
      );
    }

    if (text.trim().isEmpty) {
      return const _PreviewMessage(
        icon: Icons.description_outlined,
        message: 'Este documento no tiene texto que mostrar.',
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Text(
            'Vista previa de solo texto: se han omitido el formato, las '
            'imágenes y las tablas.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: SelectableText(text),
          ),
        ),
      ],
    );
  }
}

/// Texto de cada diapositiva, una tarjeta por diapositiva. Igual que
/// [_WordDocPreview]: sin diseño, imágenes ni animaciones.
class _SlidesPreview extends StatelessWidget {
  const _SlidesPreview({required this.fileName, required this.bytes});

  final String fileName;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    final List<String> slides;
    try {
      slides =
          fileName.toLowerCase().endsWith('.odp')
              ? extractOdpSlidesText(bytes)
              : extractPptxSlidesText(bytes);
    } catch (e) {
      return _PreviewMessage(
        icon: Icons.error_outline,
        message: describeError(
          e,
          fallback: 'No se pudo leer esta presentación.',
        ),
      );
    }

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Text(
            'Vista previa de solo texto: se han omitido el diseño, las '
            'imágenes y las animaciones.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: slides.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final content = slides[index].trim();
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Diapositiva ${index + 1}',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        content.isEmpty ? '(sin texto)' : content,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PreviewMessage extends StatelessWidget {
  const _PreviewMessage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// Límite de filas que se pintan en la tabla de CSV/Excel, para que un
/// fichero grande no congele la vista previa (DataTable no virtualiza).
const _maxPreviewRows = 200;

class _CsvPreview extends StatelessWidget {
  const _CsvPreview({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    final List<List<dynamic>> rows;
    try {
      final text = utf8.decode(bytes, allowMalformed: true);
      rows = const CsvToListConverter(eol: '\n').convert(text);
    } catch (e) {
      return _PreviewMessage(
        icon: Icons.error_outline,
        message: describeError(e, fallback: 'No se pudo leer este CSV.'),
      );
    }
    return _DataTablePreview(rows: rows);
  }
}

class _ExcelPreview extends StatelessWidget {
  const _ExcelPreview({required this.bytes});

  final Uint8List bytes;

  String _cellText(xls.Data? cell) {
    final value = cell?.value;
    if (value == null) return '';
    if (value is xls.TextCellValue) return value.value.text ?? '';
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final List<List<dynamic>> rows;
    try {
      final workbook = xls.Excel.decodeBytes(bytes);
      final sheets = workbook.tables.values;
      if (sheets.isEmpty) {
        return const _PreviewMessage(
          icon: Icons.table_chart_outlined,
          message: 'Este archivo de Excel no tiene ninguna hoja con datos.',
        );
      }
      rows = sheets.first.rows.map((row) => row.map(_cellText).toList()).toList();
    } catch (e) {
      return _PreviewMessage(
        icon: Icons.error_outline,
        message: describeError(e, fallback: 'No se pudo leer este Excel.'),
      );
    }
    return _DataTablePreview(rows: rows);
  }
}

/// Tabla de solo lectura para CSV/Excel: la primera fila se usa como
/// cabecera. Si hay muchas filas, se muestran solo las primeras
/// [_maxPreviewRows] para que la vista previa no se congele con ficheros
/// grandes.
class _DataTablePreview extends StatelessWidget {
  const _DataTablePreview({required this.rows});

  final List<List<dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return const _PreviewMessage(
        icon: Icons.table_chart_outlined,
        message: 'Este fichero no tiene filas.',
      );
    }

    final header = rows.first;
    final body = rows.skip(1).take(_maxPreviewRows).toList();
    final truncated = rows.length - 1 > _maxPreviewRows;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              child: DataTable(
                columns: [
                  for (final cell in header)
                    DataColumn(
                      label: Text(
                        cell?.toString() ?? '',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
                rows: [
                  for (final row in body)
                    DataRow(
                      cells: [
                        for (var i = 0; i < header.length; i++)
                          DataCell(
                            Text(
                              i < row.length ? (row[i]?.toString() ?? '') : '',
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
        if (truncated)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Mostrando las primeras $_maxPreviewRows filas de '
              '${rows.length - 1}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
