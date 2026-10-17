import 'package:flutter/foundation.dart';
import 'package:thor/thor.dart' hide originFromStack;
import 'package:thor/thor.dart' as thor_core show originFromStack;
import 'package:thor_flutter/src/log_capture.dart';
import 'package:thor_flutter/src/screenshot_capture.dart';

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
      // El volcado a consola (presentError → debugPrint) ya está grabado
      // como este error: no se duplica como cientos de líneas de log.
      LogCapture.silenced(() => previousFlutterHandler?.call(details));
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
    // Un desborde es EL caso donde la imagen vale más que el texto: se
    // captura en cuanto ocurre, no al generar el reporte (para entonces la
    // pantalla ya cambió).
    if (isOverflow) ThorScreenshot.captureInBackground();
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
        // "¿Qué fue lo último que hizo el usuario?" — la pregunta #1 al
        // triar un crash. Se copia AL evento (no solo al timeline) para
        // que la agrupación por huella la conserve.
        ..._lastActionOf(core),
      },
      origin: stack == null ? null : originFromStack(stack),
    );
  }

  static Map<String, Object?> _lastActionOf(ThorCore core) {
    final tap = core.store.lastOfKind(ThorEventKind.interaction);
    if (tap == null) return const {};
    final label = tap.payload['label'] ?? tap.payload['widget'];
    return {'lastAction': 'tocó «$label» (#${tap.seq})'};
  }

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…(+${s.length - max})';

  /// Primer frame del stack que sea código de la APP. Delegado al núcleo
  /// (`originFromStack` de package:thor) — una sola heurística para
  /// errores, red y bloc.
  static String? originFromStack(StackTrace stack) =>
      thor_core.originFromStack(stack);
}
