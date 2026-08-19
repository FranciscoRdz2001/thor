import 'package:flutter/foundation.dart';
import 'package:thor/thor.dart';

/// Instala la captura de errores componiendo con los handlers existentes.
///
/// Regla de oro: Thor NUNCA sustituye lo que la app ya tenía (Crashlytics,
/// logging propio) — graba y delega. Por eso los handlers previos se
/// capturan ANTES de encadenar y se llaman SIEMPRE después.
class ErrorCapture {
  ErrorCapture._();

  static bool _installed = false;

  /// Encadena Thor a `FlutterError.onError` y `PlatformDispatcher.onError`.
  /// Idempotente.
  static void install() {
    if (_installed) return;
    _installed = true;

    final previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      _recordFlutterError(details);
      previousFlutterHandler?.call(details);
    };

    final previousPlatformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _record(
        error,
        stack,
        source: 'platform',
        fatal: true,
      );
      // Si había handler previo se respeta su veredicto; si no, `true`
      // (manejado) para no cambiar el comportamiento de la app por
      // el solo hecho de instalar Thor.
      return previousPlatformHandler?.call(error, stack) ?? true;
    };
  }

  static void _recordFlutterError(FlutterErrorDetails details) {
    final exception = details.exception;
    // Los desbordes de layout son FlutterError con texto característico:
    // se etiquetan aparte porque QA los reporta como "se ve mal" y en
    // release nadie los ve.
    final isOverflow =
        exception is FlutterError && exception.message.contains('overflowed');
    _record(
      exception,
      details.stack,
      source: isOverflow ? 'layout_overflow' : 'flutter',
      fatal: false,
      library: details.library,
    );
  }

  static void _record(
    Object error,
    StackTrace? stack, {
    required String source,
    required bool fatal,
    String? library,
  }) {
    final core = ThorCore.instance;
    if (core == null) return;
    core.recorder.record(
      ThorEventKind.error,
      {
        'source': source,
        'fatal': fatal,
        'type': error.runtimeType.toString(),
        // El mensaje del error puede traer PII (p.ej. un Exception con el
        // email en el texto) — se trunca, y la política decide en el
        // reporte si se muestra completo.
        'message': _truncate(error.toString(), 500),
        if (library != null) 'library': library,
        if (stack != null) 'stack': _truncate(stack.toString(), 4000),
      },
      origin: stack == null ? null : originFromStack(stack),
    );
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…(+${s.length - max})';

  /// Primer frame del stack que sea código de la APP (no framework, no
  /// paquetes): eso es el `archivo:línea` que lleva del síntoma al código.
  ///
  /// Heurística: primer frame `package:X/...` cuyo paquete no esté en la
  /// lista de infraestructura conocida. Pública para que el capturador de
  /// red la reutilice.
  static String? originFromStack(StackTrace stack) {
    final lines = stack.toString().split('\n');
    for (final line in lines) {
      final match = _packageFrame.firstMatch(line);
      if (match == null) continue;
      final package = match.group(1)!;
      if (_infraPackages.contains(package)) continue;
      return match.group(0);
    }
    return null;
  }

  static final _packageFrame =
      RegExp(r'package:([a-z0-9_]+)/[^\s):]+:\d+(?::\d+)?');

  static const _infraPackages = {
    'flutter', 'flutter_test', 'thor', 'thor_flutter', 'thor_dio',
    'thor_bloc', 'dio', 'http', 'bloc', 'flutter_bloc', 'go_router',
    'stack_trace', 'async', 'meta',
  };
}
