import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/anr_watchdog.dart';
import 'package:thor_flutter/src/performance_capture.dart';

/// Contexto del dispositivo que cambia a media sesión, sin plugins: lo que
/// Flutter ya avisa por [WidgetsBindingObserver].
///
/// Graba `environment {signal, …}` (journal, reporte y replay):
/// - `lifecycle {state, backgroundMs?}`: resumed | inactive | paused |
///   hidden | detached. Al volver (`resumed`) trae `backgroundMs`: lo que
///   estuvo en segundo plano, para excluirlo de la duración de la sesión.
/// - `memory_pressure`: el sistema avisa que anda corto de memoria. Solo se
///   graba el aviso REAL: el que iOS manda en la ventana de ida a segundo
///   plano (`inactive` → `paused`) o de regreso ocurre en cada transición y
///   no es presión (20 de 20 pausas lo traían), así que se descarta y solo
///   se cuenta en [suppressedMemoryPressure].
/// - `system_overlay {ms}`: la app pasó `inactive` ≥ [overlayMin] y volvió a
///   `resumed` SIN llegar a `paused`: algo del sistema se puso encima (el
///   diálogo de un permiso, el centro de control, una hoja del sistema). Es
///   la huella de un permiso pedido; el motivo exacto lo dice
///   `Thor.permission` o el error de permiso inferido.
/// - `locale {value}`: cambió el idioma del sistema (`es_MX`).
/// - `text_scale {value}`: cambió la escala de texto (`1.3`).
/// - `brightness {value}`: tema del sistema (`light` | `dark`). Dentro de la
///   ventana de ida/vuelta a segundo plano NO se graba: iOS cambia el tema
///   dos veces para tomar las capturas del selector de apps. Si el cambio
///   fue real, se registra al terminar la ventana.
/// - `connectivity {online}`: la infiere el núcleo de las peticiones
///   (ver `ConnectivityInference`); aquí no hay nada que instalar.
///
/// Costo: callbacks que el motor ya dispara solo cuando algo cambia (nada
/// por frame). Cada señal con valor solo se graba si el valor cambió, y la
/// presión de memoria se espacia [memoryPressureGap].
class EnvironmentCapture with WidgetsBindingObserver {
  EnvironmentCapture._();

  static EnvironmentCapture? _instance;

  /// Tras pasar a `inactive` desde primer plano (y tras volver a
  /// `resumed`), lo que dura la ventana en que las señales de tema y
  /// memoria son ruido del cambio de estado, no del usuario ni del SO.
  @visibleForTesting
  static Duration transitionWindow = const Duration(seconds: 2);

  /// Reloj (sustituible en tests).
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// Mínimo entre avisos de memoria: el SO puede mandar varios seguidos.
  @visibleForTesting
  static Duration memoryPressureGap = const Duration(seconds: 5);

  /// Mínimo de tiempo en `inactive` (sin pasar a segundo plano) para
  /// considerarlo una superficie del sistema encima y no un parpadeo.
  @visibleForTesting
  static Duration overlayMin = const Duration(milliseconds: 400);

  /// Avisos de memoria descartados por caer en la ventana de ida/vuelta a
  /// segundo plano (ruido del cambio de estado, no presión real).
  @visibleForTesting
  static int suppressedMemoryPressure = 0;

  /// Instala el observador. Idempotente.
  static void install() {
    if (_instance != null) return;
    final capture = EnvironmentCapture._().._snapshot();
    _instance = capture;
    WidgetsBinding.instance.addObserver(capture);
  }

  /// Solo tests: quita el observador y limpia el estado.
  @visibleForTesting
  static void uninstall() {
    final capture = _instance;
    if (capture == null) return;
    capture._reconcile?.cancel();
    WidgetsBinding.instance.removeObserver(capture);
    _instance = null;
  }

  Brightness? _brightness;
  double? _textScale;
  String? _locale;
  DateTime? _lastMemory;
  DateTime? _backgroundAt;
  DateTime? _inactiveAt;
  AppLifecycleState? _lifecycle;
  DateTime? _transitionUntil;
  Timer? _reconcile;

  bool get _inTransition {
    final until = _transitionUntil;
    return until != null && now().isBefore(until);
  }

  /// Valores actuales como línea base: el primer aviso del sistema solo se
  /// graba si de verdad cambió algo.
  void _snapshot() {
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    _brightness = dispatcher.platformBrightness;
    _textScale = dispatcher.textScaleFactor;
    _locale = dispatcher.locale.toString();
  }

  void _record(Map<String, Object?> payload) {
    try {
      ThorCore.instance?.recorder.record(ThorEventKind.environment, payload);
    } on Object {
      // Observar jamás debe tumbar a la app.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // En segundo plano el watchdog de ANR no debe despertar al proceso.
    AnrWatchdog.setActive(active: state == AppLifecycleState.resumed);
    // Una carga abierta al irse no mide el tiempo fuera de la app.
    if (state != AppLifecycleState.resumed) PerformanceCapture.onBackground();
    // Ventana de ruido: al irse (inactive desde primer plano) y al volver.
    if (state == AppLifecycleState.inactive &&
        (_lifecycle == null || _lifecycle == AppLifecycleState.resumed)) {
      _transitionUntil = now().add(transitionWindow);
    } else if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // También al llegar a `paused`/`hidden`: el aviso falso a veces
      // llega justo después.
      _transitionUntil = now().add(transitionWindow);
    }
    final previous = _lifecycle;
    _lifecycle = state;
    final background = state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden;
    // `inactive` → `resumed` sin pasar por `paused`: una superficie del
    // sistema (diálogo de permiso, centro de control) estuvo encima.
    int? overlayMs;
    if (state == AppLifecycleState.inactive &&
        (previous == null || previous == AppLifecycleState.resumed)) {
      // Solo el `inactive` de IR (desde primer plano); el de VOLVER
      // (`paused` → `hidden` → `inactive` → `resumed`) no es una superficie.
      _inactiveAt = DateTime.now();
    } else if (background) {
      _inactiveAt = null;
    } else if (state == AppLifecycleState.resumed &&
        previous == AppLifecycleState.inactive &&
        _inactiveAt != null) {
      final ms = DateTime.now().difference(_inactiveAt!).inMilliseconds;
      _inactiveAt = null;
      if (ms >= overlayMin.inMilliseconds) overlayMs = ms;
    }
    // Cuánto estuvo fuera: marca de hueco para que la duración de la
    // sesión (y el dash) excluya el tiempo en segundo plano.
    int? away;
    if (background) {
      _backgroundAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed && _backgroundAt != null) {
      away = DateTime.now().difference(_backgroundAt!).inMilliseconds;
      _backgroundAt = null;
    }
    _record({
      'signal': 'lifecycle',
      'state': state.name,
      if (away != null) 'backgroundMs': away,
    });
    if (overlayMs != null) {
      _record({'signal': 'system_overlay', 'ms': overlayMs});
    }
    if (away != null) {
      // Para la marca de fin de sesión (segundos en background).
      ThorCore.instance?.backgroundMs += away;
    }
    // El SO puede matar la app en segundo plano sin aviso: que el journal
    // diga en disco que se fue ahí (así NO se confunde con un crash).
    if (background) {
      try {
        unawaited(ThorCore.instance?.journal?.flush() ?? Future<void>.value());
      } on Object {
        // Persistir jamás debe tumbar a la app.
      }
    }
  }

  /// "La app se cerró sola" suele ser un OOM kill precedido de esto.
  @override
  void didHaveMemoryPressure() {
    final at = now();
    // En la ventana de ida/vuelta a segundo plano no se graba (iOS lo manda
    // en cada transición); tampoco gasta el espaciado: un aviso real justo
    // después no debe perderse.
    if (_inTransition) {
      suppressedMemoryPressure++;
      return;
    }
    final last = _lastMemory;
    if (last != null && at.difference(last) < memoryPressureGap) return;
    _lastMemory = at;
    _record({'signal': 'memory_pressure'});
  }

  /// Cambio de idioma del sistema (formatos, textos largos, RTL…).
  @override
  void didChangeLocales(List<Locale>? locales) {
    final value = WidgetsBinding.instance.platformDispatcher.locale.toString();
    if (value == _locale) return;
    _locale = value;
    _record({'signal': 'locale', 'value': value});
  }

  /// Media clase de bugs de UI son "solo en oscuro".
  @override
  void didChangePlatformBrightness() {
    // Las capturas del selector de apps: dark y light en pareja. La línea
    // base no se toca; si de verdad cambió, [_reconcileBrightness] lo anota.
    if (_inTransition) {
      _scheduleReconcile();
      return;
    }
    _syncBrightness();
  }

  /// Al cerrar la ventana se compara el tema actual con la línea base: si
  /// el cambio era real se anota entonces; si era el par del selector de
  /// apps, ya volvió al mismo valor y no hay nada que anotar.
  void _scheduleReconcile() {
    final until = _transitionUntil;
    if (_reconcile != null || until == null) return;
    final wait = until.difference(now()) + const Duration(milliseconds: 50);
    _reconcile = Timer(wait, () {
      _reconcile = null;
      if (_inTransition) {
        _scheduleReconcile();
      } else {
        _syncBrightness();
      }
    });
  }

  void _syncBrightness() {
    final value = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    if (value == _brightness) return;
    _brightness = value;
    _record({'signal': 'brightness', 'value': value.name});
  }

  /// El clásico "se desborda con letra grande". Flutter avisa del cambio
  /// por métricas (también cambian al rotar: se filtra por valor).
  @override
  void didChangeTextScaleFactor() => _textScaleChanged();

  @override
  void didChangeMetrics() => _textScaleChanged();

  void _textScaleChanged() {
    final scale = WidgetsBinding.instance.platformDispatcher.textScaleFactor;
    if (scale == _textScale) return;
    _textScale = scale;
    _record({
      'signal': 'text_scale',
      'value': double.parse(scale.toStringAsFixed(2)),
    });
  }
}
