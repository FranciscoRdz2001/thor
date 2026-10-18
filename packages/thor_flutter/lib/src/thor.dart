import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/anr_watchdog.dart';
import 'package:thor_flutter/src/device_model.dart';
import 'package:thor_flutter/src/environment_capture.dart';
import 'package:thor_flutter/src/error_capture.dart';
import 'package:thor_flutter/src/interaction_capture.dart';
import 'package:thor_flutter/src/log_capture.dart';
import 'package:thor_flutter/src/navigator_observer.dart';
import 'package:thor_flutter/src/performance_capture.dart';
import 'package:thor_flutter/src/screen_capture.dart';
import 'package:thor_flutter/src/semantics_capture.dart';
import 'package:thor_flutter/src/session_lifetime.dart';
import 'package:thor_flutter/src/ui_health_capture.dart';

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

  /// Base del dashboard para armar el link de una sesión
  /// (`<base>/sessions/<id>`). `null` = sin link ([sessionUrl] devuelve
  /// `null`). Es solo texto: Thor no abre conexión por esto.
  static String? dashboardBaseUrl;

  /// Id de la sesión actual, o `null` si Thor está apagado / sin iniciar.
  ///
  /// Es el mismo id que lleva el replay (`x-thor-session`) y que el
  /// dashboard usa para encontrar la sesión: sirve para cruzarla con
  /// herramientas externas (Crashlytics, Sentry…) sin que Thor las conozca.
  static String? get sessionId => ThorCore.instance?.session.sessionId;

  /// Link de la sesión actual en el dashboard, o `null` si Thor está
  /// apagado o no hay [dashboardBaseUrl].
  static String? get sessionUrl => sessionUrlFor(sessionId);

  /// Arma `<base>/sessions/<id>` para [id] con [baseUrl] (por defecto
  /// [dashboardBaseUrl]); `null` si falta cualquiera de los dos.
  static String? sessionUrlFor(String? id, {String? baseUrl}) {
    final base = baseUrl ?? dashboardBaseUrl;
    if (id == null || base == null || base.isEmpty) return null;
    // Sin barra final doble: el caller puede pasar la base con o sin ella.
    final trimmed =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    return '$trimmed/sessions/${Uri.encodeComponent(id)}';
  }

  /// Foto de la sesión actual; `null` si Thor está apagado.
  static ThorSessionInfo? get sessionInfo {
    final core = ThorCore.instance;
    if (core == null) return null;
    return ThorSessionInfo._(
      sessionId: core.session.sessionId,
      sessionUrl: sessionUrl,
      userId: core.userId,
    );
  }

  static final _sessionListeners = <void Function(ThorSessionInfo)>[];

  /// Suscribe a "la sesión empezó" y "cambió el usuario" para que las
  /// integraciones (Crashlytics, Sentry…) reaccionen sin que Thor dependa
  /// de ellas.
  ///
  /// - Si Thor ya está activo, [listener] se llama de inmediato con el
  ///   estado actual (así no importa si se registra antes o después de
  ///   [run]).
  /// - Si Thor está apagado NO se llama nunca: apagado = inofensivo.
  /// - Una excepción del listener se traga: una integración rota no debe
  ///   tumbar la app ni a otros listeners.
  ///
  /// Devuelve la función que cancela la suscripción.
  static void Function() addSessionListener(
    void Function(ThorSessionInfo info) listener,
  ) {
    _sessionListeners.add(listener);
    final now = sessionInfo;
    if (now != null) _safeCall(listener, now);
    return () => _sessionListeners.remove(listener);
  }

  static void _notifySession() {
    final info = sessionInfo;
    if (info == null) return;
    for (final l in List.of(_sessionListeners)) {
      _safeCall(l, info);
    }
  }

  static void _safeCall(
    void Function(ThorSessionInfo) l,
    ThorSessionInfo info,
  ) {
    try {
      l(info);
    } on Object catch (_) {}
  }

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
  /// - [redaction]: qué se tapa de lo capturado. Por defecto
  ///   [RedactionPolicy.secretsOnly]: solo secretos (`Authorization`,
  ///   cookies, tokens, API keys, contraseñas, tarjeta/CVV/PIN, en headers,
  ///   query y a cualquier profundidad de los cuerpos JSON); URLs
  ///   completas, headers normales, cuerpos, emails, ids y nombres pasan
  ///   tal cual para poder depurar servicios. Apps sensibles:
  ///   `RedactionPolicy.strict()` (allowlist + sin datos con forma
  ///   personal en rutas, logs, errores y labels).
  /// - [appInfo] / [installId]: identidad para la cabecera de sesión.
  ///   Sin [installId], Thor guarda uno propio en el directorio de
  ///   [storageDirectory] (archivo `thor-install-id`): el mismo en cada
  ///   lanzamiento, para unir las sesiones de una instalación. Sin
  ///   directorio, uno en memoria (cambia por lanzamiento).
  /// - [deviceInfo]: datos del dispositivo que se suman (y ganan sobre) los
  ///   que Thor saca sin plugins (`os`, `osVersion`, `locale`,
  ///   `simulator`). El modelo exacto (`model`) requiere un plugin; con
  ///   `device_info_plus` son tres líneas en la app:
  ///   `final info = await DeviceInfoPlugin().deviceInfo;` y
  ///   `deviceInfo: {'model': info is IosDeviceInfo ? info.utsname.machine
  ///   : (info as AndroidDeviceInfo).model}`. Va a `meta.device` del replay.
  /// - [appVersion] / [appBuild]: versión y número de build de la app
  ///   (`1.4.2` / `87`). Van a `appInfo['version']` / `appInfo['build']`,
  ///   o sea a `meta.app` del replay, al journal y a la línea "App:" del
  ///   reporte. Ganan sobre esas mismas claves en [appInfo]. Thor no lee
  ///   la versión por su cuenta (eso exigiría `package_info_plus` en el
  ///   núcleo): la app la pasa; ver el README, sección "Versiones".
  /// - [capture]: tope de ráfagas de estado por bloc y aligerado de las
  ///   peticiones exitosas en el journal (ver [ThorCapturePolicy]).
  /// - [infraPackages]: paquetes propios que son infraestructura (tu SDK
  ///   de red, por ejemplo) y deben saltarse al resolver el
  ///   `archivo:línea` de origen.
  /// - [captureLogs]: graba `print` y `debugPrint` como logs (sin secretos
  ///   —y sin datos personales con `strict()`—, recortados y con tope de
  ///   ráfagas — ver
  ///   [ThorCapturePolicy.logBurstLimit]). La consola los sigue mostrando
  ///   igual. `dart:developer` `log()` no se puede interceptar: ver
  ///   [log].
  /// - [anrThreshold]: la UI bloqueada este tiempo o más se graba como
  ///   `performance {kind: 'anr'}` (un isolate aparte hace ping; solo con
  ///   la app en primer plano; apagado en tests). `null` lo desactiva.
  /// - [anrInDebug]: arranca el watchdog TAMBIÉN en debug (por defecto está
  ///   apagado ahí: un breakpoint o un hot reload bloquean la UI isolate y
  ///   darían ANR falsos). Pensado para builds de QA en debug. ADVERTENCIA:
  ///   cualquier pausa del depurador contará como ANR. Las congeladas de
  ///   frame de 2 s o más se reportan SIEMPRE como `performance
  ///   {kind: 'freeze'}` (debug, profile y release), con o sin este flag.
  /// - [sessionTimeout]: si la app pasa en segundo plano este tiempo o más
  ///   (30 min por defecto), al volver la sesión se cierra (flush, marca
  ///   de fin, última subida del replay) y empieza una NUEVA con otro
  ///   [sessionId] (los listeners de [addSessionListener] se enteran). El
  ///   tiempo en segundo plano no cuenta en la duración del replay ni de
  ///   la sesión: queda como `lifecycle {backgroundMs}` y como un registro
  ///   `gap` del replay. `null` desactiva la renovación (una sola sesión
  ///   por proceso; el tiempo en background se sigue excluyendo).
  ///
  /// - [bodyRules]: reglas de cuerpo por endpoint ([ThorBodyRule]): más
  ///   bytes retenidos y extractos JSONPath (`{'quantity': r'$..quantity'}`
  ///   → `{n, sum, min, max, values}` en `extracts` del evento y `x` del
  ///   replay) para respuestas que el tope de 8 KB corta (árbol de
  ///   categorías, patrocinados). Los extractos salen del cuerpo ya sin
  ///   secretos.
  ///
  /// [showOverlay] monta la burbuja del inspector y el aviso de "la sesión
  /// anterior se cayó". Son herramientas de QA: en producción dejarlo en
  /// `false` (con [enabled] en `false` ni siquiera se instalan). Aunque
  /// esté activo, el aviso solo sale si la sesión anterior se cayó de
  /// verdad (error fatal, o muerta en primer plano) — no si la mató el
  /// usuario o el SO en segundo plano —, se descarta solo a los 6 s, va
  /// arriba y no captura toques fuera de su propio recuadro.
  static Future<void> run(
    FutureOr<void> Function() body, {
    bool enabled = kDebugMode,
    bool showOverlay = true,
    FutureOr<Directory?> Function()? storageDirectory,
    RedactionPolicy redaction = const RedactionPolicy.secretsOnly(),
    BufferQuotas? quotas,
    String? installId,
    Map<String, String> appInfo = const {},
    Map<String, String> deviceInfo = const {},
    String? appVersion,
    String? appBuild,
    Set<String> infraPackages = const {},
    ThorCapturePolicy capture = const ThorCapturePolicy(),
    bool captureLogs = true,
    Duration? anrThreshold = const Duration(seconds: 2),
    bool anrInDebug = false,
    Duration? sessionTimeout = const Duration(minutes: 30),
    List<ThorBodyRule> bodyRules = const [],
  }) async {
    if (!enabled) {
      await body();
      return;
    }
    ThorNetworkCapture.bodyRules
      ..clear()
      ..addAll(bodyRules);
    PerformanceCapture.markRunStart();
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
        // Arranque hasta el primer frame: se engancha ANTES del body.
        unawaited(
          WidgetsBinding.instance.waitUntilFirstFrameRasterized
              .then((_) => PerformanceCapture.onFirstFrame()),
        );
        await ThorCore.init(
          // Se resuelve después del binding: path_provider lo necesita.
          // Si falla, Thor corre en memoria — un journal ausente nunca
          // debe impedir que la app arranque.
          storageDirectory: await _resolveDirectory(storageDirectory),
          redaction: redaction,
          quotas: quotas,
          installId: installId,
          appInfo: ThorSession.mergeAppInfo(
            appInfo,
            version: appVersion,
            build: appBuild,
          ),
          deviceInfo: {..._withModel(_collectDeviceInfo()), ...deviceInfo},
          capture: capture,
        );
        ThorNetworkCapture.install();
        _notifySession();
        await body();
        // Los capturadores de error se instalan DESPUÉS del body a
        // propósito: las apps asignan sus propios handlers
        // (Crashlytics/logging) durante el arranque, y si Thor se
        // instalara antes, el handler de la app lo pisaría. En este orden
        // Thor queda al frente y DELEGA al de la app; los errores del
        // propio arranque los cubre la zona de todos modos.
        ErrorCapture.install();
        // Mismo motivo: la app puede asignar su propio debugPrint.
        if (captureLogs) LogCapture.install();
        InteractionCapture.install();
        // Los punteros no ven al lector de pantalla ni a los arneses de QA
        // que manejan la app por el árbol semántico.
        SemanticsInteractionCapture.install();
        PerformanceCapture.install();
        // Tabs y PageView: pantallas que el Navigator no ve.
        ScreenCapture.install();
        // Pantalla atascada o en blanco, diálogos de error, imágenes rotas.
        UiHealthCapture.install();
        _watchLifecycle();
        if (sessionTimeout != null) {
          SessionLifetime.install(sessionTimeout, onRenewed: _notifySession);
        }
        if (anrThreshold != null) {
          unawaited(
            AnrWatchdog.start(
              threshold: anrThreshold,
              active: _isForeground(),
              allowInDebug: anrInDebug,
            ),
          );
        }
      }),
      // Re-lanzar rompería la zona; el error queda registrado y los
      // handlers de la app (Crashlytics vía PlatformDispatcher) corren por
      // su propio canal.
      ErrorCapture.recordZoneError,
      zoneSpecification: ZoneSpecification(
        // `print` de la app (y de sus paquetes) a la línea de tiempo.
        print: captureLogs ? LogCapture.zoneSpecification.print : null,
        // Los `runZonedGuarded` anidados de la app también graban.
        fork: ErrorCapture.forkZone,
      ),
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
      // En Android el arranque (antes del primer frame) reporta 0x0: el
      // tamaño físico aún no llegó del embedder. Un "0x0" en el reporte es
      // peor que no decir nada, así que se omite si no es válido.
      if (size != null && !size.isEmpty)
        'screen': '${size.width.round()}x${size.height.round()}',
      'dartVersion': Platform.version.split(' ').first,
      ..._simulatorInfo(),
    };
  }

  /// `os`, `osVersion`… más el `model` exacto cuando se pudo saber sin
  /// plugin (ver [DeviceModel]).
  static Map<String, String> _withModel(Map<String, String> info) {
    if (info['model'] != null) return info;
    final model = DeviceModel.detect();
    return model == null ? info : {...info, 'model': model};
  }

  /// `simulator` (y el modelo simulado) sin plugin. iOS: el simulador
  /// define `SIMULATOR_*` en el entorno del proceso. Android: no hay forma
  /// barata de leer `ro.product.*` sin canal de plataforma — se omite.
  static Map<String, String> _simulatorInfo() {
    if (!Platform.isIOS) return const {};
    try {
      final env = Platform.environment;
      // El proceso de una app en el simulador no siempre hereda `SIMULATOR_*`
      // (con `flutter run` no), y `Platform.version` dice `ios_arm64` también
      // ahí: el binario sí vive bajo `CoreSimulator/Devices/<udid>/`.
      final simulated = env.containsKey('SIMULATOR_UDID') ||
          env.containsKey('SIMULATOR_DEVICE_NAME') ||
          Platform.resolvedExecutable.contains('/CoreSimulator/Devices/');
      return {
        'simulator': '$simulated',
        if (env['SIMULATOR_MODEL_IDENTIFIER'] case final model?
            when model.isNotEmpty)
          'model': model,
      };
    } on Object {
      return const {};
    }
  }

  /// Ciclo de vida (fondo/regreso) a la línea de tiempo: muchísimos bugs
  /// viven en el resume (token vencido, socket muerto, cámara liberada).
  static bool _isForeground() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  static void _watchLifecycle() {
    EnvironmentCapture.install();
  }

  // ── Delegados de conveniencia hacia el núcleo (no-op si apagado) ──

  /// Marca libre en la línea de tiempo.
  static void mark(String label, [Map<String, Object?> data = const {}]) =>
      ThorCore.instance?.mark(label, data);

  /// Graba una línea de log y la manda también a `dart:developer` `log()`
  /// (DevTools), así que sirve de reemplazo directo de este.
  ///
  /// `developer.log` no se puede interceptar (va directo a la VM). Para no
  /// tocar cada llamada, `package:thor_flutter/log.dart` trae un `log()`
  /// con su misma firma: migrar es cambiar el import
  /// (`import 'dart:developer';` → `import 'package:thor_flutter/log.dart';`).
  ///
  /// El mensaje, [name] y [error] se limpian de secretos (`Bearer …`,
  /// `token=…`, `password=…`) antes de grabarse, y se recortan; con
  /// `RedactionPolicy.strict()` también de emails, números largos y
  /// tokens sueltos.
  ///
  /// [data]: campos estructurados (JSON libre) que acompañan al mensaje
  /// (`data: {'orderId': 42}`); sin secretos y acotados a ~2 KB.
  static void log(
    String message, {
    ThorLogLevel level = ThorLogLevel.info,
    String name = '',
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) {
    developer.log(
      message,
      name: name,
      level: switch (level) {
        ThorLogLevel.debug => 500,
        ThorLogLevel.info => 800,
        ThorLogLevel.warn => 900,
        ThorLogLevel.error => 1000,
      },
      error: error,
      stackTrace: stackTrace,
    );
    ThorCore.instance?.log(
      message,
      level: level,
      name: name,
      error: error,
      stackTrace: stackTrace,
      data: data,
    );
  }

  /// Registra un evento de negocio con nombre y propiedades:
  /// `Thor.track('add_to_cart', {'sku': 'A1', 'qty': 2})`.
  ///
  /// Queda en la línea de tiempo, el journal, el reporte y el replay
  /// (`ev` `k: "track"`, `p: {n, props?}`). [props] es JSON libre: se
  /// guarda legible salvo secretos (contraseña, token, tarjeta…) y se
  /// descarta si pesa más de ~2 KB. No-op con Thor apagado.
  static void track(String name, [Map<String, Object?> props = const {}]) {
    try {
      ThorCore.instance?.track(name, props);
    } on Object {
      // Registrar jamás debe tumbar a la app.
    }
  }

  /// Registra un tiempo propio de la app (`performance`, `kind: 'custom'`):
  /// `Thor.measure('checkout', 840, data: {'items': 3})`.
  ///
  /// Para quien ya tiene su propio medidor, un reenvío de una línea. Ej.
  /// con un `PerformanceTracker` que cierra trazas con nombre y duración:
  /// en su `stop` agregar
  /// `Thor.measure(trace.name, trace.elapsed.inMilliseconds)`.
  /// [data]: JSON libre sin secretos, ~2 KB. No-op con Thor apagado.
  static void measure(String name, num ms, {Map<String, Object?>? data}) {
    try {
      ThorCore.instance?.measure(name, ms, data: data);
    } on Object {
      // Medir jamás debe tumbar a la app.
    }
  }

  /// Un permiso del sistema cambió o se pidió: `camera`, `microphone`,
  /// `speech`, `location`, `photos`, `contacts`, `notifications`.
  ///
  /// ```dart
  /// final status = await Permission.camera.request();
  /// Thor.permission('camera', before: 'undetermined',
  ///     after: status.name, prompt: true);
  /// ```
  ///
  /// Queda como `environment {signal: 'permission', kind, before, after,
  /// prompt}` en la línea de tiempo y el replay. Thor además infiere un
  /// `denied` cuando un error trae un permiso rechazado (cámara, micrófono,
  /// voz). No-op con Thor apagado.
  static void permission(
    String kind, {
    String? before,
    String? after,
    bool prompt = false,
  }) {
    try {
      ThorCore.instance
          ?.permission(kind, before: before, after: after, prompt: prompt);
    } on Object {
      // Registrar jamás debe tumbar a la app.
    }
  }

  /// La app cedió la pantalla a una superficie externa: Safari / Custom
  /// Tab (`mode: 'in_app_browser'`), otra app (`external_app`), un WebView
  /// propio (`webview`) o una hoja del sistema (`system_ui`). Llámalo al
  /// abrir (`open: true`) y al volver (`open: false`, con [ms] si lo
  /// sabes). Solo viaja el HOST de [url] (nunca ruta ni query). No-op con
  /// Thor apagado.
  static void externalSurface(
    String url, {
    String mode = 'external_app',
    bool open = true,
    int? ms,
  }) {
    try {
      ThorCore.instance?.externalSurface(url, mode: mode, open: open, ms: ms);
    } on Object {
      // Registrar jamás debe tumbar a la app.
    }
  }

  /// Pantalla manual para navegación que el Navigator no ve.
  static void setScreen(String name) => ThorCore.instance?.setScreen(name);

  /// Contexto fino de la pantalla actual, para una misma clase que sirve a
  /// muchos contextos (un PLP/búsqueda genérico):
  /// `Thor.setScreenContext('Departamentos > Carnes > Res Selecta')`.
  ///
  /// Acompaña a los eventos siguientes (`sd` en el replay, `detail` en la
  /// pantalla del journal) hasta que cambie la pantalla; `null` lo quita.
  /// Llámalo cuando el contexto ya se conoce (initState / al cargar), no en
  /// el constructor del widget. Si no lo llamas, Thor usa el título del
  /// AppBar visible, cuando hay uno. No-op con Thor apagado.
  static void setScreenContext(String? detail) {
    try {
      ThorCore.instance?.setScreenContext(detail);
    } on Object {
      // Registrar jamás debe tumbar a la app.
    }
  }

  /// Fija (o limpia con `null`) el usuario de la sesión: queda en la línea
  /// de tiempo, en el reporte y en el replay (`{"t":"user"}`), y el
  /// dashboard busca sesiones por él.
  ///
  /// [id]: tu id interno de cliente, guardado tal cual (con
  /// `RedactionPolicy.strict()` uno con forma de email se redacta: ahí
  /// pasa uno opaco). [props]: JSON libre con lo que quieras
  /// ver al depurar a esa persona (email, nombre, tienda, plan…). Se guarda
  /// en claro porque lo mandas a propósito, salvo claves de secreto
  /// (contraseña, token, tarjeta…). Máximo ~4 KB.
  ///
  /// ```dart
  /// Thor.setUser('1737154', props: {
  ///   'email': user.email,
  ///   'nombre': user.name,
  ///   'tienda': {'id': 431, 'nombre': 'Centro'},
  /// });
  /// ```
  static void setUser(String? id, {Map<String, Object?>? props}) {
    final core = ThorCore.instance;
    if (core == null) return;
    final before = core.userId;
    core.setUser(id, props: props);
    // Solo si cambió la identidad: refrescar props no debe repetir llamadas
    // a las integraciones.
    if (core.userId != before) _notifySession();
  }

  /// Registra un proveedor de contexto de dominio.
  static void addContext(String key, ThorContextProvider provider) =>
      ThorCore.instance?.addContext(key, provider);
}

/// Foto de la sesión que reciben los listeners de
/// [Thor.addSessionListener].
@immutable
class ThorSessionInfo {
  const ThorSessionInfo._({
    required this.sessionId,
    required this.sessionUrl,
    required this.userId,
  });

  /// Id de la sesión de Thor.
  final String sessionId;

  /// Link al dashboard si hay [Thor.dashboardBaseUrl]; si no, `null`.
  final String? sessionUrl;

  /// Usuario fijado con [Thor.setUser]; `null` = anónimo.
  final String? userId;
}
