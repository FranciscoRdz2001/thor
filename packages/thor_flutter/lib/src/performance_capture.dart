import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:ui' show FramePhase;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:thor/thor.dart';

/// Captura de rendimiento con lo barato. Todo va en eventos
/// `ThorEventKind.performance` con `payload.kind`:
///
/// - `jank` `{screen, slow, frozen, worstMs, frames}`: `addTimingsCallback`
///   entrega los tiempos de cada frame sin costo agregado.
/// - `startup` `{ms, until: first_frame|first_screen, screen?}`: desde que
///   arranca `Thor.run` hasta el primer frame rasterizado / la primera
///   pantalla. La primera pantalla que se reemplaza en menos de
///   [firstScreenSettle] (`Onboarding` → `Splash`) no cuenta: se mide
///   contra la que se queda.
/// - `screen_load` `{screen, ms, from?, interrupted?, capped?}`: de un
///   cambio de pantalla a la PRIMERA quietud de la propia carga: UI quieta
///   (la misma detección de `ScreenCapture`; ver `onFrame`) y red callada
///   (sin peticiones en vuelo ni terminadas hace menos de [quiet]). No
///   incluye el tiempo del usuario: si toca o teclea antes de que termine,
///   la medición se corta ahí con `interrupted: true` (cota inferior, no
///   una carga completa). `capped: true` = pasó [maxLoad] sin quietud.
///
/// - `freeze` `{ms, screen, startAt}`: UN frame que tardó [freezeThreshold]
///   (2 s) o más, de los mismos timings del callback — funciona en debug,
///   profile y release, sin depender del watchdog (que en debug está
///   apagado y dejaba un freeze de 6.7 s como "0 ANR"). `startAt` (UTC) es
///   cuándo empezó el frame y `screen` la pantalla vigente en ese momento.
///
/// `jank` también lleva `startAt`: el inicio del primer frame lento del lote.
///
/// `anr` lo emite `AnrWatchdog` y `custom` sale de `Thor.measure`.
///
/// Anti-ruido a propósito: NO se graba cada frame lento (una sesión de QA
/// generaría miles). Se graba un evento por LOTE del callback solo cuando el
/// lote trae jank real ([minSlowFramesPerBatch]+ frames sobre presupuesto o
/// un frame congelado). Con la pantalla en el evento, el agregado del
/// reporte responde "¿QUÉ pantalla va lenta?" con números.
class PerformanceCapture {
  PerformanceCapture._();

  static bool _installed = false;
  static TimingsCallback? _callback;

  /// Presupuesto por frame. 16 ms ≈ 60 fps; un frame que lo dobla se
  /// percibe como tirón.
  static const Duration frameBudget = Duration(milliseconds: 32);

  /// Un frame sobre esto se reporta SIEMPRE (congelado — el usuario lo vio).
  static const Duration frozenThreshold = Duration(milliseconds: 700);

  /// Un frame así de largo es una congelada (`freeze`): evento propio,
  /// además de contar como `frozen` en el lote de jank.
  static const Duration freezeThreshold = Duration(seconds: 2);

  /// Mínimo de frames lentos en un lote para considerarlo jank.
  static const int minSlowFramesPerBatch = 3;

  /// Instala el callback de timings y la escucha de navegación.
  /// Idempotente.
  static void install() {
    if (_installed) return;
    _installed = true;
    _callback = (timings) {
      // Mismo reloj que los timestamps de FrameTiming: sirve para saber
      // cuánto hace que EMPEZÓ cada frame (solo se consulta para los
      // frames lentos; una lectura de reloj por lote, no por frame).
      final nowUs = Timeline.now;
      handleFrameTotals(
        [for (final t in timings) t.totalSpan],
        startAgoUs: (i) =>
            nowUs - timings[i].timestampInMicroseconds(FramePhase.vsyncStart),
      );
    };
    SchedulerBinding.instance.addTimingsCallback(_callback!);
    attach();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  /// Desinstala (tests).
  static void uninstall() {
    if (!_installed) return;
    _installed = false;
    if (_callback != null) {
      SchedulerBinding.instance.removeTimingsCallback(_callback!);
    }
    _unsubscribe?.call();
    _unsubscribe = null;
    _attachedTo = null;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _resetTiming();
  }

  /// Lógica pura sobre duraciones totales de frame — separada del
  /// callback para poder testearla sin fabricar [FrameTiming]s.
  ///
  /// La pantalla es la vigente cuando el motor ENTREGA el lote (hasta ~1 s
  /// después de los frames): el jank de una transición se atribuye a la
  /// pantalla de llegada, que es casi siempre la responsable.
  @visibleForTesting
  static void handleFrameTotals(
    List<Duration> totals, {
    int Function(int index)? startAgoUs,
  }) {
    final core = ThorCore.instance;
    if (core == null || totals.isEmpty) return;

    var slow = 0;
    var frozen = 0;
    var worst = Duration.zero;
    int? firstSlow;
    List<int>? freezes;
    for (var i = 0; i < totals.length; i++) {
      final total = totals[i];
      if (total > frameBudget) {
        slow++;
        firstSlow ??= i;
      }
      if (total > frozenThreshold) frozen++;
      if (total >= freezeThreshold) (freezes ??= <int>[]).add(i);
      if (total > worst) worst = total;
    }
    if (frozen == 0 && slow < minSlowFramesPerBatch) return;

    // Cuándo empezó el frame [i]: UTC; `null` si el reloj no cuadra.
    DateTime? startOf(int i) {
      final ago = startAgoUs?.call(i) ?? totals[i].inMicroseconds;
      if (ago < 0 || ago > const Duration(hours: 1).inMicroseconds) {
        return null;
      }
      return clock.now().toUtc().subtract(Duration(microseconds: ago));
    }

    final jankStart =
        firstSlow == null || startAgoUs == null ? null : startOf(firstSlow);
    core.recorder.record(ThorEventKind.performance, {
      'kind': 'jank',
      'screen': core.recorder.currentScreen?.display,
      'slow': slow,
      'frozen': frozen,
      'worstMs': worst.inMilliseconds,
      'frames': totals.length,
      if (jankStart != null) 'startAt': jankStart.toIso8601String(),
    });

    for (final i in freezes ?? const <int>[]) {
      final start = startOf(i);
      core.recorder.record(ThorEventKind.performance, {
        'kind': 'freeze',
        'ms': totals[i].inMilliseconds,
        'screen': (start == null ? null : _screenAt(core, start)) ??
            core.recorder.currentScreen?.display,
        if (start != null) 'startAt': start.toIso8601String(),
      });
    }
  }

  /// Pantalla vigente en [at]: la de la última navegación anterior.
  static String? _screenAt(ThorCore core, DateTime at) {
    final navs = core.store.ofKind(ThorEventKind.navigation);
    for (var i = navs.length - 1; i >= 0; i--) {
      final e = navs[i];
      if (e.atUtc.isAfter(at)) continue;
      final to = e.payload['to'];
      return to is String ? to : e.screen?.display;
    }
    return null;
  }

  // ── Reloj y arranque ──

  static final Stopwatch _watch = Stopwatch()..start();

  /// Reloj monotónico en microsegundos. Sustituible en tests.
  @visibleForTesting
  static int Function() nowUs = () => _watch.elapsedMicroseconds;

  static int _runStartUs = 0;
  static bool _firstFrameDone = false;
  static bool _firstScreenDone = false;

  /// Marca el inicio del arranque (primera línea de `Thor.run`).
  static void markRunStart() {
    _resetTiming();
    _runStartUs = nowUs();
  }

  /// El primer frame quedó rasterizado: `startup` hasta `first_frame`.
  static void onFirstFrame() {
    if (_firstFrameDone) return;
    _firstFrameDone = true;
    _recordStartup('first_frame');
  }

  static void _recordStartup(String until) {
    final core = ThorCore.instance;
    if (core == null) return;
    core.recorder.record(ThorEventKind.performance, {
      'kind': 'startup',
      'ms': (nowUs() - _runStartUs) ~/ 1000,
      'until': until,
    });
  }

  // ── Carga de pantalla (screen_load) ──
  //
  // Sin costo por frame más allá de UNA lectura de reloj: `onFrame` solo
  // guarda "cuándo fue el último frame" y "cuándo empezó esta ráfaga de
  // frames". Cuando `ScreenCapture` detecta quietud, `onIdle` cierra la
  // medición: del cambio de pantalla al ÚLTIMO frame de la ráfaga (la
  // espera de quietud de 300 ms no cuenta).

  static int _lastFrameUs = 0;
  static int _burstStartUs = 0;
  static bool _inBurst = false;
  static int? _pendingStartUs;
  static String? _pendingScreen;
  static String? _pendingFrom;
  static int _lastNetDoneUs = -1 << 40;
  static int _tapUs = -1 << 40;
  static Timer? _netTimer;
  static Timer? _capTimer;

  /// Quietud que cierra una carga: sin frames ni respuestas de red en este
  /// tiempo.
  @visibleForTesting
  static Duration quiet = const Duration(milliseconds: 300);

  /// Una carga que no encuentra quietud en este tiempo se cierra igual
  /// (`capped: true`): una animación infinita o una petición colgada no
  /// deben dejar la medición abierta para siempre.
  @visibleForTesting
  static Duration maxLoad = const Duration(seconds: 10);

  /// Un toque reciente (en este margen) es el inicio real de un cambio de
  /// pantalla detectado por el árbol, no la ráfaga de frames.
  static const Duration _tapWindow = Duration(milliseconds: 1500);

  /// Una primera pantalla reemplazada en este tiempo no es la que el
  /// usuario ve (`Onboarding` → `Splash` a los 3 ms).
  @visibleForTesting
  static Duration firstScreenSettle = const Duration(milliseconds: 50);

  static int _firstScreenAtUs = 0;
  static String? _firstScreenName;
  static Timer? _firstScreenTimer;

  static void Function()? _unsubscribe;
  static Object? _attachedTo;

  /// Suscribe la escucha de navegación al núcleo vigente (re-engancha si
  /// el núcleo cambió: tests, hot restart, renovación de sesión).
  static void attach() {
    final core = ThorCore.instance;
    if (core == null) return;
    if (identical(_attachedTo, core.recorder)) return;
    _unsubscribe?.call();
    _attachedTo = core.recorder;
    _unsubscribe = core.recorder.addListener(_onEvent);
  }

  static void _onEvent(ThorEvent event) {
    if (event.kind == ThorEventKind.network) {
      _lastNetDoneUs = nowUs();
      // Sin UI que cambie tras la respuesta no llega ninguna quietud de
      // frames: la red callada la cierra sola.
      if (_pendingStartUs != null) {
        _netTimer?.cancel();
        _netTimer = Timer(quiet, () => _tryClose(fromIdle: false));
      }
      return;
    }
    if (event.kind != ThorEventKind.navigation) return;
    final p = event.payload;
    final to = p['to'];
    if (!_firstScreenDone) {
      final at = nowUs();
      if (_firstScreenTimer != null &&
          at - _firstScreenAtUs > firstScreenSettle.inMicroseconds) {
        // La candidata ya aguantó su tiempo (el timer aún no corre): es la
        // primera pantalla; esta navegación es otra.
        _firstScreenTimer!.cancel();
        _emitFirstScreen();
      } else {
        // Se espera [firstScreenSettle]: si otra pantalla la reemplaza
        // antes, la que cuenta es esa.
        _firstScreenAtUs = at;
        if (to is String) _firstScreenName = to;
        _firstScreenTimer?.cancel();
        _firstScreenTimer = Timer(firstScreenSettle, _emitFirstScreen);
      }
    }
    if (to is! String) return;
    // Dos navegaciones antes de la quietud (splash → home): la carga es de
    // la primera a la quietud, hacia la pantalla final.
    if (_pendingStartUs == null) {
      _pendingStartUs = p['action'] == 'screen'
          ? (nowUs() - _tapUs < _tapWindow.inMicroseconds
              ? _tapUs
              : _burstStartUs)
          : nowUs();
      _pendingFrom = p['from'] as String?;
      _capTimer?.cancel();
      _capTimer = Timer(maxLoad, () => _close(capped: true));
    }
    _pendingScreen = to;
  }

  static void _emitFirstScreen() {
    _firstScreenTimer = null;
    if (_firstScreenDone) return;
    _firstScreenDone = true;
    final core = ThorCore.instance;
    if (core == null) return;
    core.recorder.record(ThorEventKind.performance, {
      'kind': 'startup',
      'ms': (_firstScreenAtUs - _runStartUs) ~/ 1000,
      'until': 'first_screen',
      if (_firstScreenName != null) 'screen': _firstScreenName,
    });
  }

  /// Un frame se dibujó. Llamado por `ScreenCapture` desde su callback
  /// persistente (ya existente): aquí solo hay una lectura de reloj.
  static void onFrame() {
    _lastFrameUs = nowUs();
    if (!_inBurst) {
      _inBurst = true;
      _burstStartUs = _lastFrameUs;
    }
  }

  /// El usuario soltó el dedo (un toque terminado): si el cambio de
  /// pantalla que provoca se detecta por el árbol, la carga empezó aquí.
  static void onTap() => _tapUs = nowUs();

  /// El usuario tocó o tecleó: lo que aún no terminó de cargar deja de ser
  /// "la pantalla cargando" y pasa a ser tiempo suyo.
  @visibleForTesting
  static void onUserInput() => _interrupt();

  /// La app se fue a segundo plano: lo que aún cargaba se cierra como
  /// interrumpido, sin contar el tiempo fuera (red y frames se congelan).
  static void onBackground() => _interrupt();

  static void _interrupt() {
    // La ráfaga de frames en curso (carrusel, cursor, teclado) deja de ser
    // "la carga" que viene: una pantalla detectada después de teclear una
    // búsqueda se mide desde el último gesto, no desde que el usuario
    // empezó a escribir.
    _inBurst = false;
    if (_pendingStartUs != null) _close(interrupted: true);
  }

  static void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) _interrupt();
  }

  static bool _onKey(KeyEvent e) {
    if (e is KeyDownEvent) _interrupt();
    return false; // solo observa.
  }

  /// La UI se quedó quieta: cierra la medición pendiente, si la hay (y si
  /// la red también está callada).
  static void onIdle() {
    _inBurst = false;
    _tryClose(fromIdle: true);
  }

  static void _tryClose({required bool fromIdle}) {
    if (_pendingStartUs == null) return;
    // Peticiones en vuelo: la pantalla aún está cargando. Cuando terminen,
    // el evento de red vuelve a intentar.
    if (ThorNetworkCapture.inFlight > 0) return;
    final now = nowUs();
    // Una respuesta reciente: su UI (rebuild) todavía puede venir.
    if (now - _lastNetDoneUs < quiet.inMicroseconds) {
      _netTimer?.cancel();
      _netTimer = Timer(quiet, () => _tryClose(fromIdle: false));
      return;
    }
    // Desde el timer de red hay que comprobar que la UI también esté
    // quieta (desde `onIdle` lo está por definición).
    if (!fromIdle && now - _lastFrameUs < quiet.inMicroseconds) return;
    _close();
  }

  static void _close({bool interrupted = false, bool capped = false}) {
    final start = _pendingStartUs;
    final screen = _pendingScreen;
    if (start == null || screen == null) return;
    final from = _pendingFrom;
    _pendingStartUs = _pendingScreen = _pendingFrom = null;
    _netTimer?.cancel();
    _capTimer?.cancel();
    final core = ThorCore.instance;
    if (core == null) return;
    final now = nowUs();
    // El final es lo último que pasó DE LA CARGA: el último frame o la
    // última respuesta (sin frames desde el cambio: 0, no negativo). Al
    // interrumpir, el momento del toque; al topar, el tope.
    var end = _lastFrameUs > start ? _lastFrameUs : start;
    if (_lastNetDoneUs > end && _lastNetDoneUs <= now) end = _lastNetDoneUs;
    if (interrupted || capped) end = now;
    core.recorder.record(ThorEventKind.performance, {
      'kind': 'screen_load',
      'screen': screen,
      'ms': (end - start) ~/ 1000,
      if (from != null) 'from': from,
      if (interrupted) 'interrupted': true,
      if (capped) 'capped': true,
    });
  }

  static void _resetTiming() {
    _netTimer?.cancel();
    _capTimer?.cancel();
    _firstScreenTimer?.cancel();
    _firstScreenName = null;
    _lastNetDoneUs = -1 << 40;
    _tapUs = -1 << 40;
    _firstFrameDone = false;
    _firstScreenDone = false;
    _inBurst = false;
    _lastFrameUs = 0;
    _burstStartUs = 0;
    _pendingStartUs = _pendingScreen = _pendingFrom = null;
  }
}
