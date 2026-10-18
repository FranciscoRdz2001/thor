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

  /// Campos que dicen "sin error" (`error: null`, `errorMessage: ''`,
  /// `failure=false`): contienen la palabra pero NO son un error. Un
  /// `Change { currentState: S(error: null) }` de un bloc las trae en cada
  /// transición normal y marcaba como error el 100% de los logs.
  static final _emptyErrorField = RegExp(
    r'\b(error|errors|exception|failure|failed)\w*\s*[:=]\s*'
    r'(null|none|false|0|""|\x27\x27|\[\]|\{\})(?![\w.])',
    caseSensitive: false,
  );

  /// Callbacks de un `BlocObserver` volcados como texto
  /// (`onChange(Cart, Change { … })`): son transiciones, no fallos, aunque
  /// el estado se llame `…Failure`. `onError(` sí es un error.
  static final _blocTrace = RegExp(
    r'^\s*on(Change|Transition|Create|Close|Event)\(',
  );

  /// Respuesta HTTP fallida volcada por un interceptor de logs
  /// (`ERROR RESPONSE [400]`): un 4xx es una respuesta del negocio (el
  /// servidor rechazó la petición), no un fallo de la app → warn.
  static final _httpClientError = RegExp(
    r'ERROR\s*RESPONSE|RESPONSE\s*ERROR|ERROR\s*\[4\d\d\]',
    caseSensitive: false,
  );
  static final _status4xx = RegExp(r'\b4\d\d\b');
  static final _statusCode = RegExp(
    r'\[(\d{3})\]|status(?:\s*code)?\s*[:=]?\s*(\d{3})\b',
    caseSensitive: false,
  );

  static int? _statusOf(String message) {
    final m = _statusCode.firstMatch(message);
    return m == null ? null : int.tryParse(m[1] ?? m[2] ?? '');
  }

  /// Nivel de un `print`/`debugPrint`, que no traen nivel: se deduce del
  /// texto ("Error al cobrar…" → error, "⚠ token por vencer" → warn) y lo
  /// demás es [fallback]. Heurística barata a propósito: se evalúa en cada
  /// línea de consola de la app.
  static ThorLogLevel infer(String message, {ThorLogLevel fallback = debug}) {
    if (message.startsWith('onError(')) return error;
    if (_blocTrace.hasMatch(message)) return fallback;
    if (_httpClientError.hasMatch(message)) {
      // El código HTTP de verdad (`[400]`, `statusCode: 500`) manda; un
      // «412 ms» suelto del texto no vuelve 4xx a un 500.
      final code = _statusOf(message);
      final client = code != null
          ? code >= 400 && code < 500
          : _status4xx.hasMatch(message);
      if (client) return warn;
    }
    final text = message.contains('rror') || message.contains('ail')
        ? message.replaceAll(_emptyErrorField, '')
        : message;
    if (_errorHint.hasMatch(text)) return error;
    if (_warnHint.hasMatch(text)) return warn;
    return fallback;
  }
}
