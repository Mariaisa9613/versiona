import 'package:flutter/material.dart';

import '../models/drive_entry.dart';

/// Insignia visual del estado de aprobación de un fichero o carpeta:
/// 🟢 Validado (coincide con la versión oficial) o 🟡 En revisión
/// (pendiente de aprobación).
class ReviewStatusBadge extends StatelessWidget {
  const ReviewStatusBadge({super.key, required this.status});

  final ReviewStatus status;

  static const _validatedBackground = Color(0xFFE3F5E9);
  static const _validatedForeground = Color(0xFF1B7A3D);
  static const _inReviewBackground = Color(0xFFFFF1D6);
  static const _inReviewForeground = Color(0xFF8A5A00);

  bool get _isValidated => status == ReviewStatus.validated;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message:
          _isValidated
              ? 'Validado: coincide con la versión aprobada'
              : 'En revisión: pendiente de aprobación',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: _isValidated ? _validatedBackground : _inReviewBackground,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _isValidated
                  ? Icons.verified_outlined
                  : Icons.hourglass_top_outlined,
              size: 14,
              color: _isValidated ? _validatedForeground : _inReviewForeground,
            ),
            const SizedBox(width: 4),
            Text(
              _isValidated ? 'Validado' : 'En revisión',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color:
                    _isValidated ? _validatedForeground : _inReviewForeground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
