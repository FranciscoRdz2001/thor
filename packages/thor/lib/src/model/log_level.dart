/// Nivel de una línea de log capturada (`print`, `debugPrint`, `Thor.log`).
enum ThorLogLevel {
  /// Charla de desarrollo. El narrador la omite y el replay solo la manda
  /// en modo diagnóstico.
  debug,

  /// Información de flujo.
  info,

  /// Algo raro pero recuperable.
  warn,

  /// Fallo.
  error;

  /// ¿warn o error? Son los que viajan siempre en el replay y los que
  /// tienen cupo propio en el tope de ráfagas.
  bool get isHigh => index >= warn.index;

  /// Nivel desde su nombre (`'warn'`); `null` si no es uno.
  static ThorLogLevel? tryParse(Object? name) =>
      name is String ? values.asNameMap()[name] : null;

  /// Nivel equivalente a un `level` numérico de `dart:developer` `log()`
  /// (la escala de `package:logging`: FINE 500, CONFIG 700, INFO 800,
  /// WARNING 900, SEVERE 1000, SHOUT 1200). `0` —el default de
  /// `developer.log`— es info: quien lo llama sin nivel no está pidiendo
  /// "ruido".
  static ThorLogLevel fromNumeric(int level) {
    if (level == 0) return info;
    if (level >= 1000) return error;
    if (level >= 900) return warn;
    if (level >= 800) return info;
    return debug;
  }

  static final _errorHint = RegExp(
    r'\b(error|errors|exception|fatal|failed|failure|fallo|crash)\b|\bfalló|'
    r'❌|⛔|🔴|🛑|\[E\]|^E/',
    caseSensitive: false,
  );
  static final _warnHint = RegExp(
    r'\b(warn|warning|advertencia|deprecated)\b|⚠|🟡|\[W\]|^W/',
    caseSensitive: false,
  );

  /// Nivel de un `print`/`debugPrint`, que no traen nivel: se deduce del
  /// texto ("Error al cobrar…" → error, "⚠ token por vencer" → warn) y lo
  /// demás es [fallback]. Heurística barata a propósito: se evalúa en cada
  /// línea de consola de la app.
  static ThorLogLevel infer(String message, {ThorLogLevel fallback = debug}) {
    if (_errorHint.hasMatch(message)) return error;
    if (_warnHint.hasMatch(message)) return warn;
    return fallback;
  }
}
