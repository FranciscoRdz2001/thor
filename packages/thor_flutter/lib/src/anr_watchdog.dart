import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:thor/thor.dart';

/// Detector de ANR: la UI isolate bloqueada `threshold` o más.
///
/// Un isolate APARTE le manda un `ping` a la UI isolate cada `interval` y
/// mide cuánto tarda el `pong`. Si la UI isolate estuvo ocupada (JSON
/// gigante, I/O síncrono, un loop), el ping se atiende tarde; al volver, el
/// watchdog avisa el tiempo exacto y la UI isolate graba
/// `performance {kind: 'anr', ms, screen}`.
///
/// Costo y seguridad:
/// - Un mensaje cada `interval` (500 ms con el umbral por defecto): sin
///   trabajo por frame en la UI isolate, solo un `send` de vuelta.
/// - Un solo ping en vuelo: un bloqueo largo no acumula mensajes.
/// - Solo corre con la app en `resumed`. En segundo plano el timer del
///   watchdog se cancela: no despierta al proceso ni gasta batería.
/// - Un proceso suspendido/congelado por el sistema no se confunde con un
///   ANR (el watchdog detecta que su propio reloj saltó y descarta).
/// - No mantiene viva a la app: es un isolate de servicio que muere con el
///   proceso, y `stop` lo mata explícitamente.
/// - Apagado en debug (`kDebugMode`: un breakpoint o un hot reload bloquean
///   solo la UI isolate y darían ANR falsos), en tests (`FLUTTER_TEST`) y
///   con Thor apagado (`Thor.run` nunca
///   lo arranca). Cuesta un isolate extra (~1-2 MB); `anrThreshold: null`
///   en `Thor.run` lo desactiva.
///
/// Límite: si el SO mata la app durante el bloqueo, esa UI isolate nunca
/// pudo grabar el evento. Lo que se ve es el ANR que SÍ terminó.
class AnrWatchdog {
  AnrWatchdog._();

  static ReceivePort? _rx;
  static Isolate? _isolate;
  static SendPort? _toDog;
  static bool _active = true;

  /// ¿Hay un watchdog corriendo?
  static bool get running => _isolate != null;

  /// Arranca el watchdog. Idempotente. [force] ignora el apagado en tests.
  static Future<void> start({
    Duration threshold = const Duration(seconds: 2),
    bool force = false,
    bool active = true,
  }) async {
    if (_isolate != null || _rx != null) return;
    if (!force && Platform.environment.containsKey('FLUTTER_TEST')) return;
    // Con el depurador, una pausa en un breakpoint o un hot reload largo
    // bloquean SOLO la UI isolate mientras el watchdog sigue vivo: sería un
    // ANR falso. En debug no arranca (los tiempos de debug no valen igual).
    if (!force && kDebugMode) return;
    final thresholdMs = threshold.inMilliseconds < 100
        ? 100
        : threshold.inMilliseconds;
    // Resolución del conteo ≈ intervalo: 1/4 del umbral, entre 25 y 500 ms.
    final intervalMs = (thresholdMs ~/ 4).clamp(25, 500);
    _active = active;
    final rx = ReceivePort();
    _rx = rx;
    rx.listen(_onMessage);
    try {
      final spawned = await Isolate.spawn<List<Object?>>(
        _watchdogMain,
        [rx.sendPort, thresholdMs, intervalMs],
        debugName: 'thor-anr',
        errorsAreFatal: false,
      );
      if (!identical(_rx, rx)) {
        spawned.kill(priority: Isolate.immediate);
        return;
      }
      _isolate = spawned;
    } on Object {
      // Plataforma sin isolates (web) o sin recursos: Thor sigue sin ANR.
      rx.close();
      if (identical(_rx, rx)) _rx = null;
    }
  }

  /// Detiene y mata el watchdog.
  static void stop() {
    _toDog?.send('stop');
    _isolate?.kill(priority: Isolate.immediate);
    _rx?.close();
    _isolate = null;
    _rx = null;
    _toDog = null;
  }

  /// Pausa/reanuda el ping según el ciclo de vida (solo `resumed` mide).
  static void setActive({required bool active}) {
    _active = active;
    _toDog?.send(<Object?>['active', active]);
  }

  static void _onMessage(Object? m) {
    switch (m) {
      case final SendPort port:
        _toDog = port;
        port.send(<Object?>['active', _active]);
      case ['ping', final int seq]:
        _toDog?.send(<Object?>['pong', seq]);
      case ['anr', final int ms]:
        recordAnr(ms);
    }
  }

  /// Graba el evento. Pública para tests.
  @visibleForTesting
  static void recordAnr(int ms) {
    final core = ThorCore.instance;
    if (core == null) return;
    core.recorder.record(ThorEventKind.performance, {
      'kind': 'anr',
      'ms': ms,
      'screen': core.recorder.currentScreen?.display,
    });
  }
}

/// Punto de entrada del isolate del watchdog (función de nivel superior).
void _watchdogMain(List<Object?> init) {
  final toMain = init[0]! as SendPort;
  final thresholdMs = init[1]! as int;
  final intervalMs = init[2]! as int;

  final rx = ReceivePort();
  toMain.send(rx.sendPort);

  final clock = Stopwatch()..start();
  Timer? timer;
  var seq = 0;
  int? outstanding; // seq del ping en vuelo
  var sentAt = 0;
  var lastTick = 0;

  // Un salto de nuestro propio reloj mucho mayor que el intervalo = el
  // proceso estuvo suspendido: lo medido no es un ANR.
  bool suspended(int now) => now - lastTick > intervalMs * 4;

  void tick(Timer _) {
    final now = clock.elapsedMilliseconds;
    if (suspended(now)) outstanding = null;
    lastTick = now;
    if (outstanding != null) return; // Uno en vuelo a la vez.
    outstanding = ++seq;
    sentAt = now;
    toMain.send(<Object?>['ping', outstanding]);
  }

  void startTimer() {
    timer?.cancel();
    outstanding = null;
    lastTick = clock.elapsedMilliseconds;
    timer = Timer.periodic(Duration(milliseconds: intervalMs), tick);
  }

  void stopTimer() {
    timer?.cancel();
    timer = null;
    outstanding = null;
  }

  rx.listen((Object? m) {
    switch (m) {
      case ['pong', final int s]:
        final now = clock.elapsedMilliseconds;
        if (timer == null || s != outstanding || suspended(now)) {
          outstanding = null;
          return;
        }
        outstanding = null;
        final stall = now - sentAt;
        if (stall >= thresholdMs) toMain.send(<Object?>['anr', stall]);
      case ['active', final bool on]:
        if (on) {
          startTimer();
        } else {
          stopTimer();
        }
      case 'stop':
        stopTimer();
        rx.close();
    }
  });
}
