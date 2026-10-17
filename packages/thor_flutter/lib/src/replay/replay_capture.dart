import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    this.endpoint,
    this.uploadEvery = const Duration(seconds: 5),
    this.idle = const Duration(milliseconds: 250),
    this.maxGap = const Duration(milliseconds: 1200),
  });

  /// Enmascara todo el texto (default). Apagar solo en entornos propios.
  final bool maskText;

  /// URL de ingesta (`POST`, cuerpo gzip JSONL). `null` = solo disco.
  final Uri? endpoint;

  /// Cada cuánto se sube el lote pendiente.
  final Duration uploadEvery;

  /// Quietud tras el último frame para tomar el snapshot.
  final Duration idle;

  /// Con animación continua (shimmer, carrusel) igual se captura cada
  /// [maxGap]; el hash evita mandar lo repetido.
  final Duration maxGap;
}

/// Replay de sesión tipo "reconstrucción": en vez de video se graba lo
/// mínimo para REDIBUJAR la interfaz y lo que el usuario hizo encima.
///
/// Registros (una línea JSON cada uno, `ts` = ms desde el inicio):
/// - `meta`  — sesión, tamaño de pantalla.
/// - `snap`  — wireframe completo + hash (primera vez que se ve un estado).
/// - `ref`   — estado ya enviado antes: solo su hash.
/// - `delta` — estado nuevo como parches sobre el anterior.
/// - `sc`    — offset de un viewport (scroll), muestreado ~10 Hz.
/// - `p`     — puntero: down / move (~20 Hz) / up.
/// - `ev`    — evento de Thor en versión ligera (pantalla, red, error…).
///
/// Se captura por EVENTOS, no por frames: tras un periodo de quietud
/// ([ThorReplayConfig.idle]) o como máximo cada [ThorReplayConfig.maxGap]
/// mientras haya animación.
class ThorReplay {
  ThorReplay._(this._config, this._core, this._file);

  static ThorReplay? _instance;

  /// Instancia activa, si el replay está encendido.
  static ThorReplay? get instance => _instance;

  final ThorReplayConfig _config;
  final ThorCore _core;
  final File? _file;

  final Stopwatch _clock = Stopwatch();
  final List<String> _pendingUpload = [];
  final List<String> _pendingDisk = [];
  final Set<String> _sentHashes = {};
  final Map<String, int> _burst = {};
  final Map<int, double> _lastOffsets = {};
  final Map<int, int> _lastOffsetAt = {};

  List<String>? _prevKeys;
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

  /// Bytes escritos por tipo de registro — para medir el costo real.
  final Map<String, int> bytesByType = {};

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
    _instance = ThorReplay._(config, core, file).._install();
  }

  int get _ts => _clock.elapsedMilliseconds;

  void _install() {
    _clock.start();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    _write({
      't': 'meta',
      'v': 1,
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
    _flushTimer = Timer.periodic(_config.uploadEvery, (_) => flush());
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
      SchedulerBinding.instance.addPostFrameCallback((_) => _snapshot());
      return;
    }
    _idleTimer = Timer(_config.idle, _snapshot);
  }

  void _snapshot() {
    _lastSnapAt = _ts;
    final Wireframe? wire;
    try {
      wire = WireframeBuilder(maskText: _config.maskText).build();
    } on Object {
      return;
    }
    if (wire == null) return;
    _viewports = wire.viewports;
    for (final MapEntry(:key, :value) in wire.offsets.entries) {
      _lastOffsets[key] = value;
    }
    final keys = [for (final op in wire.ops) jsonEncode(op)];
    final hash = _fnv(keys.join('\n'));
    if (hash == _prevHash) return;
    final offs = {
      for (final MapEntry(:key, :value) in wire.offsets.entries)
        '$key': _round(value),
    };

    if (_sentHashes.contains(hash)) {
      _write({'t': 'ref', 'ts': _ts, 'h': hash, 'offs': offs});
    } else {
      final delta = _delta(keys, wire.ops);
      final full = {
        't': 'snap',
        'ts': _ts,
        'h': hash,
        'offs': offs,
        'ops': wire.ops,
      };
      if (delta != null && _prevHash != null) {
        final record = {
          't': 'delta',
          'ts': _ts,
          'h': hash,
          'base': _prevHash,
          'offs': offs,
          'seq': delta,
        };
        // El delta solo gana si de verdad es más chico.
        final dJson = jsonEncode(record);
        if (dJson.length < jsonEncode(full).length * 0.6) {
          _writeRaw('delta', dJson);
        } else {
          _write(full);
        }
      } else {
        _write(full);
      }
      _sentHashes.add(hash);
    }
    _prevKeys = keys;
    _prevHash = hash;
  }

  /// Expresa la lista nueva como secuencia de segmentos: `[inicio, largo]`
  /// = rango copiado del estado anterior, o la primitiva nueva tal cual.
  /// El orden importa (es el orden de pintado), por eso no es un set-diff.
  List<Object?>? _delta(List<String> keys, List<List<Object?>> ops) {
    final prev = _prevKeys;
    if (prev == null) return null;
    final index = <String, int>{};
    for (var i = 0; i < prev.length; i++) {
      index.putIfAbsent(prev[i], () => i);
    }
    final seq = <Object?>[];
    List<int>? run;
    for (var i = 0; i < keys.length; i++) {
      final j = index[keys[i]];
      if (j != null && run != null && run[0] + run[1] == j) {
        run[1]++;
      } else if (j != null) {
        run = [j, 1];
        seq.add(run);
      } else {
        run = null;
        seq.add(ops[i]);
      }
    }
    return seq;
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
      _write({'t': 'sc', 'ts': now, 'v': vp.id, 'o': _round(px)});
    }
  }

  void _onPointer(PointerEvent e) {
    final x = _round(e.position.dx);
    final y = _round(e.position.dy);
    if (e is PointerDownEvent) {
      _pointerDown = true;
      _write({'t': 'p', 'ts': _ts, 'k': 'd', 'x': x, 'y': y});
    } else if (e is PointerMoveEvent && _pointerDown) {
      if (_ts - _lastMoveAt < 50) return;
      _lastMoveAt = _ts;
      _write({'t': 'p', 'ts': _ts, 'k': 'm', 'x': x, 'y': y});
    } else if (e is PointerUpEvent || e is PointerCancelEvent) {
      _pointerDown = false;
      _write({'t': 'p', 'ts': _ts, 'k': 'u', 'x': x, 'y': y});
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
    _write({
      't': 'ev',
      'ts': _ts,
      'k': event.kind.name,
      if (event.screen != null) 'sc': event.screen!.display,
      'p': slim,
    });
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
        'err': p['errorMessage'],
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

  void _write(Map<String, Object?> record) =>
      _writeRaw(record['t']! as String, jsonEncode(record));

  void _writeRaw(String type, String line) {
    bytesByType[type] = (bytesByType[type] ?? 0) + line.length + 1;
    _pendingDisk.add(line);
    if (_config.endpoint != null) _pendingUpload.add(line);
  }

  /// Vacía lo pendiente a disco y, si hay endpoint, lo sube en un lote
  /// gzip. Un fallo de red deja el lote para el siguiente intento.
  Future<void> flush() async {
    final file = _file;
    if (file != null && _pendingDisk.isNotEmpty) {
      final batch = '${_pendingDisk.join('\n')}\n';
      _pendingDisk.clear();
      await file.writeAsString(batch, mode: FileMode.append, flush: true);
    } else {
      _pendingDisk.clear();
    }
    final endpoint = _config.endpoint;
    if (endpoint == null || _pendingUpload.isEmpty || _uploading) return;
    _uploading = true;
    final lines = List<String>.of(_pendingUpload);
    try {
      final body = gzip.encode(utf8.encode(lines.join('\n')));
      final http = _http ??= HttpClient();
      final req = await http.postUrl(endpoint);
      req.headers
        ..set('content-type', 'application/x-ndjson')
        ..set('content-encoding', 'gzip')
        ..set('x-thor-session', _core.session.sessionId);
      req.add(body);
      final res = await req.close();
      await res.drain<void>();
      if (res.statusCode < 300) _pendingUpload.removeRange(0, lines.length);
    } on Object {
      // Sin red: se reintenta en el siguiente ciclo.
    } finally {
      _uploading = false;
    }
  }

  /// Apaga el replay (tests / logout).
  static Future<void> stop() async {
    final r = _instance;
    if (r == null) return;
    _instance = null;
    r._idleTimer?.cancel();
    r._flushTimer?.cancel();
    r._unsubscribe?.call();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(r._onPointer);
    await r.flush();
  }

  static num _round(double v) => (v * 10).round() / 10;

  /// Dos hashes FNV-1a de 32 bits (semilla y primo distintos) → 16 hex. Enteros
  /// acotados a 32 bits: mismo resultado en VM y en web.
  static String _fnv(String s) {
    var a = 0x811c9dc5;
    var b = 0x9747b28c;
    for (final c in s.codeUnits) {
      a = ((a ^ c) * 0x01000193) & 0xFFFFFFFF;
      b = ((b ^ c) * 0x5bd1e995) & 0xFFFFFFFF;
    }
    return a.toRadixString(16).padLeft(8, '0') +
        b.toRadixString(16).padLeft(8, '0');
  }
}
