import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:thor/thor.dart';

/// Captura de rendimiento con lo barato. Todo va en eventos
/// `ThorEventKind.performance` con `payload.kind`:
///
/// - `jank` `{screen, slow, frozen, worstMs, frames}`: `addTimingsCallback`
///   entrega los tiempos de cada frame sin costo agregado.
/// - `startup` `{ms, until: first_frame|first_screen}`: desde que arranca
///   `Thor.run` hasta el primer frame rasterizado / la primera pantalla.
/// - `screen_load` `{screen, ms, from?}`: de un cambio de pantalla a que
///   la UI se queda quieta (la misma detección de quietud de
///   `ScreenCapture`; ver `onFrame`).
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

  /// Mínimo de frames lentos en un lote para considerarlo jank.
  static const int minSlowFramesPerBatch = 3;

  /// Instala el callback de timings y la escucha de navegación.
  /// Idempotente.
  static void install() {
    if (_installed) return;
    _installed = true;
    _callback = (timings) => handleFrameTotals(
          [for (final t in timings) t.totalSpan],
        );
    SchedulerBinding.instance.addTimingsCallback(_callback!);
    attach();
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
    _resetTiming();
  }

  /// Lógica pura sobre duraciones totales de frame — separada del
  /// callback para poder testearla sin fabricar [FrameTiming]s.
  ///
  /// La pantalla es la vigente cuando el motor ENTREGA el lote (hasta ~1 s
  /// después de los frames): el jank de una transición se atribuye a la
  /// pantalla de llegada, que es casi siempre la responsable.
  @visibleForTesting
  static void handleFrameTotals(List<Duration> totals) {
    final core = ThorCore.instance;
    if (core == null || totals.isEmpty) return;

    var slow = 0;
    var frozen = 0;
    var worst = Duration.zero;
    for (final total in totals) {
      if (total > frameBudget) slow++;
      if (total > frozenThreshold) frozen++;
      if (total > worst) worst = total;
    }
    if (frozen == 0 && slow < minSlowFramesPerBatch) return;

    core.recorder.record(ThorEventKind.performance, {
      'kind': 'jank',
      'screen': core.recorder.currentScreen?.display,
      'slow': slow,
      'frozen': frozen,
      'worstMs': worst.inMilliseconds,
      'frames': totals.length,
    });
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
    if (event.kind != ThorEventKind.navigation) return;
    final p = event.payload;
    if (!_firstScreenDone) {
      _firstScreenDone = true;
      _recordStartup('first_screen');
    }
    final to = p['to'];
    if (to is! String) return;
    // Dos navegaciones antes de la quietud (splash → home): la carga es de
    // la primera a la quietud, hacia la pantalla final.
    if (_pendingStartUs == null) {
      _pendingStartUs = p['action'] == 'screen' ? _burstStartUs : nowUs();
      _pendingFrom = p['from'] as String?;
    }
    _pendingScreen = to;
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

  /// La UI se quedó quieta: cierra la medición pendiente, si la hay.
  static void onIdle() {
    _inBurst = false;
    final start = _pendingStartUs;
    final screen = _pendingScreen;
    if (start == null || screen == null) return;
    final from = _pendingFrom;
    _pendingStartUs = _pendingScreen = _pendingFrom = null;
    final core = ThorCore.instance;
    if (core == null) return;
    // Sin frames desde el cambio (navegación sin pintar): 0, no negativo.
    final end = _lastFrameUs > start ? _lastFrameUs : start;
    core.recorder.record(ThorEventKind.performance, {
      'kind': 'screen_load',
      'screen': screen,
      'ms': (end - start) ~/ 1000,
      if (from != null) 'from': from,
    });
  }

  static void _resetTiming() {
    _firstFrameDone = false;
    _firstScreenDone = false;
    _inBurst = false;
    _lastFrameUs = 0;
    _burstStartUs = 0;
    _pendingStartUs = _pendingScreen = _pendingFrom = null;
  }
}
