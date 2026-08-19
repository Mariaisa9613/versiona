import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Extrae solo el texto (sin formato, imágenes ni estilos) de un documento
/// Word (.docx). Sirve para una vista previa rápida, no para reproducir el
/// documento tal cual.
String extractDocxText(Uint8List bytes) {
  final entry = ZipDecoder().decodeBytes(bytes).findFile('word/document.xml');
  if (entry == null) {
    throw StateError('No se encontró el contenido del documento.');
  }
  final xml = XmlDocument.parse(utf8.decode(entry.content as List<int>));
  return xml
      .findAllElements('w:p')
      .map((p) => p.findAllElements('w:t').map((t) => t.innerText).join())
      .join('\n');
}

/// Extrae solo el texto de un documento de LibreOffice/OpenOffice Writer
/// (.odt).
String extractOdtText(Uint8List bytes) {
  final entry = ZipDecoder().decodeBytes(bytes).findFile('content.xml');
  if (entry == null) {
    throw StateError('No se encontró el contenido del documento.');
  }
  final xml = XmlDocument.parse(utf8.decode(entry.content as List<int>));
  return xml.findAllElements('text:p').map((p) => p.innerText).join('\n');
}

/// Extrae el texto de cada diapositiva de una presentación PowerPoint
/// (.pptx), una entrada de la lista por diapositiva, en orden.
List<String> extractPptxSlidesText(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final slideFiles =
      archive.files
          .where((f) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(f.name))
          .toList()
        ..sort((a, b) => _slideNumber(a.name).compareTo(_slideNumber(b.name)));

  if (slideFiles.isEmpty) {
    throw StateError('No se encontraron diapositivas en la presentación.');
  }

  return [
    for (final file in slideFiles)
      XmlDocument.parse(utf8.decode(file.content as List<int>))
          .findAllElements('a:t')
          .map((t) => t.innerText)
          .join(' '),
  ];
}

int _slideNumber(String path) {
  final match = RegExp(r'slide(\d+)\.xml$').firstMatch(path);
  return match != null ? int.parse(match.group(1)!) : 0;
}

/// Extrae el texto de cada diapositiva de una presentación de LibreOffice/
/// OpenOffice Impress (.odp), una entrada de la lista por diapositiva.
List<String> extractOdpSlidesText(Uint8List bytes) {
  final entry = ZipDecoder().decodeBytes(bytes).findFile('content.xml');
  if (entry == null) {
    throw StateError('No se encontró el contenido de la presentación.');
  }
  final xml = XmlDocument.parse(utf8.decode(entry.content as List<int>));
  final pages = xml.findAllElements('draw:page').toList();
  if (pages.isEmpty) {
    throw StateError('No se encontraron diapositivas en la presentación.');
  }
  return [
    for (final page in pages)
      page.findAllElements('text:p').map((p) => p.innerText).join('\n'),
  ];
}
