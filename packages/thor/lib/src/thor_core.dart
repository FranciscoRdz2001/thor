import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:meta/meta.dart';

import 'package:thor/src/model/event.dart';
import 'package:thor/src/model/gesture.dart';
import 'package:thor/src/model/log_level.dart';
import 'package:thor/src/model/session.dart';
import 'package:thor/src/network/connectivity_inference.dart';
import 'package:thor/src/network/raw_network_store.dart';
import 'package:thor/src/persistence/journal.dart';
import 'package:thor/src/recorder.dart';
import 'package:thor/src/redaction/redaction_policy.dart';
import 'package:thor/src/store/capture_policy.dart';
import 'package:thor/src/store/event_store.dart';
import 'package:thor/src/util/origin.dart';

/// Proveedor de contexto de dominio: se llama al generar un reporte para
/// fotografiar estado de negocio (cola de sync, turno abierto…).
typedef ThorContextProvider = Map<String, Object?> Function();

/// Fachada del núcleo de Thor.
///
/// Dart puro: no sabe de Flutter, dio ni bloc. Los adaptadores se cuelgan de
/// [recorder] y de los hooks públicos. `thor_flutter` expone el `Thor.run`
/// de alto nivel; esta clase es el motor debajo.
class ThorCore {
  ThorCore._({
    required this.recorder,
    required this.store,
    required this.session,
    required this.redaction,
    this.capture = const ThorCapturePolicy(),
    this.journal,
  });

  /// Instancia activa. `null` hasta [init] — los adaptadores deben tratar
  /// ese caso como no-op, jamás como error (Thor apagado no puede romper
  /// la app que diagnostica).
  static ThorCore? get instance => _instance;
  static ThorCore? _instance;

  /// Grabador central (los adaptadores registran a través de él).
  final ThorRecorder recorder;

  /// Almacén en memoria.
  final EventStore store;

  /// Sesión actual.
  final ThorSession session;

  /// Política de redacción vigente.
  final RedactionPolicy redaction;

  /// Límites de captura vigentes (ráfagas, largo de logs…).
  final ThorCapturePolicy capture;

  /// Journal en disco; `null` si se inicializó sin persistencia (tests,
  /// plataformas sin FS).
  final SessionJournal? journal;

  final Map<String, ThorContextProvider> _contextProviders = {};
  void Function()? _unsubscribeJournal;
  void Function()? _unsubscribeConnectivity;

  /// Sesión previa recuperada en [init]; si `endedCleanly == false`, la app
  /// murió y este es el material del reporte de crash.
  RecoveredSession? recoveredPrevious;

  /// Cómo se inicializó este núcleo, para [renewSession].
  Future<ThorCore> Function()? _reinit;

  /// Inicializa Thor. Idempotente: llamadas repetidas devuelven la
  /// instancia existente.
  ///
  /// - [storageDirectory]: dónde persistir journals (privado de la app).
  ///   `null` = solo memoria.
  /// - [installId]: identificador de instalación persistente; el adaptador
  ///   de Flutter lo provee. Si falta, se genera uno efímero.
  /// - [capture]: topes de ráfagas de estado y aligerado de red en el
  ///   journal (ver [ThorCapturePolicy]).
  /// - [redaction]: por defecto [RedactionPolicy.secretsOnly] (solo se
  ///   tapan secretos); `RedactionPolicy.strict()` para apps sensibles.
  static Future<ThorCore> init({
    Directory? storageDirectory,
    RedactionPolicy redaction = const RedactionPolicy.secretsOnly(),
    BufferQuotas? quotas,
    String? installId,
    Map<String, String> appInfo = const {},
    Map<String, String> deviceInfo = const {},
    ThorCapturePolicy capture = const ThorCapturePolicy(),
    bool announcePrevious = true,
  }) async {
    final existing = _instance;
    if (existing != null) return existing;

    final now = clock.now();
    final session = ThorSession(
      sessionId: generateThorId(),
      installId: installId ?? await _persistentInstallId(storageDirectory),
      startedAtUtc: now.toUtc(),
      utcOffset: now.timeZoneOffset,
      appInfo: appInfo,
      deviceInfo: deviceInfo,
    );
    final store = EventStore(quotas: quotas);
    final recorder = ThorRecorder(store: store, policy: capture);

    SessionJournal? journal;
    RecoveredSession? recovered;
    ThorCore? created;
    Object? earlyJournalError;
    if (storageDirectory != null) {
      // Primero mirar si la sesión anterior murió sin cerrar…
      recovered = await SessionJournal.recoverPrevious(storageDirectory);
      // …y luego abrir el journal propio.
      journal = SessionJournal(
        directory: storageDirectory,
        session: session,
        fullNetworkOnSuccess: capture.fullNetworkInJournal,
        // El journal es del SDK: su fallo es UN evento `source: 'thor'`,
        // nunca un error de la app (ni un bucle de errores).
        onFailure: (error) {
          if (created == null) {
            earlyJournalError = error; // falló al abrir, antes de existir
          } else {
            created.recordInternalError('journal', error);
          }
        },
      );
      await journal.start();
    }

    final core = ThorCore._(
      recorder: recorder,
      store: store,
      session: session,
      redaction: redaction,
      capture: capture,
      journal: journal,
    )
      ..recoveredPrevious = recovered
      // Sin plugin: "sin conexión" se infiere de las peticiones capturadas.
      .._unsubscribeConnectivity = ConnectivityInference.install(recorder);

    created = core;
    if (earlyJournalError != null) {
      core.recordInternalError('journal', earlyJournalError!);
    }
    if (journal != null) {
      // Los errores van a disco de inmediato: si la app está por morir,
      // la causa ya tiene que estar escrita.
      core._unsubscribeJournal = recorder.addListener(
        (event) => journal!.append(event, urgent: _isUrgent(event)),
      );
    }

    core._reinit = () => init(
          storageDirectory: storageDirectory,
          redaction: redaction,
          quotas: quotas,
          installId: session.installId,
          appInfo: appInfo,
          deviceInfo: deviceInfo,
          capture: capture,
          // La renovación ya dejó su propio `session_start`.
          announcePrevious: false,
        );
    _instance = core;
    // "¿Cómo terminó la sesión anterior?" — sin marca de fin en el journal
    // eso no se sabe; aquí queda dicho en la línea de tiempo de ESTA sesión.
    if (announcePrevious && recovered != null) {
      core.recorder.record(ThorEventKind.environment, {
        'signal': 'previous_session',
        'session': recovered.session.sessionId,
        'reason': recovered.endReason,
        if (recovered.lastLifecycleState case final state?) 'state': state,
        'backgroundMs': recovered.backgroundMs,
      });
    }
    return core;
  }

  /// Tope de errores internos del SDK por `what` y sesión: pasado eso solo
  /// se cuentan ([internalErrorsDropped]).
  static const maxInternalErrors = 3;

  final Map<String, int> _internalErrors = {};

  /// Errores internos descartados por el tope [maxInternalErrors].
  int internalErrorsDropped = 0;

  /// Graba un fallo del PROPIO SDK (journal, replay en disco…) como evento
  /// `error` con `source: 'thor'` e `internal: true`, para que el dash lo
  /// separe de los errores de la app. Con tope por [what] y sesión: un
  /// disco roto no debe inundar la línea de tiempo (9985 eventos en una
  /// sesión, el 96% del tablero). Nunca lanza.
  void recordInternalError(String what, Object error) {
    try {
      final n = _internalErrors[what] = (_internalErrors[what] ?? 0) + 1;
      if (n > maxInternalErrors) {
        internalErrorsDropped++;
        return;
      }
      recorder.record(ThorEventKind.error, {
        'source': 'thor',
        'internal': true,
        'component': what,
        'fatal': false,
        'type': error.runtimeType.toString(),
        'message': redaction.scrub(
          cleanLogText('$error', 500, scrub: redaction.scrub),
        ),
        if (n == maxInternalErrors) 'last': true,
      });
    } on Object {
      // Un fallo al avisar del fallo: se ignora.
    }
  }

  /// ¿[error] es un fallo de E/S sobre un archivo del propio SDK
  /// (`thor-<id>.jsonl`, `replay-<id>.jsonl` y sus `.on`/`.sent`)? Esos no
  /// son errores de la app.
  static bool isInternalFileError(Object error) {
    if (error is! FileSystemException) return false;
    final path = error.path ?? '';
    final i = path.lastIndexOf(RegExp(r'[/\\]'));
    final name = i < 0 ? path : path.substring(i + 1);
    return RegExp(r'^(thor|replay)-.*\.(jsonl|on|sent)$').hasMatch(name) ||
        name == installIdFile;
  }

  /// Nombre del archivo (dentro de `storageDirectory`) con el id de
  /// instalación: sobrevive a los lanzamientos, así las sesiones de una
  /// misma instalación se pueden unir.
  static const installIdFile = 'thor-install-id';

  /// Id de instalación estable: el que está en [installIdFile] o, si no hay
  /// (primer arranque), uno nuevo que se guarda ahí. Sin directorio o con
  /// el disco fallando, uno en memoria (cambia por lanzamiento: mejor eso
  /// que impedir el arranque).
  static Future<String> _persistentInstallId(Directory? dir) async {
    if (dir == null) return generateThorId();
    try {
      final file = File('${dir.path}/$installIdFile');
      if (file.existsSync()) {
        final saved = (await file.readAsString()).trim();
        if (RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(saved)) return saved;
      }
      final id = generateThorId();
      await dir.create(recursive: true);
      await file.writeAsString(id, flush: true);
      return id;
    } on Object {
      return generateThorId();
    }
  }

  /// Termina esta sesión (cierre limpio: ráfagas, flush, marca de fin en el
  /// journal) y arranca una nueva en su lugar: mismo dispositivo, misma
  /// instalación, mismo usuario y mismos proveedores de contexto, otro
  /// `sessionId`, línea de tiempo vacía y journal propio.
  ///
  /// Es lo que hace `Thor.run(sessionTimeout: …)` cuando la app vuelve de
  /// un segundo plano largo. Los adaptadores que guardan el
  /// `recorder` viejo deben re-engancharse al devolver; la pantalla activa
  /// se conserva. Devuelve `this` si esta instancia ya no es la activa.
  Future<ThorCore> renewSession({String reason = 'renewed'}) async {
    final reinit = _reinit;
    if (reinit == null || !identical(_instance, this)) return this;
    final previousId = session.sessionId;
    final screen = recorder.currentScreen;
    final user = (id: _userId, props: _userProps);
    final contexts = Map.of(_contextProviders);
    recorder.record(ThorEventKind.environment, {
      'signal': 'session_end',
      'reason': reason,
    });
    await dispose(reason: reason);
    final next = await reinit();
    next
      ..recoveredPrevious = null
      .._contextProviders.addAll(contexts)
      ..recorder.currentScreen = screen;
    next.recorder.record(ThorEventKind.environment, {
      'signal': 'session_start',
      'reason': reason,
      'previous': previousId,
    });
    if (user.id != null || user.props != null) {
      // Directo, sin pasar por la política: ya vienen limpios.
      next
        .._userId = user.id
        .._userProps = user.props;
      next.recorder.record(ThorEventKind.environment, {
        'signal': 'user',
        'id': user.id,
        if (user.props != null) 'props': user.props,
      });
    }
    return next;
  }

  /// Un log de nivel error es tan evidencia como un error capturado: si la
  /// app muere después, tiene que estar en disco.
  static bool _isUrgent(ThorEvent event) =>
      event.kind == ThorEventKind.error ||
      (event.kind == ThorEventKind.log &&
          event.payload['level'] == ThorLogLevel.error.name);

  /// Tope del stack de un log de error: alcanza para ubicar el fallo sin
  /// que un log en bucle infle el journal.
  static const _maxLogStackChars = 2000;

  /// Graba una línea de log (`ThorEventKind.log` con `level`, `source` y
  /// `message`).
  ///
  /// Es lo que hay debajo de la captura de `print`/`debugPrint` y de
  /// `Thor.log`. PRIVACIDAD: el mensaje (y [name] y [error]) pasan por
  /// [RedactionPolicy.scrub] de la política vigente y se truncan a
  /// [ThorCapturePolicy.maxLogLength] ANTES de grabarse. Con la política
  /// por defecto (solo secretos) se quitan `Bearer …`, `password=…`,
  /// `token=…` y similares, y el resto (emails, ids) queda legible para
  /// depurar; con `RedactionPolicy.strict()` además emails, números largos
  /// y tokens sueltos se vuelven `:email`/`:n`/`:token`. Las ráfagas se
  /// recortan en el grabador (ver [ThorCapturePolicy.logBurstLimit]).
  ///
  /// [source]: `thor` (API explícita), `print` o `debugPrint`.
  void log(
    String message, {
    ThorLogLevel level = ThorLogLevel.info,
    String source = 'thor',
    String? name,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) {
    final max = capture.maxLogLength;
    final cleanData = _boundData(data, maxLogDataChars);
    final scrub = redaction.scrub;
    recorder.record(
      ThorEventKind.log,
      {
        'level': level.name,
        'source': source,
        'message': cleanLogText(message, max, scrub: scrub),
        if (cleanData != null) 'data': cleanData,
        if (name != null && name.isNotEmpty)
          'name': cleanLogText(name, 80, scrub: scrub),
        if (error != null) ...{
          'error': cleanLogText('$error', max, scrub: scrub),
          'errorType': error.runtimeType.toString(),
        },
        if (stackTrace != null && level == ThorLogLevel.error)
          'stack': _clip('$stackTrace', _maxLogStackChars),
      },
      origin: stackTrace == null ? null : originFromStack(stackTrace),
    );
  }

  /// Tope de los campos estructurados de un log (`data`) serializados.
  static const maxLogDataChars = 2048;

  /// Tope de las `props` de un [track] serializadas (~2 KB).
  static const maxTrackPropsChars = 2048;

  /// Tope del nombre de un evento de negocio.
  static const _maxTrackNameChars = 80;

  /// Graba un evento de negocio (`ThorEventKind.track`): `payload`
  /// `{name, props?}`. Es lo que la app manda A PROPÓSITO para contar el
  /// recorrido ("agregó al carrito", "pagó"), así que [props] se guardan
  /// legibles salvo secretos (política vigente: con la de por defecto solo
  /// se tapan claves y valores de secreto; con `strict()` los valores
  /// sueltos se enmascaran). Lo que no es JSON se convierte a texto y más
  /// de [maxTrackPropsChars] se descarta (queda `{"_truncated": true}`).
  void track(String name, [Map<String, Object?> props = const {}]) {
    final clean = _boundData(props, maxTrackPropsChars);
    recorder.record(ThorEventKind.track, {
      'name': cleanLogText(name, _maxTrackNameChars, scrub: redaction.scrub),
      if (clean != null) 'props': clean,
    });
  }

  /// Graba un tiempo propio de la app (`ThorEventKind.performance`,
  /// `kind: 'custom'`): `{name, ms, data?}`. Es la puerta para que el
  /// medidor de la app (un `PerformanceTracker`, un trace de Firebase…)
  /// reenvíe sus tiempos con una línea. [data] sigue las reglas de
  /// [track] (sin secretos, ~2 KB). Un [ms] no finito o negativo se ignora.
  void measure(String name, num ms, {Map<String, Object?>? data}) {
    if (!ms.isFinite || ms < 0) return;
    final clean = _boundData(data, maxTrackPropsChars);
    recorder.record(ThorEventKind.performance, {
      'kind': 'custom',
      'name': cleanLogText(name, _maxTrackNameChars, scrub: redaction.scrub),
      'ms': ms.round(),
      if (clean != null) 'data': clean,
    });
  }

  /// [data] redactado con la política vigente, forzado a JSON puro y
  /// acotado a [maxChars] serializados; `null` si no hay datos.
  Map<String, Object?>? _boundData(Map<String, Object?>? data, int maxChars) {
    if (data == null || data.isEmpty) return null;
    try {
      // Dos pasadas a propósito: la primera tapa secretos por clave/valor y
      // normaliza las claves; el ida y vuelta por JSON convierte a texto lo
      // no serializable (`toString()` de un objeto o excepción puede traer
      // `token=…`), así que la SEGUNDA pasada limpia ese texto nuevo.
      final first = redaction.redactValue(data);
      final json = jsonEncode(first, toEncodable: (v) => v.toString());
      final redacted = redaction.redactValue(jsonDecode(json));
      final out = jsonEncode(redacted);
      if (out.length > maxChars) return {'_truncated': true};
      return (jsonDecode(out) as Map).cast<String, Object?>();
    } on Object {
      // Un mapa cíclico o un toString que lanza no puede tumbar a la app.
      return {'_unserializable': true};
    }
  }

  /// [text] limpio con [scrub] y recortado a [max].
  ///
  /// [scrub] es normalmente `redaction.scrub` de la política vigente; sin
  /// él se usa la limpieza más estricta ([RedactionPolicy.scrubText]:
  /// secretos y datos con forma personal), para quien llame sin política.
  ///
  /// Se recorta ANTES de limpiar (a 4×[max]) porque la limpieza es regex
  /// sobre el texto entero y un `print(json)` puede pesar un megabyte; el
  /// margen evita cortar un email a la mitad justo en el borde.
  static String cleanLogText(
    String text,
    int max, {
    String Function(String text) scrub = RedactionPolicy.scrubText,
  }) {
    final head = text.length > max * 4 ? text.substring(0, max * 4) : text;
    final clean = scrub(head);
    if (clean.length <= max && head.length == text.length) return clean;
    final cut = clean.length <= max ? clean : clean.substring(0, max);
    return '$cut…(+${text.length - cut.length})';
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…(+${s.length - max})';

  /// Marca libre en la línea de tiempo (`Thor.mark('cobro_iniciado')`).
  void mark(String label, [Map<String, Object?> data = const {}]) {
    recorder.record(ThorEventKind.log, {
      'label': label,
      if (data.isNotEmpty) 'data': redaction.redactValue(data),
    });
  }

  /// Fija la pantalla activa manualmente — para navegación que el Navigator
  /// no ve (tabs, PageView, wizards internos).
  void setScreen(String name) {
    recorder.currentScreen = ScreenId(widgetClass: name);
    recorder.record(ThorEventKind.navigation, {
      'action': 'manual',
      'to': name,
    });
  }

  /// Contexto fino de la pantalla actual (ver [ScreenId.detail]): para una
  /// clase de pantalla que sirve a muchos contextos, `Departamentos >
  /// Carnes > Res Selecta`. Va a la línea de tiempo (`environment`,
  /// `signal: 'screen_context'`) y acompaña a los eventos siguientes; se
  /// limpia solo al cambiar de pantalla. `null` lo quita. Se limpia de
  /// secretos y se recorta.
  void setScreenContext(String? detail) {
    final current = recorder.currentScreen;
    if (current == null) return;
    final clean = detail == null || detail.trim().isEmpty
        ? null
        : cleanLogText(detail.trim(), 120, scrub: redaction.scrub);
    if (clean == current.detail) return;
    recorder.currentScreen = current.withDetail(clean);
    recorder.record(ThorEventKind.environment, {
      'signal': 'screen_context',
      'value': clean,
    });
  }

  String? _userId;
  Map<String, Object?>? _userProps;

  /// Usuario actual fijado con [setUser]; `null` = anónimo.
  String? get userId => _userId;

  /// Datos adicionales del usuario actual (sin secretos).
  Map<String, Object?>? get userProps => _userProps;

  /// Tope de [setUser] `props` serializados: la identidad viaja con cada
  /// sesión y no debe pesar más que el replay mismo.
  static const maxUserPropsChars = 4096;

  /// Fija (o limpia con `null`) el usuario de la sesión — para buscar "la
  /// sesión del usuario X" cuando llega la queja.
  ///
  /// [id] se guarda TAL CUAL (sin hash: hay que poder cruzarlo con el
  /// backend). Con `RedactionPolicy.strict()` debe ser OPACO (id interno
  /// de cliente): un id con forma de email se sustituye por
  /// [RedactionPolicy.redactedMarker]. Con la política por defecto (solo
  /// secretos) un email también pasa: es justo lo que se busca al depurar.
  ///
  /// [props] es JSON libre (mapas, listas, números, texto) con cualquier
  /// dato que la app quiera ver al depurar: email, nombre, tienda, plan…
  /// A diferencia de lo que Thor captura solo, esto lo manda la app A
  /// PROPÓSITO, así que se guarda en claro — salvo las claves de secreto
  /// (contraseña, token, tarjeta, CVV…), que nunca pasan. Lo que no es
  /// JSON se convierte a texto; más de [maxUserPropsChars] se descarta
  /// (queda `{"_truncated": true}`).
  ///
  /// Graba un evento de entorno `signal: 'user'` solo si algo cambió.
  void setUser(String? id, {Map<String, Object?>? props}) {
    final safeId =
        id != null && !redaction.isSecretsOnly && _emailShaped.hasMatch(id)
            ? RedactionPolicy.redactedMarker
            : id;
    final clean = _cleanProps(props);
    if (safeId == _userId && _sameJson(clean, _userProps)) return;
    final previousId = _userId;
    _userId = safeId;
    _userProps = clean;
    recorder.record(ThorEventKind.environment, {
      'signal': 'user',
      'id': safeId,
      if (clean != null) 'props': clean,
    });
    if (safeId == null) _checkSilentLogout(previousId);
  }

  static Map<String, Object?>? _cleanProps(Map<String, Object?>? props) {
    if (props == null || props.isEmpty) return null;
    // Ida y vuelta por JSON: valida, y lo no serializable queda como texto.
    final json = jsonEncode(
      RedactionPolicy.redactSecrets(props),
      toEncodable: (v) => v.toString(),
    );
    if (json.length > maxUserPropsChars) return {'_truncated': true};
    return (jsonDecode(json) as Map).cast<String, Object?>();
  }

  static bool _sameJson(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

  static final _emailShaped = RegExp(r'[^\s@]+@[^\s@]+\.[^\s@]+');

  // ── Señales de alto nivel: permisos, superficies externas, problemas ──

  /// Tiempo total en segundo plano de esta sesión (ms), sumado por el
  /// adaptador de ciclo de vida. Va en la marca de fin del journal.
  int backgroundMs = 0;

  /// Graba un permiso del sistema (`environment {signal: 'permission'}`):
  /// [kind] (`camera`, `microphone`, `speech`, `location`, `photos`,
  /// `contacts`, `notifications`…), estado [before] → [after] (`granted`,
  /// `denied`, `restricted`, `limited`, `undetermined`) y si salió el
  /// diálogo del sistema ([prompt]). [source]: `app` (la app lo reporta),
  /// `error` (inferido de un error de permiso) u `overlay`.
  ///
  /// Se omite si nada cambió y no hubo [prompt]: el mismo `denied` repetido
  /// en cada pantalla no es una señal nueva.
  void permission(
    String kind, {
    String? before,
    String? after,
    bool prompt = false,
    String source = 'app',
  }) {
    final k = cleanLogText(kind, 40);
    final b = before == null ? null : cleanLogText(before, 40);
    final a = after == null ? null : cleanLogText(after, 40);
    final key = '$k|$b|$a|$prompt';
    if (!prompt && _lastPermission[k] == key) return;
    _lastPermission[k] = key;
    recorder.record(ThorEventKind.environment, {
      'signal': 'permission',
      'kind': k,
      if (b != null) 'before': b,
      if (a != null) 'after': a,
      'prompt': prompt,
      'source': source,
    });
  }

  final Map<String, String> _lastPermission = {};

  /// Qué permiso nombra un texto de error/excepción de permiso denegado
  /// (`CameraAccessDenied`, «Permission denied: microphone», «speech
  /// recognition not authorized»); `null` si no habla de un permiso.
  /// Heurística barata y conservadora: exige palabra de permiso Y recurso.
  static String? permissionKindFromText(String text) {
    final t = text.toLowerCase();
    final denied = t.contains('permission') ||
        t.contains('permiso') ||
        t.contains('denied') ||
        t.contains('denegad') ||
        t.contains('not authorized') ||
        t.contains('unauthorized') ||
        t.contains('accessdenied') ||
        t.contains('access denied');
    if (!denied) return null;
    if (t.contains('camera') || t.contains('cámara') || t.contains('camara')) {
      return 'camera';
    }
    if (t.contains('microphone') ||
        t.contains('micrófono') ||
        t.contains('microfono') ||
        t.contains('record_audio') ||
        t.contains('audio recording')) {
      return 'microphone';
    }
    if (t.contains('speech')) return 'speech';
    if (t.contains('location') || t.contains('ubicaci')) return 'location';
    if (t.contains('photo') || t.contains('gallery')) return 'photos';
    if (t.contains('contacts')) return 'contacts';
    if (t.contains('notification')) return 'notifications';
    return null;
  }

  /// Graba una superficie externa (`environment {signal:
  /// 'external_surface'}`): la app cedió la pantalla a otra cosa — Safari /
  /// Chrome Custom Tab (`in_app_browser`), otra app (`external_app`), un
  /// WebView propio (`webview`) o una hoja del sistema (`system_ui`).
  /// [host] es solo el host (nunca la ruta ni la query: pueden traer
  /// secretos); [open] `true` al abrir y `false` al cerrar; [ms] cuánto
  /// estuvo abierta (al cerrar).
  void externalSurface(
    String host, {
    String mode = 'external_app',
    bool open = true,
    int? ms,
  }) {
    // Solo el host: con o sin esquema, jamás la ruta, la query ni el
    // fragmento (pueden traer secretos).
    final parsed = Uri.tryParse(host)?.host ?? '';
    final bare =
        parsed.isNotEmpty ? parsed : host.split(RegExp(r'[/?#]')).first.trim();
    final clean = cleanLogText(bare, 120, scrub: redaction.scrub);
    recorder.record(ThorEventKind.environment, {
      'signal': 'external_surface',
      'host': clean,
      'mode': cleanLogText(mode, 40),
      'state': open ? 'open' : 'close',
      if (ms != null) 'ms': ms,
    });
  }

  /// Graba un PROBLEMA que el usuario vio o sufrió aunque no haya una
  /// excepción (diálogo de error, congelamiento, toque muerto, pantalla
  /// vacía, logout silencioso…) como evento `error` con [source] propio y
  /// `fatal: false`: entra a los issues igual que un error real. Nunca
  /// lanza.
  void problem(
    String source,
    String type,
    String message, {
    Map<String, Object?> extra = const {},
    String? origin,
  }) {
    try {
      recorder.record(
        ThorEventKind.error,
        {
          'source': source,
          'fatal': false,
          'type': type,
          'message': cleanLogText(message, 500, scrub: redaction.scrub),
          ...extra,
          ...lastActionPayload(),
        },
        origin: origin,
      );
    } on Object {
      // Observar jamás debe tumbar a la app.
    }
  }

  /// `{lastAction: 'tocó «X» (#n)'}` con el último toque, o vacío.
  Map<String, Object?> lastActionPayload() {
    final tap = store
        .ofKind(ThorEventKind.interaction)
        .reversed
        .where((e) => ThorGesture.isPress(e.payload['gesture']))
        .firstOrNull;
    if (tap == null) return const {};
    final label = tap.payload['label'] ?? tap.payload['widget'];
    return {'lastAction': 'tocó «$label» (#${tap.seq})'};
  }

  /// Ventana tras un toque en la que un `setUser(null)` todavía cuenta como
  /// acción del usuario ("Cerrar sesión" + diálogo de confirmación).
  static const silentLogoutWindow = Duration(seconds: 5);

  /// `setUser(null)` sin que el usuario haya tocado nada hace un momento:
  /// la sesión de la app terminó sola (refresh de token rechazado, signoff
  /// del backend). Es un problema visible — el carrito y el perfil
  /// desaparecen — que no deja ninguna excepción.
  void _checkSilentLogout(String? previous) {
    if (previous == null) return;
    final now = clock.now().toUtc();
    final tap = store
        .ofKind(ThorEventKind.interaction)
        .reversed
        .where((e) => ThorGesture.isPress(e.payload['gesture']))
        .firstOrNull;
    if (tap != null && now.difference(tap.atUtc) <= silentLogoutWindow) return;
    problem(
      'silent_logout',
      'SilentLogout',
      'La sesión terminó sin que el usuario lo pidiera (usuario → anónimo)',
      extra: {
        if (tap != null) 'sinceTapMs': now.difference(tap.atUtc).inMilliseconds,
      },
    );
  }

  /// Registra un proveedor de contexto de dominio bajo [key].
  void addContext(String key, ThorContextProvider provider) {
    _contextProviders[key] = provider;
  }

  /// Fotografía todos los contextos registrados (redactados). Un proveedor
  /// que lanza no tumba a los demás: su error queda como su propio valor.
  Map<String, Object?> snapshotContext() => {
        for (final MapEntry(:key, value: provider) in _contextProviders.entries)
          key: _safeContext(provider),
      };

  Object? _safeContext(ThorContextProvider provider) {
    try {
      return redaction.redactValue(provider());
    } on Object catch (e) {
      return {'error': 'proveedor de contexto lanzó: $e'};
    }
  }

  /// Cierre limpio (sesión terminó bien). Tras esto, [instance] es `null`.
  ///
  /// [reason] (`clean`, `renewed`…) queda en la marca de fin del journal.
  Future<void> dispose({String reason = 'clean'}) async {
    // Los cURLs crudos son de ESTA sesión: mueren con ella.
    RawNetworkStore.clear();
    // Los conteos de ráfagas abiertas se escriben antes del cierre: son
    // hallazgo, no ruido.
    recorder.flushBursts();
    _unsubscribeJournal?.call();
    _unsubscribeConnectivity?.call();
    await journal?.close(reason: reason, backgroundMs: backgroundMs);
    if (identical(_instance, this)) _instance = null;
  }

  /// Solo tests: resetea el singleton sin cierre limpio (simula crash).
  @visibleForTesting
  static void debugReset() => _instance = null;
}
