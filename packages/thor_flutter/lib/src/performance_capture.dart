import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:thor/thor.dart';

/// Captura de rendimiento con lo barato: `addTimingsCallback` entrega los
/// tiempos de cada frame sin costo agregado.
///
/// Anti-ruido a propósito: NO se graba cada frame lento (una sesión de QA
/// generaría miles). Se graba un evento por LOTE del callback solo cuando el
/// lote trae jank real ([minSlowFramesPerBatch]+ frames sobre presupuesto o
/// un frame congelado). Con la pantalla estampada, el agregado del reporte
/// responde "¿QUÉ pantalla va lenta?" con números.
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

  /// Instala el callback de timings. Idempotente.
  static void install() {
    if (_installed) return;
    _installed = true;
    _callback = (timings) => handleFrameTotals(
          [for (final t in timings) t.totalSpan],
        );
    SchedulerBinding.instance.addTimingsCallback(_callback!);
  }

  /// Desinstala (tests).
  static void uninstall() {
    if (!_installed) return;
    _installed = false;
    if (_callback != null) {
      SchedulerBinding.instance.removeTimingsCallback(_callback!);
    }
  }

  /// Lógica pura sobre duraciones totales de frame — separada del
  /// callback para poder testearla sin fabricar [FrameTiming]s.
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
      'slowFrames': slow,
      'frozenFrames': frozen,
      'worstMs': worst.inMilliseconds,
      'batchFrames': totals.length,
    });
  }
}
