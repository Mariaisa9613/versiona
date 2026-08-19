import 'package:flutter/material.dart';

import '../models/drive_entry.dart';

/// Icono representativo de un fichero (según su extensión) o carpeta.
/// Compartido entre la vista de lista, la de tablero y la previsualización.
IconData iconForDriveEntry(DriveEntry entry) {
  if (entry.isFolder) return Icons.folder_outlined;
  final ext =
      entry.name.contains('.') ? entry.name.split('.').last.toLowerCase() : '';
  switch (ext) {
    case 'pdf':
      return Icons.picture_as_pdf_outlined;
    case 'doc':
    case 'docx':
      return Icons.description_outlined;
    case 'xls':
    case 'xlsx':
      return Icons.table_chart_outlined;
    case 'jpg':
    case 'jpeg':
    case 'png':
    case 'gif':
    case 'webp':
      return Icons.image_outlined;
    case 'zip':
    case 'rar':
      return Icons.folder_zip_outlined;
    default:
      return Icons.insert_drive_file_outlined;
  }
}
