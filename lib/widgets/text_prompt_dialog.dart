import 'package:flutter/material.dart';

/// Diálogo con un único campo de texto. Devuelve lo escrito al confirmar, o
/// `null` si se cancela.
///
/// Existe para que sea el propio diálogo quien tenga su
/// [TextEditingController] y lo libere al desmontarse. Crearlo fuera y
/// liberarlo al volver de `showDialog` no sirve: el diálogo todavía lo usa
/// durante la animación de salida.
class TextPromptDialog extends StatefulWidget {
  const TextPromptDialog({
    super.key,
    required this.title,
    required this.confirmLabel,
    this.message,
    this.initialText = '',
    this.hintText,
    this.labelText,
    this.outlined = false,
    this.helperFor,
    this.canConfirm,
    this.destructive = false,
  });

  final String title;
  final String confirmLabel;

  /// Texto que va encima del campo.
  final String? message;

  final String initialText;
  final String? hintText;
  final String? labelText;
  final bool outlined;

  /// Texto de ayuda bajo el campo, recalculado con cada tecla.
  final String Function(String text)? helperFor;

  /// Si se puede confirmar con lo escrito. Por defecto, siempre.
  final bool Function(String text)? canConfirm;

  /// Pinta el botón de confirmar en rojo, para acciones sin vuelta atrás.
  final bool destructive;

  @override
  State<TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<TextPromptDialog> {
  late final _controller = TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canConfirm => widget.canConfirm?.call(_controller.text) ?? true;

  void _confirm() {
    if (_canConfirm) Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final helper = widget.helperFor?.call(_controller.text);

    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message != null) ...[
            Text(widget.message!),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _controller,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _confirm(),
            decoration: InputDecoration(
              hintText: widget.hintText,
              labelText: widget.labelText,
              border: widget.outlined ? const OutlineInputBorder() : null,
            ),
          ),
          if (helper != null) ...[
            const SizedBox(height: 12),
            Text(helper, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _canConfirm ? _confirm : null,
          style:
              widget.destructive
                  ? FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  )
                  : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
