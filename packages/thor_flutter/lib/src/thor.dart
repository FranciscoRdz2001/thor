import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/error_capture.dart';
import 'package:thor_flutter/src/interaction_capture.dart';
import 'package:thor_flutter/src/navigator_observer.dart';
import 'package:thor_flutter/src/performance_capture.dart';
import 'package:thor_flutter/src/screen_capture.dart';
import 'package:thor_flutter/src/semantics_capture.dart';

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
  /// - [storageDirectory]: **función** que resuelve dónde persistir los
  ///   journals; devolver `null` deja a Thor solo en memoria (sin
  ///   persistencia anti-crash). Es función y no un `Directory` por una
  ///   razón concreta: resolverlo suele necesitar `path_provider`, que
  ///   necesita el binding — y si la app inicializa el binding ANTES de
  ///   `run`, queda en una zona distinta a la del `runApp` de adentro. Ese
  ///   *zone mismatch* rompe justo la configuración de zona de la que
  ///   depende `Chain.capture` para reconstruir el `archivo:línea` a través
  ///   de gaps async. Flutter lo avisa con una aserción de debug fácil de
  ///   ignorar y el daño es silencioso. Thor la llama YA dentro de su zona
  ///   y con el binding listo. `path_provider` sigue siendo decisión del
  ///   caller: Thor no lo impone.
  /// - [appInfo] / [installId]: identidad para la cabecera de sesión.
  /// - [capture]: tope de ráfagas de estado por bloc y aligerado de las
  ///   peticiones exitosas en el journal (ver [ThorCapturePolicy]).
  /// - [infraPackages]: paquetes propios que son infraestructura (tu SDK
  ///   de red, por ejemplo) y deben saltarse al resolver el
  ///   `archivo:línea` de origen.
  static Future<void> run(
    FutureOr<void> Function() body, {
    bool enabled = kDebugMode,
    bool showOverlay = true,
    FutureOr<Directory?> Function()? storageDirectory,
    RedactionPolicy redaction = const RedactionPolicy.strict(),
    BufferQuotas? quotas,
    String? installId,
    Map<String, String> appInfo = const {},
    Set<String> infraPackages = const {},
    ThorCapturePolicy capture = const ThorCapturePolicy(),
  }) async {
    if (!enabled) {
      await body();
      return;
    }
    _enabled = true;
    // Paquetes propios de transporte (`mi_sdk`) que NO deben salir como
    // origen: sin esto el archivo:línea apunta al interior del cliente HTTP
    // y no a la pantalla/bloc que disparó la petición.
    extraInfraPackages.addAll(infraPackages);
    // La burbuja del inspector la monta el observer al primer push.
    ThorNavigatorObserver.overlayEnabled = showOverlay;

    // El cuerpo entero corre en la misma zona guardada: eso incluye
    // los errores async no capturados.
    //
    // `Chain.capture` (dentro de la zona) es lo que permite reconstruir el
    // origen archivo:línea a través de gaps asíncronos: sin él, una
    // petición disparada desde un bloc pierde el frame de la app. El
    // `when: true` lo mantiene también en release-QA; su costo es
    // proporcional a los await del arranque, no continuo.
    await runZonedGuarded(
      () => Chain.capture(() async {
        // El binding se inicializa AQUÍ, dentro de la zona, para que sea la
        // misma que la del runApp del body (ver [storageDirectory]).
        WidgetsFlutterBinding.ensureInitialized();
        await ThorCore.init(
          // Se resuelve después del binding: path_provider lo necesita.
          // Si falla, Thor corre en memoria — un journal ausente nunca
          // debe impedir que la app arranque.
          storageDirectory: await _resolveDirectory(storageDirectory),
          redaction: redaction,
          quotas: quotas,
          installId: installId,
          appInfo: appInfo,
          deviceInfo: _collectDeviceInfo(),
          capture: capture,
        );
        ThorNetworkCapture.install();
        await body();
        // Los capturadores de error se instalan DESPUÉS del body a
        // propósito: las apps asignan sus propios handlers
        // (Crashlytics/logging) durante el arranque, y si Thor se
        // instalara antes, el handler de la app lo pisaría. En este orden
        // Thor queda al frente y DELEGA al de la app; los errores del
        // propio arranque los cubre la zona de todos modos.
        ErrorCapture.install();
        InteractionCapture.install();
        // Los punteros no ven al lector de pantalla ni a los arneses de QA
        // que manejan la app por el árbol semántico.
        SemanticsInteractionCapture.install();
        PerformanceCapture.install();
        // Tabs y PageView: pantallas que el Navigator no ve.
        ScreenCapture.install();
        _watchLifecycle();
      }),
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

  /// Resuelve el directorio de journals sin dejar que su fallo tumbe la
  /// app: un canal de plataforma no disponible (tests, plataforma rara)
  /// degrada a memoria, no a excepción durante el arranque.
  static Future<Directory?> _resolveDirectory(
    FutureOr<Directory?> Function()? resolver,
  ) async {
    if (resolver == null) return null;
    try {
      return await resolver();
    } on Object {
      return null;
    }
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
      'brightness': PlatformDispatcher.instance.platformBrightness.name,
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

  /// Fija (o limpia con `null`) el usuario de la sesión: queda en la línea
  /// de tiempo, en el reporte y en el replay (`{"t":"user"}`).
  ///
  /// Pasa un id OPACO (tu id interno de cliente), nunca email/teléfono/
  /// nombre: Thor lo guarda tal cual, sin hashear — transformarlo en
  /// silencio impediría cruzarlo con tu backend. Los [traits] sí pasan por
  /// la `RedactionPolicy` (solo claves de la allowlist quedan en claro).
  static void setUser(String? id, {Map<String, String>? traits}) =>
      ThorCore.instance?.setUser(id, traits: traits);

  /// Registra un proveedor de contexto de dominio.
  static void addContext(String key, ThorContextProvider provider) =>
      ThorCore.instance?.addContext(key, provider);
}

class _LifecycleWatcher with WidgetsBindingObserver {
  Brightness? _lastBrightness;
  double? _lastTextScale;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    ThorCore.instance?.recorder.record(ThorEventKind.environment, {
      'signal': 'lifecycle',
      'state': state.name,
    });
  }

  /// El sistema avisa que anda corto de memoria — contexto oro cuando el
  /// bug es "la app se cerró sola" (OOM kill inminente).
  @override
  void didHaveMemoryPressure() {
    ThorCore.instance?.recorder.record(ThorEventKind.environment, {
      'signal': 'memoryPressure',
    });
  }

  /// Cambio de tema del sistema a media sesión — media clase de bugs de UI
  /// son "solo en oscuro".
  @override
  void didChangePlatformBrightness() {
    final value = PlatformDispatcher.instance.platformBrightness.name;
    if (value == _lastBrightness?.name) return;
    _lastBrightness = PlatformDispatcher.instance.platformBrightness;
    ThorCore.instance?.recorder.record(ThorEventKind.environment, {
      'signal': 'brightness',
      'value': value,
    });
  }

  /// Cambio de escala de texto — el clásico "se desborda con letra grande".
  @override
  void didChangeMetrics() {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) return;
    final scale = views.first.platformDispatcher.textScaleFactor;
    if (scale == _lastTextScale) return;
    _lastTextScale = scale;
    ThorCore.instance?.recorder.record(ThorEventKind.environment, {
      'signal': 'textScale',
      'value': scale.toStringAsFixed(2),
    });
  }
}
