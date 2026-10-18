/// Texto de errores para el evento `error`: stack completo acotado,
/// mensajes largos y hashes de instancia fuera del título.
library;

/// Utilidades de texto de errores (compartidas por `thor_flutter` y
/// `thor_bloc`: una sola regla de recorte).
abstract final class ErrorText {
  /// Tope de frames de un stack (los más cercanos al fallo).
  static const maxStackFrames = 60;

  /// Tope de caracteres de un stack.
  static const maxStackChars = 8 * 1024;

  /// Tope del mensaje de un error (~2 KB): alcanza para el texto completo
  /// de un `FlutterError` (resumen + descripción) sin inflar el journal.
  static const maxMessageChars = 2048;

  // `_AddToCartWidgetState#cb997`: hash de instancia de `Diagnosticable`
  // (5 hex). Va pegado a un identificador: `Issue #12345` no se toca.
  static final _instanceHash = RegExp(r'(?<=[\w>)\]])#[0-9a-f]{5}(?![\w])');

  /// [text] sin los hashes de instancia (`State#cb997` → `State`): cambian
  /// en cada ejecución y partían un mismo error en varios grupos/títulos.
  static String stripInstanceHashes(String text) =>
      text.contains('#') ? text.replaceAll(_instanceHash, '') : text;

  /// [s] recortado a [max] con el aviso `…(+N)`.
  static String clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…(+${s.length - max})';

  /// Stack con a lo sumo [maxFrames] frames y [maxChars] caracteres; lo
  /// que sobra se resume (`…(+N frames)`). Los frames más cercanos al
  /// fallo son los primeros, así que el recorte quita el final.
  static String clipStack(
    StackTrace stack, {
    int maxFrames = maxStackFrames,
    int maxChars = maxStackChars,
  }) {
    final lines = stack.toString().split('\n');
    final kept = <String>[];
    var frames = 0;
    var dropped = 0;
    var chars = 0;
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      if (frames >= maxFrames || chars + line.length + 1 > maxChars) {
        dropped++;
        continue;
      }
      frames++;
      chars += line.length + 1;
      kept.add(line);
    }
    if (dropped > 0) kept.add('…(+$dropped frames)');
    return kept.join('\n');
  }

  static final _culprit = RegExp(
    r'relevant error-causing widget was:\s*\n?\s*([^\n]+)',
    caseSensitive: false,
  );
  static final _sourceLocation =
      RegExp(r'((?:file://|package:)[^\s):]+\.dart:\d+(?::\d+)?)');

  /// Widget y archivo del "relevant error-causing widget" que Flutter
  /// pone en el texto de un desborde de layout
  /// (`Row Row:file:///app/lib/cart.dart:84:15`). `null` si el texto no
  /// lo trae (en release Flutter recorta el mensaje).
  static ({String widget, String? file})? errorCausingWidget(String text) {
    final line = _culprit.firstMatch(text)?[1]?.trim();
    if (line == null || line.isEmpty) return null;
    final widget = line.split(RegExp(r'[\s:]')).first;
    if (widget.isEmpty) return null;
    return (widget: widget, file: _sourceLocation.firstMatch(line)?[1]);
  }
}
