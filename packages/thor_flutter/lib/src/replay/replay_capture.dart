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
    this.snapshotBudget = const Duration(milliseconds: 8),
    this.apiKey,
  });

  /// Enmascara todo el texto (default). Apagar solo en entornos propios.
  final bool maskText;

  /// Manda la URL de cada imagen. Apagado: la imagen es un rectángulo.
  final bool imageUrls;

  /// URL de ingesta (`POST`, cuerpo gzip NDJSON). `null` = solo disco.
  final Uri? endpoint;

  /// Llave de la app para la ingesta (header `x-thor-key`). El servidor
  /// rechaza sin ella (401) salvo en desarrollo.
  final String? apiKey;

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

  /// Tiempo máximo razonable de un snapshot (recorrido + bloques + hash)
  /// en el hilo de UI. Si se pasa varias veces seguidas, el replay espacia
  /// los snapshots ([idle] y [maxGap] ×2, hasta ×8) en vez de cobrarle
  /// frames a la app. Medido en debug (pesimista) con ~9000 elementos
  /// montados: ~0.4 ms el recorrido, ~0.2 ms bloques + hash.
  final Duration snapshotBudget;
}

/// Costo del replay en el dispositivo, para depurar y para el servidor
/// (viaja como `{"t":"stats",…}` al subir o irse a segundo plano).
class ThorReplayStats {
  ThorReplayStats._(this._json);

  final Map<String, Object?> _json;

  /// `{"snap":{"n","p50","p95","max"},"ops":{"avg","max"},`
  /// `"blk":{"avg","max"},"bo":{"n","x"}}` — ms con un decimal; `bo` =
  /// veces que se espació por exceder el presupuesto y factor actual.
  Map<String, Object?> toJson() => _json;

  @override
  String toString() => jsonEncode(_json);
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
/// - `{"t":"user","ts":…,"id":…}` — usuario fijado/cambiado con
///   `Thor.setUser` (`id: null` = se limpió). Si ya se conocía al
///   arrancar, también va como `uid` en el meta.
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

  // ── Costo en el dispositivo ──
  //
  // El snapshot corre en el hilo de UI: nunca se había medido. Se guardan
  // las últimas 256 duraciones (p50/p95 de lo reciente, memoria fija) y
  // contadores de toda la sesión.
  final Stopwatch _snapWatch = Stopwatch();
  final List<int> _snapUs = [];
  int _snapN = 0;
  int _snapMaxUs = 0;
  int _opsSum = 0;
  int _opsMax = 0;
  int _blkSum = 0;
  int _blkMax = 0;
  int _statsAtN = 0;

  /// Snapshots seguidos sobre / bajo el presupuesto.
  int _overBudget = 0;
  int _underBudget = 0;

  /// Factor sobre idle/maxGap (1, 2, 4, 8) y cuántas veces se subió.
  int _backoff = 1;
  int _backoffs = 0;

  /// Costo medido hasta ahora (para depurar: `ThorReplay.instance?.stats`).
  ThorReplayStats get stats => ThorReplayStats._(_statsJson());

  Map<String, Object?> _statsJson() {
    double ms(int us) => (us / 100).round() / 10;
    final sorted = [..._snapUs]..sort();
    int pct(double p) =>
        sorted.isEmpty ? 0 : sorted[((sorted.length - 1) * p).round()];
    final n = _snapN == 0 ? 1 : _snapN;
    return {
      'snap': {
        'n': _snapN,
        'p50': ms(pct(.5)),
        'p95': ms(pct(.95)),
        'max': ms(_snapMaxUs),
      },
      'ops': {'avg': (_opsSum / n).round(), 'max': _opsMax},
      'blk': {'avg': (_blkSum / n).round(), 'max': _blkMax},
      'bo': {'n': _backoffs, 'x': _backoff},
    };
  }

  void _recordCost(int us, int ops, int blocks) {
    if (_snapUs.length == 256) _snapUs.removeAt(0);
    _snapUs.add(us);
    _snapN++;
    _snapMaxUs = max(_snapMaxUs, us);
    _opsSum += ops;
    _opsMax = max(_opsMax, ops);
    _blkSum += blocks;
    _blkMax = max(_blkMax, blocks);
    // Un snapshot lento aislado (GC, primera compilación) no cuenta: solo
    // 3 seguidos espacian. Si la pantalla vuelve a ser ligera (10 seguidos
    // bajo la mitad del presupuesto) se recupera un paso: un catálogo
    // pesado no debe degradar el replay del resto de la sesión.
    final budget = _config.snapshotBudget.inMicroseconds;
    if (us > budget) {
      _underBudget = 0;
      if (++_overBudget >= 3 && _backoff < 8) {
        _backoff *= 2;
        _backoffs++;
        _overBudget = 0;
      }
    } else {
      _overBudget = 0;
      if (us < budget ~/ 2 && ++_underBudget >= 10 && _backoff > 1) {
        _backoff ~/= 2;
        _underBudget = 0;
      }
    }
  }

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
      unawaited(_recover(directory, config.endpoint!, config.apiKey, file!));
    }
  }

  /// Sesiones anteriores que quedaron en disco: las que debían subir (en la
  /// muestra o con error — marca `.on`) suben lo que les faltó; las demás
  /// se borran. Una sesión que terminó en crash es la que más importa.
  @visibleForTesting
  static Future<void> recover(
    Directory dir,
    Uri endpoint,
    File current, {
    String? apiKey,
  }) =>
      _recover(dir, endpoint, apiKey, current);

  static Future<void> _recover(
    Directory dir,
    Uri endpoint,
    String? apiKey,
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
          if (rest.isNotEmpty) {
            final up = await _upload(
              http,
              endpoint,
              apiKey,
              sessionId,
              rest,
              blocks,
            );
            // Sin red o servidor ocupado: se intenta en el siguiente
            // arranque. Rechazada (llave, tamaño): reintentar no sirve.
            if (up.sent is _Later) continue;
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
  static Future<({_Sent sent, List<String> unsentBlocks})> _upload(
    HttpClient http,
    Uri endpoint,
    String? apiKey,
    String sessionId,
    List<String> records,
    Map<String, String> blocks,
  ) async {
    final first = await _post(http, endpoint, apiKey, sessionId, records);
    const none = <String>[];
    if (first.sent is! _Ok) return (sent: first.sent, unsentBlocks: none);
    final lines = [
      for (final h in first.missing)
        if (blocks[h] case final line?) line,
    ];
    if (lines.isEmpty) return (sent: first.sent, unsentBlocks: none);
    final second = await _post(http, endpoint, apiKey, sessionId, lines);
    final bytes = (first.sent as _Ok).bytes;
    return switch (second.sent) {
      _Ok(bytes: final more) => (
          sent: _Ok(bytes + more),
          unsentBlocks: const <String>[]
        ),
      // Los registros ya llegaron: los bloques que faltan viajan después.
      _ => (sent: _Ok(bytes), unsentBlocks: lines),
    };
  }

  /// Un POST gzip NDJSON: qué pasó y qué bloques pide el servidor.
  static Future<({_Sent sent, List<String> missing})> _post(
    HttpClient http,
    Uri endpoint,
    String? apiKey,
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
      if (apiKey != null) req.headers.set('x-thor-key', apiKey);
      req.add(body);
      final res = await req.close();
      final text = await res.transform(utf8.decoder).join();
      final code = res.statusCode;
      if (code == 429) {
        final after = int.tryParse(res.headers.value('retry-after') ?? '');
        return (
          sent: _Later(after == null ? null : Duration(seconds: after)),
          missing: const <String>[],
        );
      }
      // Llave inválida, sesión de otra app o lote demasiado grande:
      // reintentar igual no cambia nada.
      if (code == 401 || code == 403 || code == 413) {
        return (sent: _Rejected(code), missing: const <String>[]);
      }
      if (code >= 300) return (sent: _Later(null), missing: const <String>[]);
      final json = jsonDecode(text);
      return (
        sent: _Ok(body.length),
        missing: json is Map && json['missing'] is List
            ? (json['missing'] as List).cast<String>()
            : const <String>[],
      );
    } on Object {
      return (sent: _Later(null), missing: const <String>[]);
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
  int? _retryAt;

  /// Quita la marca `.on`: una sesión rechazada no se reintenta al
  /// siguiente arranque.
  void _unmarkEnabled() {
    final file = _file;
    if (file == null) return;
    final base = file.path.substring(0, file.path.length - '.jsonl'.length);
    final on = File('$base.on');
    if (on.existsSync()) unawaited(on.delete().catchError((_) => on));
  }

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
      if (_core.userId != null) 'uid': _core.userId,
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
    if (_ts - _lastSnapAt > _config.maxGap.inMilliseconds * _backoff) {
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
    _idleTimer = Timer(_config.idle * _backoff, _snapshot);
  }

  void _snapshot() {
    _lastSnapAt = _ts;
    final Wireframe? wire;
    final List<List<Object?>> vps;
    final List<List<Object?>> refs;
    final Map<String, String> blocks;
    final String hash;
    _snapWatch
      ..reset()
      ..start();
    try {
      wire = WireframeBuilder(
        maskText: _config.maskText,
        imageUrls: _config.imageUrls,
      ).build();
      if (wire == null) return;
      (:vps, :refs, :blocks) = split(wire.ops);
      hash = fnv(jsonEncode([vps, refs]));
    } on Object {
      return;
    }
    _snapWatch.stop();
    _recordCost(_snapWatch.elapsedMicroseconds, wire.ops.length, refs.length);
    _viewports = wire.viewports;
    for (final MapEntry(:key, :value) in wire.offsets.entries) {
      _lastOffsets[key] = value;
    }
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
  @visibleForTesting
  static ({
    List<List<Object?>> vps,
    List<List<Object?>> refs,
    Map<String, String> blocks,
  }) split(List<List<Object?>> ops) {
    final vps = <List<Object?>>[];
    final refs = <List<Object?>>[];
    final blocks = <String, String>{};
    // Cada op se codifica UNA vez, sin su posición: `"r",w,h,…`. De ahí
    // salen tanto el corte (su hash) como el cuerpo del bloque (se le
    // inserta la posición relativa). Antes eran dos jsonEncode por op. El
    // texto resultante es idéntico al de jsonEncode — los hashes no
    // cambian (lo comprueba replay_cost_test contra la versión original).
    final current = <List<Object?>>[];
    final tails = <String>[];
    int? vp;

    void close() {
      if (current.isEmpty) return;
      final first = current.first;
      final ox = first[1]! as num;
      final oy = first[2]! as num;
      final body = StringBuffer('[');
      for (var i = 0; i < current.length; i++) {
        final op = current[i];
        if (i > 0) body.write(',');
        body
          ..write('[')
          ..write(jsonEncode(op[0]))
          ..write(',')
          ..write(_json(_sub(op[1]! as num, ox)))
          ..write(',')
          ..write(_json(_sub(op[2]! as num, oy)))
          ..write(',')
          ..write(tails[i])
          ..write(']');
      }
      body.write(']');
      final text = body.toString();
      final hash = fnv(text);
      blocks[hash] = '["blk","$hash",$text]';
      refs.add([hash, vp, ox, oy]);
      current.clear();
      tails.clear();
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
      // `[w,h,…resto]` sin corchetes.
      final encoded = jsonEncode([op[3], op[4], ...op.skip(6)]);
      final tail = encoded.substring(1, encoded.length - 1);
      current.add(op);
      tails.add(tail);
      if (current.length >= 4 && _isBoundary(op[0]! as String, tail)) close();
    }
    close();
    return (vps: vps, refs: refs, blocks: blocks);
  }

  /// Dónde cortar se decide SIN la posición del op: si un banner de otra
  /// altura empuja la pantalla unos píxeles, el contenido igual debe caer
  /// en los mismos bloques. (Medido en producción: cortar con la posición
  /// hacía nuevos 138 bloques de la 2ª sesión; sin ella, 55.)
  /// Equivale a `fnv32(jsonEncode([kind, w, h, ...resto])) % 32 == 0`.
  static bool _isBoundary(String kind, String tail) =>
      fnv32('[${jsonEncode(kind)},$tail]') % 32 == 0;

  /// Un número como lo escribe jsonEncode. NaN/infinito lanzan igual que
  /// jsonEncode: el snapshot se descarta en vez de mandar JSON inválido.
  static String _json(num n) {
    if (!n.isFinite) throw ArgumentError.value(n, 'n', 'no finito');
    return n.toString();
  }

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
    // Identidad: registro propio (no `ev`) para que el servidor indexe
    // "sesiones del usuario X" sin parsear eventos. Solo el id: los traits
    // se quedan en el journal.
    if (event.kind == ThorEventKind.environment && p['signal'] == 'user') {
      _writeJson({'t': 'user', 'ts': _ts, 'id': p['id']});
      return;
    }
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
    // El costo viaja con cada subida / ida a segundo plano (solo si hubo
    // snapshots nuevos): una línea, ~120 bytes.
    if (upload && _snapN > _statsAtN) {
      _statsAtN = _snapN;
      _writeJson({'t': 'stats', ..._statsJson()});
    }
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
    // 429: el servidor pidió esperar.
    if (_retryAt case final at? when _ts < at) return;
    _uploading = true;
    _lastUploadAt = _ts;
    try {
      final endpoint = _config.endpoint!;
      final records = List<String>.of(_pendingUpload);
      final up = await _upload(
        _http ??= HttpClient(),
        endpoint,
        _config.apiKey,
        _core.session.sessionId,
        records,
        _blocks,
      );
      switch (up.sent) {
        case _Ok(:final bytes):
          uploadedBytes += bytes;
          _pendingUpload
            ..removeRange(0, records.length)
            ..insertAll(0, up.unsentBlocks);
          _sentRecords += records.length;
          _saveSent();
        case _Later(:final after):
          if (after != null) _retryAt = _ts + after.inMilliseconds;
        case _Rejected(:final status):
          if (status == 413) {
            // Solo este lote: el resto de la sesión puede caber.
            _pendingUpload.removeRange(0, records.length);
          } else {
            // Llave o sesión rechazadas: esta sesión ya no sube.
            _uploadEnabled = false;
            _pendingUpload.clear();
            _unmarkEnabled();
          }
      }
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
  static String fnv(String s) {
    // Las dos pasadas en un solo recorrido del String (mismo resultado que
    // dos fnv32): los bloques se hashean en cada snapshot.
    var a = 0x811c9dc5;
    var b = 0x9747b28c;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      a = ((a ^ c) * 0x01000193) & 0xFFFFFFFF;
      b = ((b ^ c) * 0x5bd1e995) & 0xFFFFFFFF;
    }
    return a.toRadixString(16).padLeft(8, '0') +
        b.toRadixString(16).padLeft(8, '0');
  }
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

/// Resultado de una subida.
sealed class _Sent {}

/// Llegó: [bytes] gzip enviados.
final class _Ok extends _Sent {
  _Ok(this.bytes);
  final int bytes;
}

/// Sin red, error del servidor o 429: se reintenta (tras [after] si vino).
final class _Later extends _Sent {
  _Later(this.after);
  final Duration? after;
}

/// 401/403/413: reintentar igual no sirve.
final class _Rejected extends _Sent {
  _Rejected(this.status);
  final int status;
}
