import 'package:flutter/widgets.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/anr_watchdog.dart';

/// Contexto del dispositivo que cambia a media sesión, sin plugins: lo que
/// Flutter ya avisa por [WidgetsBindingObserver].
///
/// Graba `environment {signal, …}` (journal, reporte y replay):
/// - `lifecycle {state}`: resumed | inactive | paused | hidden | detached.
/// - `memory_pressure`: el sistema avisa que anda corto de memoria.
/// - `locale {value}`: cambió el idioma del sistema (`es_MX`).
/// - `text_scale {value}`: cambió la escala de texto (`1.3`).
/// - `brightness {value}`: tema del sistema (`light` | `dark`).
/// - `connectivity {online}`: la infiere el núcleo de las peticiones
///   (ver `ConnectivityInference`); aquí no hay nada que instalar.
///
/// Costo: callbacks que el motor ya dispara solo cuando algo cambia (nada
/// por frame). Cada señal con valor solo se graba si el valor cambió, y la
/// presión de memoria se espacia [memoryPressureGap].
class EnvironmentCapture with WidgetsBindingObserver {
  EnvironmentCapture._();

  static EnvironmentCapture? _instance;

  /// Mínimo entre avisos de memoria: el SO puede mandar varios seguidos.
  @visibleForTesting
  static Duration memoryPressureGap = const Duration(seconds: 5);

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
    WidgetsBinding.instance.removeObserver(capture);
    _instance = null;
  }

  Brightness? _brightness;
  double? _textScale;
  String? _locale;
  DateTime? _lastMemory;

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
    _record({'signal': 'lifecycle', 'state': state.name});
  }

  /// "La app se cerró sola" suele ser un OOM kill precedido de esto.
  @override
  void didHaveMemoryPressure() {
    final now = DateTime.now();
    final last = _lastMemory;
    if (last != null && now.difference(last) < memoryPressureGap) return;
    _lastMemory = now;
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
