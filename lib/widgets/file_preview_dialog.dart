import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart' as xls;
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/drive_entry.dart';
import '../state/drive_controller.dart';
import '../utils/drive_entry_icons.dart';
import '../utils/error_messages.dart';

enum _PreviewKind { image, pdf, csv, excel, unsupported }

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
