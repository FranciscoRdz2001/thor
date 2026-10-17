import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/replay/wireframe.dart';

/// Configuración del replay de sesión.
class ThorReplayConfig {
  /// Crea la configuración.
  const ThorReplayConfig({
    this.maskText = true,
    this.imageUrls = false,
    this.endpoint,
    this.sampleRate = 1,
    this.uploadOnError = true,
    this.uploadEvery = const Duration(minutes: 5),
    this.saveEvery = const Duration(seconds: 5),
    this.idle = const Duration(milliseconds: 250),
    this.maxGap = const Duration(milliseconds: 1200),
  });

  /// Enmascara todo el texto (default). Apagar solo en entornos propios.
  final bool maskText;

  /// Manda la URL de cada imagen. Apagado: la imagen es un rectángulo.
  final bool imageUrls;

  /// URL de ingesta (`POST`, cuerpo gzip NDJSON). `null` = solo disco.
  final Uri? endpoint;

  /// Fracción de sesiones que se suben siempre (0–1). El resto se graba
  /// en disco y solo se sube si pasa algo ([uploadOnError]).
  final double sampleRate;

  /// Una sesión fuera de la muestra se sube COMPLETA (desde el inicio) en
  /// cuanto hay un error o una petición fallida: el replay de las sesiones
  /// que fallan es el que importa.
  final bool uploadOnError;

  /// Respaldo periódico de subida. Lo normal es subir UNA vez, al irse la
  /// app a segundo plano (o al primer error): un lote grande comprime
  /// mucho mejor (medido en producción, 4.4 min: lotes de 5 s = 60 KB,
  /// de 60 s = 35 KB, uno solo ≈ 20 KB). Lo que no alcanzó a subir (crash,
  /// app matada) se sube en el siguiente arranque.
  final Duration uploadEvery;

  /// Cada cuánto se escribe a disco (lo que sobrevive a un crash).
  final Duration saveEvery;

  /// Quietud tras el último frame para tomar el snapshot.
  final Duration idle;

  /// Con animación continua (shimmer, carrusel) igual se captura cada
  /// [maxGap]; el hash evita mandar lo repetido.
  final Duration maxGap;
}

/// Replay de sesión tipo "reconstrucción": en vez de video se graba lo
/// mínimo para REDIBUJAR la interfaz y lo que el usuario hizo encima.
///
/// Formato v2 — una línea por registro; los frecuentes son arreglos:
/// - `{"t":"meta",…}` — sesión, tamaño de pantalla.
/// - `["st", ts, hash, offs, vps, refs]` — estado de pantalla nuevo:
///   viewports `[id, padre, x, y, w, h, eje]` y referencias a bloques
///   `[hashBloque, vp, ox, oy]`.
/// - `["ref", ts, hash, offs]` — estado ya visto en la sesión.
/// - `["blk", hash, ops]` — contenido de un bloque, en coordenadas
///   relativas a su primera primitiva. **Solo viaja si el servidor no lo
///   tiene** (de esta u otra sesión, de este u otro dispositivo).
/// - `["sc", ts, vp, offset]` — scroll (~10 Hz mientras se mueve).
/// - `["p", ts, "d"|"m"|"u", x, y]` — dedo.
/// - `{"t":"ev",…}` — evento de Thor en versión ligera.
///
/// Subida en dos fases: se mandan los registros sin bloques; el servidor
/// contesta `{"missing": [...]}` y solo esos bloques se mandan después.
/// Una pantalla vista por mil usuarios se sube una vez.
class ThorReplay {
  ThorReplay._(this._config, this._core, this._file, this._uploadEnabled);

  static ThorReplay? _instance;

  /// Instancia activa, si el replay está encendido.
  static ThorReplay? get instance => _instance;

  final ThorReplayConfig _config;
  final ThorCore _core;
  final File? _file;

  /// Si esta sesión sube (muestra o ya hubo un error).
  bool _uploadEnabled;

  final Stopwatch _clock = Stopwatch();
  final List<String> _pendingDisk = [];

  /// Registros aún no confirmados por el servidor (sin bloques).
  final List<String> _pendingUpload = [];

  /// Todos los bloques de la sesión (hash → línea), para contestar los
  /// `missing` del servidor sin releer el disco.
  final Map<String, String> _blocks = {};
  final Set<String> _sentStates = {};
  final Map<String, int> _burst = {};
  final Map<int, double> _lastOffsets = {};
  final Map<int, int> _lastOffsetAt = {};

  String? _prevHash;
  List<WireViewport> _viewports = const [];
  Timer? _idleTimer;
  Timer? _flushTimer;
  int _lastSnapAt = -1 << 30;
  int _lastMoveAt = 0;
  bool _pointerDown = false;
  void Function()? _unsubscribe;
  HttpClient? _http;
  bool _uploading = false;

  /// Bytes gzip enviados al servidor en esta sesión.
  int uploadedBytes = 0;

  /// Enciende el replay. Requiere Thor inicializado.
  static Future<void> start(
    ThorReplayConfig config, {
    Directory? directory,
  }) async {
    final core = ThorCore.instance;
    if (core == null || _instance != null) return;
    File? file;
    if (directory != null) {
      await directory.create(recursive: true);
      file = File('${directory.path}/replay-${core.session.sessionId}.jsonl');
    }
    // La subida del replay no es tráfico de la app.
    if (config.endpoint case final endpoint?) {
      ThorNetworkCapture.ignoredPrefixes.add(endpoint.toString());
    }
    final sampled = Random().nextDouble() < config.sampleRate;
    final replay =
        _instance = ThorReplay._(config, core, file, sampled).._install();
    if (sampled) replay._markEnabled();
    if (directory != null && config.endpoint != null) {
      unawaited(_recover(directory, config.endpoint!, file!));
    }
  }

  /// Sesiones anteriores que quedaron en disco: las que debían subir (en la
  /// muestra o con error — marca `.on`) suben lo que les faltó; las demás
  /// se borran. Una sesión que terminó en crash es la que más importa.
  @visibleForTesting
  static Future<void> recover(Directory dir, Uri endpoint, File current) =>
      _recover(dir, endpoint, current);

  static Future<void> _recover(
    Directory dir,
    Uri endpoint,
    File current,
  ) async {
    try {
      final http = HttpClient();
      await for (final entity in dir.list()) {
        final path = entity.path;
        if (entity is! File ||
            !path.endsWith('.jsonl') ||
            !path.split('/').last.startsWith('replay-') ||
            path == current.path) {
          continue;
        }
        final base = path.substring(0, path.length - '.jsonl'.length);
        final on = File('$base.on');
        final sent = File('$base.sent');
        if (on.existsSync()) {
          final sessionId = base.split('/').last.substring('replay-'.length);
          final skip = sent.existsSync()
              ? int.tryParse(sent.readAsStringSync()) ?? 0
              : 0;
          final blocks = <String, String>{};
          final records = <String>[];
          for (final line in await entity.readAsLines()) {
            if (line.startsWith('["blk","')) {
              blocks[line.substring(8, 24)] = line;
            } else if (line.isNotEmpty) {
              records.add(line);
            }
          }
          final rest = records.skip(skip).toList();
          if (rest.isNotEmpty &&
              await _upload(http, endpoint, sessionId, rest, blocks) == null) {
            continue; // Sin red: se intenta en el siguiente arranque.
          }
        }
        for (final f in [entity, on, sent]) {
          if (f.existsSync()) await f.delete();
        }
      }
      http.close();
    } on Object {
      // La recuperación jamás debe afectar a la app.
    }
  }

  /// Sube [records] y luego los bloques que el servidor pida. Devuelve los
  /// bytes enviados, o `null` si los registros no llegaron.
  static Future<int?> _upload(
    HttpClient http,
    Uri endpoint,
    String sessionId,
    List<String> records,
    Map<String, String> blocks,
  ) async {
    final first = await _post(http, endpoint, sessionId, records);
    if (first == null) return null;
    final (sentBytes, missing) = first;
    final lines = [
      for (final h in missing)
        if (blocks[h] case final line?) line,
    ];
    if (lines.isEmpty) return sentBytes;
    final second = await _post(http, endpoint, sessionId, lines);
    return sentBytes + (second?.$1 ?? 0);
  }

  /// Un POST gzip NDJSON: (bytes enviados, bloques que faltan) o `null`.
  static Future<(int, List<String>)?> _post(
    HttpClient http,
    Uri endpoint,
    String sessionId,
    List<String> lines,
  ) async {
    try {
      final body = gzip.encode(utf8.encode(lines.join('\n')));
      final req = await http.postUrl(endpoint);
      req.headers
        ..set('content-type', 'application/x-ndjson')
        ..set('content-encoding', 'gzip')
        ..set('x-thor-session', sessionId);
      req.add(body);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 300) return null;
      final json = jsonDecode(text);
      return (
        body.length,
        json is Map && json['missing'] is List
            ? (json['missing'] as List).cast<String>()
            : const <String>[],
      );
    } on Object {
      return null;
    }
  }

  /// Marca en disco que esta sesión sube (para recuperarla si muere).
  void _markEnabled() {
    final file = _file;
    if (file == null) return;
    final base = file.path.substring(0, file.path.length - '.jsonl'.length);
    unawaited(File('$base.on').writeAsString('1').catchError((_) => File('')));
  }

  int _sentRecords = 0;

  void _saveSent() {
    final file = _file;
    if (file == null) return;
    final base = file.path.substring(0, file.path.length - '.jsonl'.length);
    unawaited(
      File('$base.sent').writeAsString('$_sentRecords').catchError(
            (_) => File(''),
          ),
    );
  }

  int get _ts => _clock.elapsedMilliseconds;

  void _install() {
    _clock.start();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    _writeJson({
      't': 'meta',
      'v': 2,
      'sid': _core.session.sessionId,
      'iid': _core.session.installId,
      'at': DateTime.now().toUtc().toIso8601String(),
      'w': size.width,
      'h': size.height,
      'dpr': view.devicePixelRatio,
      'app': _core.session.appInfo,
    });
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _unsubscribe = _core.recorder.addListener(_onEvent);
    _flushTimer = Timer.periodic(_config.saveEvery, (_) {
      final due = _ts - _lastUploadAt >= _config.uploadEvery.inMilliseconds;
      unawaited(flush(upload: due));
    });
    WidgetsBinding.instance.addObserver(_lifecycle);
    _scheduleSnapshot();
  }

  // ── Disparadores ──

  void _onFrame(Duration _) {
    // El callback persistente no se puede quitar: tras stop() queda inerte.
    if (_instance != this) return;
    _sampleScroll();
    _scheduleSnapshot();
  }

  void _scheduleSnapshot() {
    _idleTimer?.cancel();
    // Animación continua: no esperar quietud eterna.
    if (_ts - _lastSnapAt > _config.maxGap.inMilliseconds) {
      final scheduler = SchedulerBinding.instance;
      // Con un frame en camino se espera a que pinte; con la UI quieta no
      // llega ninguno y el snapshot se perdería.
      if (scheduler.hasScheduledFrame) {
        scheduler.addPostFrameCallback((_) => _snapshot());
      } else {
        _idleTimer = Timer(Duration.zero, _snapshot);
      }
      return;
    }
    _idleTimer = Timer(_config.idle, _snapshot);
  }

  void _snapshot() {
    _lastSnapAt = _ts;
    final Wireframe? wire;
    try {
      wire = WireframeBuilder(
        maskText: _config.maskText,
        imageUrls: _config.imageUrls,
      ).build();
    } on Object {
      return;
    }
    if (wire == null) return;
    _viewports = wire.viewports;
    for (final MapEntry(:key, :value) in wire.offsets.entries) {
      _lastOffsets[key] = value;
    }
    final (:vps, :refs, :blocks) = _split(wire.ops);
    final hash = fnv(jsonEncode([vps, refs]));
    if (hash == _prevHash) return;
    _prevHash = hash;
    final offs = {
      for (final MapEntry(:key, :value) in wire.offsets.entries)
        '$key': _round(value),
    };
    if (!_sentStates.add(hash)) {
      _write(['ref', _ts, hash, offs]);
      return;
    }
    for (final MapEntry(:key, :value) in blocks.entries) {
      _blocks.putIfAbsent(key, () => value);
    }
    _write(['st', _ts, hash, offs, vps, refs]);
  }

  /// Parte el wireframe en bloques direccionados por contenido.
  ///
  /// Un bloque nunca cruza de viewport y se corta además donde el hash de
  /// una primitiva cae en 1/32 (content-defined chunking): insertar un
  /// item en una lista solo cambia los bloques de alrededor. Las
  /// coordenadas van relativas a la primera primitiva del bloque, así el
  /// mismo componente en otra posición (u otra sesión) es el mismo bloque.
  ({
    List<List<Object?>> vps,
    List<List<Object?>> refs,
    Map<String, String> blocks,
  }) _split(List<List<Object?>> ops) {
    final vps = <List<Object?>>[];
    final refs = <List<Object?>>[];
    final blocks = <String, String>{};
    var current = <List<Object?>>[];
    int? vp;

    void close() {
      if (current.isEmpty) return;
      final first = current.first;
      final ox = first[1]! as num;
      final oy = first[2]! as num;
      final rel = [
        for (final op in current)
          [
            op[0],
            _sub(op[1]! as num, ox),
            _sub(op[2]! as num, oy),
            op[3],
            op[4],
            ...op.skip(6),
          ],
      ];
      final body = jsonEncode(rel);
      final hash = fnv(body);
      blocks[hash] = '["blk","$hash",$body]';
      refs.add([hash, vp, ox, oy]);
      current = [];
    }

    for (final op in ops) {
      if (op[0] == 'v') {
        // ['v', x, y, w, h, padre, id, eje] → [id, padre, x, y, w, h, eje]
        vps.add([op[6], op[5], op[1], op[2], op[3], op[4], op[7]]);
        continue;
      }
      final opVp = op[5]! as int;
      if (opVp != vp) {
        close();
        vp = opVp;
      }
      current.add(op);
      if (current.length >= 4 && _isBoundary(op)) close();
    }
    close();
    return (vps: vps, refs: refs, blocks: blocks);
  }

  /// Dónde cortar se decide SIN la posición del op: si un banner de otra
  /// altura empuja la pantalla unos píxeles, el contenido igual debe caer
  /// en los mismos bloques. (Medido en producción: cortar con la posición
  /// hacía nuevos 138 bloques de la 2ª sesión; sin ella, 55.)
  static bool _isBoundary(List<Object?> op) =>
      fnv32(jsonEncode([op[0], op[3], op[4], ...op.skip(6)])) % 32 == 0;

  static num _sub(num a, num b) {
    final d = ((a - b) * 2).round();
    return d.isEven ? d ~/ 2 : d / 2;
  }

  void _sampleScroll() {
    final now = _ts;
    for (final vp in _viewports) {
      final px = vp.pixels;
      if (px == null) continue;
      final last = _lastOffsets[vp.id];
      if (last != null && (px - last).abs() < 1) continue;
      if (now - (_lastOffsetAt[vp.id] ?? -1000) < 100) continue;
      _lastOffsets[vp.id] = px;
      _lastOffsetAt[vp.id] = now;
      _write(['sc', now, vp.id, _round(px)]);
    }
  }

  void _onPointer(PointerEvent e) {
    final x = _round(e.position.dx);
    final y = _round(e.position.dy);
    if (e is PointerDownEvent) {
      _pointerDown = true;
      _write(['p', _ts, 'd', x, y]);
    } else if (e is PointerMoveEvent && _pointerDown) {
      if (_ts - _lastMoveAt < 50) return;
      _lastMoveAt = _ts;
      _write(['p', _ts, 'm', x, y]);
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      _pointerDown = false;
      _write(['p', _ts, 'u', x, y]);
    }
  }

  // ── Eventos de Thor en versión ligera ──

  void _onEvent(ThorEvent event) {
    final p = event.payload;
    final slim = switch (event.kind) {
      ThorEventKind.navigation => {'a': p['action'], 'to': p['to']},
      ThorEventKind.interaction => {
          'g': p['gesture'],
          'l': p['label'],
          'w': p['widget'],
        },
      ThorEventKind.error => {
          'type': p['type'],
          'msg': p['message'],
          'src': p['source'],
          'at': event.origin,
        },
      ThorEventKind.network => _slimNetwork(p, event.origin),
      ThorEventKind.state => _slimState(p),
      ThorEventKind.log => {'l': p['label']},
      _ => null,
    };
    if (slim == null) return;
    _writeJson({
      't': 'ev',
      'ts': _ts,
      'k': event.kind.name,
      if (event.screen != null) 'sc': event.screen!.display,
      'p': slim,
    });
    // Una sesión con fallo se sube entera aunque no estuviera en la
    // muestra: es justo la que hay que depurar.
    final failed = event.kind == ThorEventKind.error ||
        (event.kind == ThorEventKind.network && slim.containsKey('err'));
    if (failed && _config.uploadOnError && !_uploadEnabled) {
      _uploadEnabled = true;
      _markEnabled();
      unawaited(flush());
    }
  }

  static final _staticAsset = RegExp(
    r'(assets|img|cdn)[^/]*\.|\.(png|jpe?g|webp|svg|gif|woff2?)(\?|$)',
  );

  /// Red: las exitosas solo con lo esencial; las fallidas conservan el
  /// cuerpo de respuesta (ya redactado) y el origen en código.
  Map<String, Object?>? _slimNetwork(Map<String, Object?> p, String? at) {
    final url = (p['url'] as String?) ?? '';
    if (_staticAsset.hasMatch(url)) return null;
    final status = p['statusCode'] as int?;
    final failed = status == null || status >= 400 || p['error'] != null;
    return {
      'm': p['method'],
      'u': url.split('?').first,
      's': status,
      'd': p['durationMs'],
      if (failed) ...{
        'err': p['errorMessage'] ?? 'HTTP $status',
        'body': p['responseBody'],
        'at': at,
      },
    };
  }

  /// Estado: solo transiciones, y máximo 2 por segundo por bloc — un bloc
  /// que recibe cada scroll como evento no debe ahogar la línea.
  Map<String, Object?>? _slimState(Map<String, Object?> p) {
    if (p['action'] != 'change') return null;
    final key = '${p['bloc']}@${_ts ~/ 1000}';
    final n = _burst[key] = (_burst[key] ?? 0) + 1;
    if (_burst.length > 512) _burst.clear();
    if (n > 2) return null;
    return {'b': p['bloc'], 'to': p['to']};
  }

  // ── Escritura y subida ──

  void _writeJson(Map<String, Object?> record) => _line(jsonEncode(record));

  void _write(List<Object?> record) => _line(jsonEncode(record));

  void _line(String line) {
    _pendingDisk.add(line);
    if (_config.endpoint != null) _pendingUpload.add(line);
  }

  late final _lifecycle = _ReplayLifecycle(this);
  int _lastUploadAt = 0;

  /// Escribe lo pendiente a disco (registros y bloques nuevos) y, si la
  /// sesión sube y [upload], manda el lote. Un fallo de red lo deja para
  /// después.
  Future<void> flush({bool upload = true}) async {
    final file = _file;
    if (file != null &&
        (_pendingDisk.isNotEmpty || _unsavedBlocks.isNotEmpty)) {
      final lines = [
        ..._unsavedBlocks.map((h) => _blocks[h]!),
        ..._pendingDisk,
      ];
      _savedBlocks.addAll(_unsavedBlocks);
      _pendingDisk.clear();
      await file.writeAsString(
        '${lines.join('\n')}\n',
        mode: FileMode.append,
        flush: true,
      );
    } else {
      _pendingDisk.clear();
    }
    if (!upload || !_uploadEnabled || _pendingUpload.isEmpty || _uploading) {
      return;
    }
    _uploading = true;
    _lastUploadAt = _ts;
    try {
      final endpoint = _config.endpoint!;
      final records = List<String>.of(_pendingUpload);
      final sent = await _upload(
        _http ??= HttpClient(),
        endpoint,
        _core.session.sessionId,
        records,
        _blocks,
      );
      if (sent == null) return;
      uploadedBytes += sent;
      _pendingUpload.removeRange(0, records.length);
      _sentRecords += records.length;
      _saveSent();
    } finally {
      _uploading = false;
    }
  }

  final Set<String> _savedBlocks = {};
  Iterable<String> get _unsavedBlocks =>
      _blocks.keys.where((h) => !_savedBlocks.contains(h)).toList();

  /// Apaga el replay (tests / logout).
  static Future<void> stop() async {
    final r = _instance;
    if (r == null) return;
    _instance = null;
    r._idleTimer?.cancel();
    r._flushTimer?.cancel();
    r._unsubscribe?.call();
    WidgetsBinding.instance.removeObserver(r._lifecycle);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(r._onPointer);
    await r.flush();
  }

  static num _round(double v) => (v * 10).round() / 10;

  /// FNV-1a de 32 bits (enteros acotados: igual en VM y en web).
  @visibleForTesting
  static int fnv32(String s, [int seed = 0x811c9dc5, int prime = 0x01000193]) {
    var h = seed;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * prime) & 0xFFFFFFFF;
    }
    return h;
  }

  /// Dos FNV-1a de 32 bits (semilla y primo distintos) → 16 hex.
  @visibleForTesting
  static String fnv(String s) =>
      fnv32(s).toRadixString(16).padLeft(8, '0') +
      fnv32(s, 0x9747b28c, 0x5bd1e995).toRadixString(16).padLeft(8, '0');
}

/// Sube lo pendiente cuando la app se va a segundo plano: el sistema puede
/// matarla ahí sin aviso.
class _ReplayLifecycle with WidgetsBindingObserver {
  _ReplayLifecycle(this.replay);

  final ThorReplay replay;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(replay.flush());
    }
  }
}
