import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show NetworkImageLoadException;
import 'package:thor/thor.dart' hide originFromStack;
import 'package:thor/thor.dart' as thor_core show originFromStack;
import 'package:thor_flutter/src/log_capture.dart';
import 'package:thor_flutter/src/screenshot_capture.dart';
import 'package:thor_flutter/src/ui_health_capture.dart';

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

  /// `fork` de la zona de `Thor.run`: toda zona que nazca debajo con su
  /// propio `handleUncaughtError` (el `runZonedGuarded` de la app, el de
  /// un paquete) graba el error en Thor ANTES de delegar a ese handler.
  ///
  /// Sin esto, un `runZonedGuarded(..., onError)` de la app se queda con
  /// TODOS los errores async no capturados: el handler de la zona de Thor
  /// nunca se entera y `PlatformDispatcher.onError` tampoco (la zona ya
  /// los manejó). Visto en una app real cuyo `onError` estaba vacío: un
  /// `throw` en un Timer no dejaba rastro ni subía el replay. El handler
  /// de la app sigue corriendo igual — Thor solo mira.
  static Zone forkZone(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    ZoneSpecification? specification,
    Map<Object?, Object?>? zoneValues,
  ) {
    final handler = specification?.handleUncaughtError;
    if (handler == null) return parent.fork(zone, specification, zoneValues);
    return parent.fork(
      zone,
      ZoneSpecification.from(
        specification!,
        handleUncaughtError: (self, parent, zone, error, stack) {
          recordZoneError(error, stack);
          handler(self, parent, zone, error, stack);
        },
      ),
      zoneValues,
    );
  }

  /// El último error de zona grabado, hasta la siguiente microtarea: un
  /// handler que reenvía al padre (`Chain.capture` lo hace) pasa el MISMO
  /// error dos veces por [recordZoneError] en el mismo turno.
  static Object? _lastZoneError;

  /// Error async no capturado (zona de `Thor.run` o una anidada, ver
  /// [forkZone]). Nunca lanza: corre dentro de un handler de errores.
  static void recordZoneError(Object error, StackTrace stack) {
    if (identical(error, _lastZoneError)) return;
    _lastZoneError = error;
    // Zona raíz: la microtarea no debe pasar por las zonas de la app.
    Zone.root.scheduleMicrotask(() => _lastZoneError = null);
    try {
      _record(error, stack, source: 'zone', fatal: true);
    } on Object {
      // Grabar nunca debe romper el manejo de errores de la app.
    }
  }

  /// Entrada directa de un error de framework (tests).
  @visibleForTesting
  static void recordFlutterError(FlutterErrorDetails details) =>
      _recordFlutterError(details);

  static void _recordFlutterError(FlutterErrorDetails details) {
    final exception = details.exception;
    // Los desbordes de layout son FlutterError con texto característico:
    // se etiquetan aparte porque QA los reporta como "se ve mal" y en
    // release nadie los ve.
    final isOverflow =
        exception is FlutterError && exception.message.contains('overflowed');
    // Una imagen que no cargó: el síntoma es «falta una imagen», la causa
    // es una URL. Se etiqueta aparte (con la URL) para que no se pierda
    // entre los errores de framework.
    if (!isOverflow && _isImageFailure(details)) {
      UiHealthCapture.recordImageFailure(
        exception is NetworkImageLoadException ? exception.uri : null,
        statusCode: exception is NetworkImageLoadException
            ? exception.statusCode
            : null,
        detail: exception is NetworkImageLoadException
            ? null
            : _truncate(exception.toString(), 200),
        stack: details.stack,
      );
      return;
    }
    _record(
      exception,
      details.stack,
      source: isOverflow ? 'layout_overflow' : 'flutter',
      fatal: false,
      library: details.library,
      details: details,
    );
    // Un desborde es EL caso donde la imagen vale más que el texto: se
    // captura en cuanto ocurre, no al generar el reporte (para entonces la
    // pantalla ya cambió).
    if (isOverflow) ThorScreenshot.captureInBackground();
  }

  static bool _isImageFailure(FlutterErrorDetails details) =>
      details.exception is NetworkImageLoadException ||
      details.library == 'image resource service';

  /// Graba un problema que el usuario VIO (diálogo de error, imagen rota)
  /// como evento `error` con [source] propio, reusando la misma envoltura
  /// que un error real: mismo recorte, mismos secretos fuera y la
  /// `lastAction`. No es una excepción: `fatal` siempre `false`.
  static void recordSignal({
    required String source,
    required String type,
    required String message,
    Map<String, Object?> extra = const {},
    StackTrace? stack,
  }) {
    final core = ThorCore.instance;
    if (core == null) return;
    core.recorder.record(
      ThorEventKind.error,
      {
        'source': source,
        'fatal': false,
        'type': type,
        'message': core.redaction.scrub(_truncate(message, 500)),
        ...extra,
        ..._lastActionOf(core),
      },
      origin: stack == null ? null : originFromStack(stack),
    );
  }

  static void _record(
    Object error,
    StackTrace? stack, {
    required String source,
    required bool fatal,
    String? library,
    FlutterErrorDetails? details,
  }) {
    final core = ThorCore.instance;
    if (core == null) return;
    // Un fallo de E/S sobre un archivo del propio SDK (journal, replay) no
    // es un error de la app: se etiqueta `source: 'thor'` y se acota.
    if (ThorCore.isInternalFileError(error)) {
      core.recordInternalError('storage', error);
      return;
    }
    final text = error.toString();
    // Un permiso rechazado deja su propio evento (`permission`): el escáner
    // con la cámara denegada o el micrófono sin voz no dejaban nada más
    // que la excepción posterior.
    final hint = ThorCore.permissionKindFromText(text);
    if (hint != null) {
      core.permission(hint, after: 'denied', source: 'error');
    }
    // El mensaje del error puede traer PII (p.ej. un Exception con el
    // email en el texto) — se trunca, y la política decide en el
    // reporte si se muestra completo. Los SECRETOS no esperan al
    // reporte: un `DioException` con `Authorization: Bearer …` o una
    // URL con `?token=` no debe tocar el journal en disco.
    final raw = RedactionPolicy.scrubSecrets(
      ErrorText.clip(text, ErrorText.maxMessageChars),
    );
    // Sin el hash de instancia (`_AddToCartWidgetState#cb997`): cambia en
    // cada ejecución y parte un mismo error en varios títulos. El texto
    // original se conserva en `messageRaw`.
    final message = ErrorText.stripInstanceHashes(raw);
    final flutter = details == null || _isRepeat(text)
        ? null
        : _flutterContext(details, text);
    core.recorder.record(
      ThorEventKind.error,
      {
        'source': source,
        'fatal': fatal,
        'type': error.runtimeType.toString(),
        'message': message,
        if (message != raw) 'messageRaw': raw,
        if (library != null) 'library': library,
        if (stack != null) 'stack': ErrorText.clipStack(stack),
        ...?flutter,
        // "¿Qué fue lo último que hizo el usuario?" — la pregunta #1 al
        // triar un crash. Se copia AL evento (no solo al timeline) para
        // que la agrupación por huella la conserve.
        ..._lastActionOf(core),
      },
      origin: stack == null ? null : originFromStack(stack),
    );
  }

  static final Stopwatch _sinceStart = Stopwatch()..start();
  static String? _lastErrorText;
  static int _lastErrorMs = 0;

  /// ¿El mismo error que acaba de pasar (hace menos de 1 s)? Un error en
  /// `build` se repite cada frame: el contexto de Flutter (colector de
  /// diagnósticos, regex) se calcula una vez y no en cada repetición, en el
  /// hilo de UI.
  static bool _isRepeat(String text) {
    final now = _sinceStart.elapsedMilliseconds;
    final repeat = text == _lastErrorText && now - _lastErrorMs < 1000;
    _lastErrorText = text;
    _lastErrorMs = now;
    return repeat;
  }

  /// Tope de los textos de contexto de Flutter (resumen, información).
  static const _maxContextChars = 600;

  /// Lo que Flutter sabe del error además de la excepción: `context`
  /// ("while building ListView"), el resumen del `informationCollector`
  /// (el árbol de widgets/la ruta de render implicados) y, en un desborde
  /// de layout, el widget y el archivo que lo causaron. Nunca lanza: corre
  /// dentro del manejador de errores y el colector es código de terceros.
  static Map<String, Object?>? _flutterContext(
    FlutterErrorDetails details,
    String exceptionText,
  ) {
    try {
      final context = details.context?.toDescription();
      String? info;
      final collector = details.informationCollector;
      if (collector != null) {
        info = collector()
            .map((node) => node.toDescription())
            .where((line) => line.trim().isNotEmpty)
            .join('\n');
      }
      final culprit = ErrorText.errorCausingWidget(
        '$exceptionText\n${info ?? ''}',
      );
      return {
        if (context != null && context.isNotEmpty)
          'context': RedactionPolicy.scrubSecrets(
            ErrorText.clip(context, _maxContextChars),
          ),
        if (info != null && info.isNotEmpty)
          'info': RedactionPolicy.scrubSecrets(
            ErrorText.stripInstanceHashes(
              ErrorText.clip(info, _maxContextChars),
            ),
          ),
        if (culprit != null) ...{
          'widget': culprit.widget,
          if (culprit.file != null) 'file': culprit.file,
        },
      };
    } on Object {
      return null;
    }
  }

  static Map<String, Object?> _lastActionOf(ThorCore core) {
    // Solo toques: un scroll o el foco de un campo no son «lo que tocó».
    final tap = core.store
        .ofKind(ThorEventKind.interaction)
        .reversed
        .where((e) => ThorGesture.isPress(e.payload['gesture']))
        .firstOrNull;
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
