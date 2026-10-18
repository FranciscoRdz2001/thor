import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:thor/src/model/event.dart';
import 'package:thor/src/model/session.dart';

/// Resultado de inspeccionar el journal de una sesión previa al arrancar.
class RecoveredSession {
  /// Crea el resultado de una recuperación.
  const RecoveredSession({
    required this.session,
    required this.events,
    required this.endedCleanly,
    required this.corruptLines,
    this.closeReason,
    this.closeBackgroundMs,
  });

  /// Motivo declarado en la marca de cierre (`clean`, `renewed`…); `null`
  /// si no hay marca o es de una versión anterior.
  final String? closeReason;

  /// Milisegundos en segundo plano que traía la marca de cierre.
  final int? closeBackgroundMs;

  /// Cómo terminó la sesión: `clean` (cierre normal, o el motivo que
  /// declaró), `crash` (error fatal o muerta en primer plano) o `killed`
  /// (la mató el usuario o el SO en segundo plano).
  String get endReason {
    if (endedCleanly) return closeReason ?? 'clean';
    return crashed ? 'crash' : 'killed';
  }

  /// Total de tiempo en segundo plano de la sesión: el declarado al cerrar
  /// o, si murió sin cerrar, la suma de los `backgroundMs` de sus eventos
  /// de ciclo de vida.
  int get backgroundMs {
    final declared = closeBackgroundMs;
    if (declared != null) return declared;
    var total = 0;
    for (final e in events) {
      if (e.kind == ThorEventKind.environment &&
          e.payload['signal'] == 'lifecycle') {
        final ms = e.payload['backgroundMs'];
        if (ms is int) total += ms;
      }
    }
    return total;
  }

  /// Cabecera de la sesión recuperada.
  final ThorSession session;

  /// Eventos legibles del journal, en orden.
  final List<ThorEvent> events;

  /// `true` si el journal tiene marca de cierre — la sesión terminó bien.
  /// `false` = la app murió con el journal abierto: ese es el reporte de
  /// crash que se le ofrece a QA al reiniciar.
  final bool endedCleanly;

  /// Líneas ilegibles descartadas (última línea a medio escribir en un
  /// crash es lo normal). Se reporta para que el truncado sea visible.
  final int corruptLines;

  /// Último estado de ciclo de vida registrado (`resumed`, `inactive`,
  /// `paused`, `hidden`, `detached`), o `null` si la sesión no registró
  /// ninguno (nunca salió de primer plano).
  String? get lastLifecycleState {
    for (final e in events.reversed) {
      if (e.kind == ThorEventKind.environment &&
          e.payload['signal'] == 'lifecycle') {
        return e.payload['state'] as String?;
      }
    }
    return null;
  }

  /// Si se grabó un error fatal / no manejado (`fatal: true`: zona o
  /// `PlatformDispatcher.onError`).
  bool get hasFatalError => events.any(
        (e) => e.kind == ThorEventKind.error && e.payload['fatal'] == true,
      );

  /// ¿La sesión REALMENTE se cayó? Distinto de `!endedCleanly`: el usuario
  /// o el SO matan procesos en segundo plano sin que nada falle, y eso no
  /// es un crash que QA deba revisar.
  ///
  /// - Con marca de cierre: no.
  /// - Con un error fatal/no manejado grabado: sí.
  /// - Sin cierre y sin error fatal: sí solo si la app murió en primer
  ///   plano. Si el último ciclo de vida fue `paused`/`hidden`/`detached`
  ///   (o `inactive`, que es lo último que se ve al matarla desde el
  ///   selector de apps o `simctl terminate`), la mató el usuario o el SO.
  bool get crashed {
    if (endedCleanly) return false;
    if (hasFatalError) return true;
    final state = lastLifecycleState;
    return state == null || state == 'resumed';
  }
}

/// Journal append-only por sesión: la persistencia que sobrevive al crash.
///
/// Formato: un archivo JSONL por sesión. Primera línea `{"type":"session"…}`,
/// luego una línea por evento, y al cierre limpio `{"type":"end"}`. Si la app
/// muere, la marca de cierre nunca se escribe — así se detecta el crash al
/// siguiente arranque sin necesitar ningún hook del sistema.
///
/// Las escrituras van en lotes ([flushInterval] o [flushThreshold], lo que
/// ocurra primero) para no tocar disco en cada evento; `flush` inmediato
/// disponible para los momentos críticos (se acaba de grabar un error).
class SessionJournal {
  /// Abre (creando) el journal de [session] dentro de [directory].
  SessionJournal({
    required this.directory,
    required this.session,
    this.flushInterval = const Duration(seconds: 2),
    this.flushThreshold = 25,
    this.maxSessions = 10,
    this.fullNetworkOnSuccess = false,
    this.maxWriteFailures = 3,
    this.onFailure,
  });

  /// Directorio raíz de journals (privado de la app).
  final Directory directory;

  /// Sesión dueña de este journal.
  final ThorSession session;

  /// Máximo tiempo que un evento espera en memoria antes de ir a disco.
  final Duration flushInterval;

  /// Máximo de eventos pendientes antes de forzar escritura.
  final int flushThreshold;

  /// Sesiones antiguas a conservar; el resto se purga en [start] (nadie
  /// quiere el SDK que llenó el disco del dispositivo).
  final int maxSessions;

  /// Si las peticiones EXITOSAS se escriben completas. Por defecto no:
  /// headers, bodies y cURL de una petición que salió bien pesaban ~2.7 KB
  /// por evento y no explican ningún bug; la versión ligera conserva lo
  /// que sí sirve (método, URL, status, duración, bytes). Las fallidas se
  /// escriben siempre completas — ahí el cuerpo ES la causa.
  final bool fullNetworkOnSuccess;

  /// Escrituras seguidas que pueden fallar antes de rendirse: pasado el
  /// tope el journal se apaga (ver [disabled]) en vez de insistir en bucle.
  final int maxWriteFailures;

  /// Se llama UNA vez, cuando el journal se rinde. El núcleo lo usa para
  /// dejar un solo error de origen `thor` (no del código de la app).
  final void Function(Object error)? onFailure;

  static const _sessionPrefix = 'thor-';
  static const _sessionSuffix = '.jsonl';

  IOSink? _sink;
  final List<String> _pending = [];
  Timer? _flushTimer;
  bool _closed = false;
  int _writeFailures = 0;
  bool _disabled = false;

  /// `true` si el journal se rindió tras [maxWriteFailures] fallos de
  /// escritura seguidos (directorio borrado, disco lleno…): ya no escribe
  /// nada y no vuelve a avisar. La app sigue; solo se pierde la persistencia.
  bool get disabled => _disabled;

  /// Ruta del archivo de esta sesión.
  File get file => File(
        p.join(
          directory.path,
          '$_sessionPrefix${session.sessionId}$_sessionSuffix',
        ),
      );

  /// Abre el journal: escribe la cabecera de sesión y purga sesiones viejas.
  ///
  /// Nunca lanza: si no se puede abrir el archivo el journal queda apagado
  /// ([disabled]) y la app arranca igual.
  Future<void> start() async {
    try {
      await directory.create(recursive: true);
      _openSink();
    } on Object catch (e) {
      _giveUp(e);
      return;
    }
    _pending.add(_headerLine());
    await flush();
    await _purgeOldSessions();
  }

  String _headerLine() =>
      jsonEncode({'type': 'session', ...session.toJson()});

  void _openSink() {
    final sink = file.openWrite(mode: FileMode.writeOnlyAppend);
    // Un error de apertura/escritura también sale por `done`; sin oyente
    // subiría como error NO capturado de la zona (y, en la app, como un
    // error suyo). Lo vemos por `flush`.
    unawaited(sink.done.then((_) {}, onError: (Object _) {}));
    _sink = sink;
  }

  /// Re-crea el directorio y el archivo (alguien los borró: reinstalación
  /// del build, limpieza de caché) y vuelve a escribir la cabecera para que
  /// el archivo siga siendo una sesión legible. `false` si no se pudo.
  Future<bool> _reopen() async {
    try {
      try {
        await _sink?.close();
      } on Object {
        // El sink viejo ya apuntaba a un archivo que no existe.
      }
      _sink = null;
      await directory.create(recursive: true);
      final fresh = !file.existsSync();
      _openSink();
      if (fresh) _sink!.writeln(_headerLine());
      return true;
    } on Object {
      return false;
    }
  }

  void _giveUp(Object error) {
    if (_disabled) return;
    _disabled = true;
    _pending.clear();
    _flushTimer?.cancel();
    _flushTimer = null;
    _sink = null;
    try {
      onFailure?.call(error);
    } on Object {
      // Avisar jamás puede romper nada.
    }
  }

  /// Encola [event]; irá a disco en el próximo lote.
  ///
  /// [urgent] fuerza flush inmediato — para errores: si la app va a morir,
  /// que el evento que explica por qué ya esté en disco.
  void append(ThorEvent event, {bool urgent = false}) {
    if (_closed || _disabled || _sink == null) return;
    final json = event.toJson();
    if (!fullNetworkOnSuccess && event.kind == ThorEventKind.network) {
      json['payload'] = lightNetworkPayload(event.payload);
    }
    _pending.add(jsonEncode({'type': 'event', ...json}));
    if (urgent || _pending.length >= flushThreshold) {
      unawaited(flush());
    } else {
      _flushTimer ??= Timer(flushInterval, () => unawaited(flush()));
    }
  }

  /// Claves que sobreviven en una petición exitosa aligerada.
  static const _lightNetworkKeys = {
    'method',
    'url',
    'statusCode',
    'durationMs',
    'requestBytes',
    'responseBytes',
    // Cifras de una regla de endpoint: pesan poco y son el motivo de la regla.
    'extracts',
  };

  /// Versión ligera de un payload de red: las exitosas se quedan con lo
  /// esencial y `lite: true` (para que nadie lea la ausencia de headers
  /// como "no hubo headers"); las fallidas pasan intactas.
  static Map<String, Object?> lightNetworkPayload(Map<String, Object?> p) {
    final status = p['statusCode'];
    final failed = p['error'] != null || status is! int || status >= 400;
    if (failed) return p;
    return {
      for (final MapEntry(:key, :value) in p.entries)
        if (_lightNetworkKeys.contains(key)) key: value,
      'lite': true,
    };
  }

  Future<void> _flushChain = Future<void>.value();

  /// Escribe lo pendiente a disco.
  ///
  /// Serializado: cada flush espera al anterior. Sin esto, un flush urgente
  /// en vuelo y un `await flush()` posterior podían resolverse fuera de
  /// orden y el caller creía persistido lo que aún no tocaba disco
  /// (flake real cazado en CI).
  ///
  /// Nunca falla: un error de disco se cuenta ([maxWriteFailures]) y, si
  /// persiste, apaga el journal. Quien lo llama con `unawaited` no puede
  /// dejar un error sin manejar (era el bucle de `PathNotFoundException`).
  Future<void> flush() {
    final next = _flushChain.then((_) => _doFlush()).catchError(_writeFailed);
    _flushChain = next;
    return next;
  }

  Future<void> _doFlush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_disabled || _sink == null || _pending.isEmpty) return;
    final batch = _pending.join('\n');
    _pending.clear();
    // Si el archivo desapareció, el descriptor abierto sigue "escribiendo"
    // en un inodo huérfano sin error: se detecta aquí, no por una excepción.
    var reopened = false;
    if (!file.existsSync()) {
      reopened = await _reopen();
      if (!reopened) return _writeFailed(const FileSystemException('journal'));
    }
    try {
      _sink!.writeln(batch);
      await _sink!.flush();
      _writeFailures = 0;
    } on Object catch (e) {
      // Un reintento tras recrear el archivo; si tampoco, cuenta como fallo.
      if (!reopened && await _reopen()) {
        try {
          _sink!.writeln(batch);
          await _sink!.flush();
          _writeFailures = 0;
          return;
        } on Object catch (e2) {
          return _writeFailed(e2);
        }
      }
      _writeFailed(e);
    }
  }

  void _writeFailed(Object error) {
    if (++_writeFailures >= maxWriteFailures) _giveUp(error);
  }

  /// Cierre limpio: marca de fin + flush + cierre del archivo.
  /// Si esto nunca corre (crash), [recoverPrevious] lo detecta.
  ///
  /// [reason] (`clean`, `renewed`…) y [backgroundMs] quedan en la marca de
  /// fin: la siguiente ejecución sabe cómo terminó esta sesión.
  Future<void> close({String reason = 'clean', int? backgroundMs}) async {
    if (_closed) return;
    _closed = true;
    _pending.add(
      jsonEncode({
        'type': 'end',
        'atUtc': DateTime.now().toUtc().toIso8601String(),
        'reason': reason,
        if (backgroundMs != null) 'backgroundMs': backgroundMs,
      }),
    );
    await flush();
    try {
      await _sink?.close();
    } on Object {
      // Cerrar un archivo que ya no existe no es motivo de error.
    }
    _sink = null;
  }

  Future<void> _purgeOldSessions() async {
    final files = await _listSessionFiles(directory);
    if (files.length <= maxSessions) return;
    // Más viejas primero (el nombre arranca con timestamp base36 del id).
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final old in files.take(files.length - maxSessions)) {
      try {
        await old.delete();
      } on FileSystemException {
        // Purga best-effort: no puede tirar el arranque de la app.
      }
    }
  }

  static Future<List<File>> _listSessionFiles(Directory dir) async {
    if (!dir.existsSync()) return [];
    return [
      await for (final f in dir.list())
        if (f is File &&
            p.basename(f.path).startsWith(_sessionPrefix) &&
            f.path.endsWith(_sessionSuffix))
          f,
    ];
  }

  /// Inspecciona el journal más reciente que NO sea [excludeSessionId].
  ///
  /// Devuelve `null` si no hay sesiones previas. Si la más reciente no tiene
  /// marca de cierre, [RecoveredSession.endedCleanly] viene `false`: la app
  /// murió y ese journal es la evidencia del crash.
  static Future<RecoveredSession?> recoverPrevious(
    Directory directory, {
    String? excludeSessionId,
  }) async {
    final files = await _listSessionFiles(directory);
    files.sort((a, b) => b.path.compareTo(a.path)); // recientes primero
    for (final file in files) {
      if (excludeSessionId != null &&
          p.basename(file.path) ==
              '$_sessionPrefix$excludeSessionId$_sessionSuffix') {
        continue;
      }
      final recovered = await _parse(file);
      if (recovered != null) return recovered;
    }
    return null;
  }

  /// Lee un journal concreto (`null` si no se puede leer o no tiene
  /// cabecera de sesión).
  static Future<RecoveredSession?> read(File file) => _parse(file);

  static Future<RecoveredSession?> _parse(File file) async {
    final List<String> lines;
    try {
      lines = await file.readAsLines();
    } on FileSystemException {
      return null;
    }
    ThorSession? session;
    final events = <ThorEvent>[];
    var ended = false;
    String? reason;
    int? bg;
    var corrupt = 0;
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line) as Map<String, Object?>;
        switch (json['type']) {
          case 'session':
            session = ThorSession.fromJson(json);
          case 'event':
            events.add(ThorEvent.fromJson(json));
          case 'end':
            ended = true;
            reason = json['reason'] as String?;
            bg = json['backgroundMs'] as int?;
        }
      } on Object {
        // Línea a medio escribir (crash durante flush) o corrupta: se cuenta
        // y se sigue — perder una línea no debe perder la sesión entera.
        corrupt++;
      }
    }
    if (session == null) return null;
    return RecoveredSession(
      session: session,
      events: events,
      endedCleanly: ended,
      corruptLines: corrupt,
      closeReason: reason,
      closeBackgroundMs: bg,
    );
  }
}
