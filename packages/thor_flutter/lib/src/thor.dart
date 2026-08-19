import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/error_capture.dart';
import 'package:thor_flutter/src/interaction_capture.dart';
import 'package:thor_flutter/src/navigator_observer.dart';

/// Fachada Flutter de Thor — la API que ve la app.
///
/// Integración completa (dos puntos, nada por ruta/bloc/petición):
///
/// ```dart
/// void main() => Thor.run(
///       () => runApp(const MyApp()),
///       enabled: const bool.fromEnvironment('THOR', defaultValue: kDebugMode),
///     );
///
/// MaterialApp(navigatorObservers: [Thor.observer]);
/// ```
///
/// Con `enabled: false` TODO es no-op: los capturadores nunca se instalan y
/// la app queda exactamente como estaba. El gate por `--dart-define=THOR`
/// (no solo `kDebugMode`) existe porque QA prueba builds de release.
class Thor {
  Thor._();

  static bool _enabled = false;

  /// ¿Thor está activo en este proceso?
  static bool get enabled => _enabled;

  /// Observer para registrar en el router (go_router `observers:`,
  /// MaterialApp `navigatorObservers:`, auto_route, Beamer…).
  ///
  /// Devuelve siempre una instancia válida: si Thor está apagado el
  /// observer es inerte (no graba nada), así el registro en el router no
  /// necesita condicionales.
  static ThorNavigatorObserver get observer => _observer;
  static final _observer = ThorNavigatorObserver();

  /// Arranca la app con Thor instalado.
  ///
  /// - [enabled]: gate maestro. Con `false`, [body] corre tal cual.
  /// - [storageDirectory]: dónde persistir journals. Si es `null`, Thor
  ///   corre solo en memoria (la persistencia anti-crash queda apagada).
  ///   La app normalmente pasa el directorio de soporte de la app
  ///   (`path_provider` es decisión del caller — Thor no lo impone).
  /// - [appInfo] / [installId]: identidad para la cabecera de sesión.
  static Future<void> run(
    FutureOr<void> Function() body, {
    bool enabled = kDebugMode,
    Directory? storageDirectory,
    RedactionPolicy redaction = const RedactionPolicy.strict(),
    BufferQuotas? quotas,
    String? installId,
    Map<String, String> appInfo = const {},
  }) async {
    if (!enabled) {
      await body();
      return;
    }
    _enabled = true;

    // El cuerpo entero corre en la misma zona guardada: eso incluye
    // los errores async no capturados.
    await runZonedGuarded(
      () async {
        WidgetsFlutterBinding.ensureInitialized();
        await ThorCore.init(
          storageDirectory: storageDirectory,
          redaction: redaction,
          quotas: quotas,
          installId: installId,
          appInfo: appInfo,
          deviceInfo: _collectDeviceInfo(),
        );
        ErrorCapture.install();
        InteractionCapture.install();
        _watchLifecycle();
        await body();
      },
      (error, stack) {
        ThorCore.instance?.recorder.record(
          ThorEventKind.error,
          {
            'source': 'zone',
            'fatal': true,
            'type': error.runtimeType.toString(),
            'message': error.toString(),
            'stack': stack.toString(),
          },
          origin: ErrorCapture.originFromStack(stack),
        );
        // Re-lanzar rompería la zona; el error ya quedó registrado y los
        // handlers de la app (Crashlytics vía PlatformDispatcher) ya
        // corrieron por su propio canal.
      },
    );
  }

  /// Contexto del dispositivo sin plugins: lo que Flutter ya sabe.
  /// (Modelo exacto de hardware requiere device_info_plus — decisión del
  /// caller vía [run]`.appInfo` si lo quiere más rico.)
  static Map<String, String> _collectDeviceInfo() {
    final views = PlatformDispatcher.instance.views;
    final view = views.isEmpty ? null : views.first;
    final size =
        view == null ? null : view.physicalSize / view.devicePixelRatio;
    return {
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'locale': PlatformDispatcher.instance.locale.toString(),
      'textScale': view == null
          ? '?'
          : view.platformDispatcher.textScaleFactor.toStringAsFixed(2),
      'brightness':
          PlatformDispatcher.instance.platformBrightness.name,
      if (size != null)
        'screen': '${size.width.round()}x${size.height.round()}',
      'dartVersion': Platform.version.split(' ').first,
    };
  }

  /// Ciclo de vida (fondo/regreso) a la línea de tiempo: muchísimos bugs
  /// viven en el resume (token vencido, socket muerto, cámara liberada).
  static void _watchLifecycle() {
    WidgetsBinding.instance.addObserver(_LifecycleWatcher());
  }

  // ── Delegados de conveniencia hacia el núcleo (no-op si apagado) ──

  /// Marca libre en la línea de tiempo.
  static void mark(String label, [Map<String, Object?> data = const {}]) =>
      ThorCore.instance?.mark(label, data);

  /// Pantalla manual para navegación que el Navigator no ve.
  static void setScreen(String name) => ThorCore.instance?.setScreen(name);

  /// Registra un proveedor de contexto de dominio.
  static void addContext(String key, ThorContextProvider provider) =>
      ThorCore.instance?.addContext(key, provider);
}

class _LifecycleWatcher with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ThorCore.instance?.recorder.record(ThorEventKind.environment, {
      'signal': 'lifecycle',
      'state': state.name,
    });
  }
}
