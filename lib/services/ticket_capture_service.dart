import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

/// Fotografía tickets de gasto con la cámara del móvil, ya comprimidos para
/// subirlos al Drive sin engordar el repositorio.
class TicketCaptureService {
  final ImagePicker _picker = ImagePicker();

  /// Abre la cámara nativa. `imageQuality: 75` y `maxWidth: 1600` mantienen
  /// cada ticket por debajo de ~500 KB sin perder legibilidad. Devuelve
  /// `null` si el usuario cancela la foto.
  Future<XFile?> capturarTicket() {
    return _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 75,
      maxWidth: 1600,
    );
  }

  /// Nombre de archivo estándar para un ticket recién fotografiado, p. ej.
  /// "TICKET_20260827_123000.jpg".
  String nombreTicket() {
    final marca = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    return 'TICKET_$marca.jpg';
  }
}
