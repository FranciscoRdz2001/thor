import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:meta/meta.dart';

import 'package:thor/src/model/event.dart';
import 'package:thor/src/model/log_level.dart';
import 'package:thor/src/model/session.dart';
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

  /// Sesión previa recuperada en [init]; si `endedCleanly == false`, la app
  /// murió y este es el material del reporte de crash.
  RecoveredSession? recoveredPrevious;

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
  }) async {
    final existing = _instance;
    if (existing != null) return existing;

    final now = clock.now();
    final session = ThorSession(
      sessionId: generateThorId(),
      installId: installId ?? generateThorId(),
      startedAtUtc: now.toUtc(),
      utcOffset: now.timeZoneOffset,
      appInfo: appInfo,
      deviceInfo: deviceInfo,
    );
    final store = EventStore(quotas: quotas);
    final recorder = ThorRecorder(store: store, policy: capture);

    SessionJournal? journal;
    RecoveredSession? recovered;
    if (storageDirectory != null) {
      // Primero mirar si la sesión anterior murió sin cerrar…
      recovered = await SessionJournal.recoverPrevious(storageDirectory);
      // …y luego abrir el journal propio.
      journal = SessionJournal(
        directory: storageDirectory,
        session: session,
        fullNetworkOnSuccess: capture.fullNetworkInJournal,
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
    )..recoveredPrevious = recovered;

    if (journal != null) {
      // Los errores van a disco de inmediato: si la app está por morir,
      // la causa ya tiene que estar escrita.
      core._unsubscribeJournal = recorder.addListener(
        (event) => journal!.append(event, urgent: _isUrgent(event)),
      );
    }

    return _instance = core;
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

  /// [data] redactado con la política vigente, forzado a JSON puro y
  /// acotado a [maxChars] serializados; `null` si no hay datos.
  Map<String, Object?>? _boundData(Map<String, Object?>? data, int maxChars) {
    if (data == null || data.isEmpty) return null;
    try {
      final redacted = redaction.redactValue(data);
      // Ida y vuelta por JSON: valida, y lo no serializable queda como texto.
      final json = jsonEncode(redacted, toEncodable: (v) => v.toString());
      if (json.length > maxChars) return {'_truncated': true};
      return (jsonDecode(json) as Map).cast<String, Object?>();
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
    _userId = safeId;
    _userProps = clean;
    recorder.record(ThorEventKind.environment, {
      'signal': 'user',
      'id': safeId,
      if (clean != null) 'props': clean,
    });
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
  Future<void> dispose() async {
    // Los cURLs crudos son de ESTA sesión: mueren con ella.
    RawNetworkStore.clear();
    // Los conteos de ráfagas abiertas se escriben antes del cierre: son
    // hallazgo, no ruido.
    recorder.flushBursts();
    _unsubscribeJournal?.call();
    await journal?.close();
    if (identical(_instance, this)) _instance = null;
  }

  /// Solo tests: resetea el singleton sin cierre limpio (simula crash).
  @visibleForTesting
  static void debugReset() => _instance = null;
}
