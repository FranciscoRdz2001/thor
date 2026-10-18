import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:thor/thor.dart';

/// Captura de la consola de la app: `print` y `debugPrint`.
///
/// Qué se puede interceptar y qué no:
/// - `print`: sí, con el `print` de la zona de `Thor.run`
///   ([zoneSpecification]).
/// - `debugPrint`: sí, es una variable global reasignable ([install]).
/// - `dart:developer` `log()`: NO — va directo a la VM sin zona ni función
///   reasignable. Para eso está `package:thor_flutter/log.dart`, un `log()`
///   con la misma firma (migración: cambiar el import) o `Thor.log`.
/// - `FlutterError.presentError`: ya lo graba ErrorCapture como error; su
///   volcado a consola (que sale por `debugPrint`) corre [silenced] para
///   no duplicarlo como cientos de líneas de log.
///
/// "Apagado = inofensivo": sin `Thor.run` nada de esto se instala; con
/// Thor, la consola recibe exactamente lo mismo que antes y además se
/// graba (sin secretos, ver `ThorCore.log`).
class LogCapture {
  LogCapture._();

  static bool _installed = false;
  static DebugPrintCallback? _original;

  /// Marca de zona: lo que se imprime dentro ya se grabó (o no debe
  /// grabarse).
  static const _echo = #thorLogEcho;

  /// Evita el bucle si algo imprime mientras se graba (un listener que
  /// loguea, un error del journal).
  static bool _recording = false;

  /// `print` de la zona de `Thor.run`: primero a la consola de siempre,
  /// luego a la línea de tiempo.
  static const ZoneSpecification zoneSpecification =
      ZoneSpecification(print: _onZonePrint);

  static void _onZonePrint(
    Zone self,
    ZoneDelegate parent,
    Zone zone,
    String line,
  ) {
    parent.print(zone, line);
    if (zone[_echo] == true) return;
    _record(line, 'print');
  }

  /// Envuelve `debugPrint`. Se llama DESPUÉS del body de la app (como
  /// ErrorCapture): si la app asigna su propio `debugPrint` al arrancar,
  /// Thor lo envuelve en vez de quedar pisado. Idempotente.
  static void install() {
    if (_installed) return;
    _installed = true;
    _original = debugPrint;
    debugPrint = _debugPrint;
  }

  /// Restaura el `debugPrint` previo (tests: el binding de flutter_test
  /// exige dejarlo como estaba).
  static void uninstall() {
    if (!_installed) return;
    _installed = false;
    if (debugPrint == _debugPrint) {
      debugPrint = _original ?? debugPrintThrottled;
    }
    _original = null;
  }

  static void _debugPrint(String? message, {int? wrapWidth}) {
    if (message != null && Zone.current[_echo] != true) {
      _record(message, 'debugPrint');
    }
    // El original corre en una zona marcada: `debugPrintThrottled` termina
    // en `print` —quizá más tarde, desde un Timer que hereda esta zona— y
    // esas líneas ya quedaron grabadas como debugPrint.
    final original = _original ?? debugPrintThrottled;
    silenced(() => original(message, wrapWidth: wrapWidth));
  }

  /// Corre [body] sin grabar lo que imprima (por `print` o `debugPrint`),
  /// incluso lo que salga después desde timers creados adentro.
  static T silenced<T>(T Function() body) =>
      runZoned(body, zoneValues: {_echo: true});

  /// Líneas recién grabadas con su origen y reloj, para no grabar dos veces
  /// el mismo texto que llega por `print` Y por `debugPrint` (un
  /// `debugPrint` de la app que termina en `print`, o un logger que
  /// escribe por los dos).
  static final List<({String line, String source, int ms})> _recent = [];
  static final Stopwatch _clock = Stopwatch()..start();

  /// Ventana en la que el mismo texto por la OTRA vía cuenta como duplicado.
  @visibleForTesting
  static Duration duplicateWindow = const Duration(milliseconds: 500);

  /// Limpia el historial de duplicados (tests).
  @visibleForTesting
  static void resetDuplicates() => _recent.clear();

  /// ¿[line] ya se grabó por otra vía hace nada? Un mismo origen repetido
  /// NO es duplicado (el usuario imprimió dos veces).
  static bool _isCrossSourceDuplicate(String line, String source) {
    final now = _clock.elapsedMilliseconds;
    final window = duplicateWindow.inMilliseconds;
    _recent.removeWhere((r) => now - r.ms > window);
    for (final r in _recent) {
      if (r.line == line && r.source != source) return true;
    }
    if (_recent.length >= 16) _recent.removeAt(0);
    _recent.add((line: line, source: source, ms: now));
    return false;
  }

  static void _record(String line, String source) {
    final core = ThorCore.instance;
    if (core == null || _recording) return;
    if (_isCrossSourceDuplicate(line, source)) return;
    _recording = true;
    try {
      core.log(line, level: ThorLogLevel.infer(line), source: source);
    } on Object {
      // Grabar un log jamás debe tumbar a quien imprime.
    } finally {
      _recording = false;
    }
  }
}
