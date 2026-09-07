import 'package:flutter/material.dart';

import '../models/pending_change.dart';

/// Insignia visual del estado de un fichero o carpeta: 🟢 Validado (es la
/// versión aprobada) o 🟡 el tipo de cambio que tiene pendiente (nuevo,
/// modificado, movido o pendiente de eliminar).
class ReviewStatusBadge extends StatelessWidget {
  const ReviewStatusBadge({super.key, this.pendingChange});

  /// El cambio sin aprobar que afecta a la entrada, o `null` si lo que se ve
  /// es exactamente la versión aprobada.
  final PendingChange? pendingChange;

  static const _validatedBackground = Color(0xFFE3F5E9);
  static const _validatedForeground = Color(0xFF1B7A3D);
  static const _inReviewBackground = Color(0xFFFFF1D6);
  static const _inReviewForeground = Color(0xFF8A5A00);
  static const _deletedBackground = Color(0xFFFCE4E4);
  static const _deletedForeground = Color(0xFFB3261E);

  bool get _isValidated => pendingChange == null;

  bool get _isDeletion => pendingChange?.kind == PendingChangeKind.deleted;

  String get _label {
    switch (pendingChange?.kind) {
      case null:
        return 'Validado';
      case PendingChangeKind.added:
        return 'Nuevo';
      case PendingChangeKind.modified:
        return 'Modificado';
      case PendingChangeKind.deleted:
        return 'Se eliminará';
    }
  }

  String get _tooltip {
    final change = pendingChange;
    if (change == null) return 'Validado: es la versión aprobada';

    final quien =
        change.authors.isEmpty ? '' : ' · ${change.authors.join(', ')}';
    switch (change.kind) {
      case PendingChangeKind.added:
        return 'Nuevo, pendiente de aprobación$quien';
      case PendingChangeKind.modified:
        return 'Modificado, pendiente de aprobación$quien';
      case PendingChangeKind.deleted:
        return 'Pendiente de eliminarse cuando se apruebe$quien';
    }
  }

  IconData get _icon {
    switch (pendingChange?.kind) {
      case null:
        return Icons.verified_outlined;
      case PendingChangeKind.added:
        return Icons.add_circle_outline;
      case PendingChangeKind.modified:
        return Icons.hourglass_top_outlined;
      case PendingChangeKind.deleted:
        return Icons.delete_outline;
    }
  }

  Color get _background {
    if (_isValidated) return _validatedBackground;
    return _isDeletion ? _deletedBackground : _inReviewBackground;
  }

  Color get _foreground {
    if (_isValidated) return _validatedForeground;
    return _isDeletion ? _deletedForeground : _inReviewForeground;
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: _tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: _background,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 14, color: _foreground),
            const SizedBox(width: 4),
            Text(
              _label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: _foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
