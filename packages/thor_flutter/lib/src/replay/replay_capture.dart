import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/overlay/thor_ui.dart' show ThorUi;
import 'package:thor_flutter/src/replay/wireframe.dart';

/// Cuánto oculta el replay de lo que sale del dispositivo.
enum ThorPrivacy {
  /// Default: el replay se ve como un video y la red va completa (URL con
  /// query, headers, cuerpos), con SOLO los secretos tapados
  /// (`Authorization`, cookies, tokens, API keys, contraseñas, tarjeta,
  /// CVV, PIN). Emails, ids, nombres y direcciones pasan tal cual: sin
  /// ellos no se puede depurar un servicio.
  secretsOnly,

  /// Opt-in para apps sensibles: el comportamiento anterior. Texto en
  /// pantalla y labels de taps enmascarados (largos de palabra), red solo
  /// con método/ruta/status/duración en las exitosas (query fuera, ruta
  /// sin `:email`/`:n`/`:token`) y cuerpos por la allowlist de
  /// `RedactionPolicy.strict()`; logs, errores y rutas sin datos con forma
  /// personal. Para el mismo nivel en el journal y el reporte local, usar
  /// además `Thor.run(redaction: RedactionPolicy.strict())`.
  strict,
}

/// Configuración del replay de sesión.
class ThorReplayConfig {
  /// Crea la configuración.
  const ThorReplayConfig({
    this.privacy,
    this.maskText = false,
    this.maxBodyBytes = 4096,
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
    this.unmaskedTexts = const {},
    this.configEndpoint,
  });

  /// Nivel de privacidad ([ThorPrivacy]). `null` (default) sigue a la
  /// política de `Thor.run`: [ThorPrivacy.secretsOnly] con la de por
  /// defecto, [ThorPrivacy.strict] si la app pasó
  /// `RedactionPolicy.strict()` (o cualquier allowlist).
  final ThorPrivacy? privacy;

  /// Enmascara el texto de la pantalla. Apagado por defecto: el replay se
  /// ve como un video, con el texto real (también lo tecleado en campos
  /// normales). En cualquier modo, jamás viaja el contenido de un campo
  /// oculto (`obscureText`, autofill de contraseña/tarjeta,
  /// `TextInputType.visiblePassword`: solo si está lleno) ni nada dentro
  /// de un `ThorReplayIgnore`. [ThorPrivacy.strict] lo enciende siempre.
  ///
  /// Encendido, el texto viaja como largos de palabra y aplica también a
  /// los labels de taps (`ev` de interacción): un tap en una fila que
  /// muestra "Ana Pérez" no manda "Ana Pérez" mientras la pantalla lo
  /// tapa. Pasan legibles solo los que son copy de la interfaz (botones de
  /// alto nivel, tooltips, hints, íconos, o dentro de un
  /// `ThorReplayShowText`), sin emails, números largos ni tokens.
  final bool maskText;

  /// Tope por cuerpo (petición y respuesta) en los eventos de red del
  /// replay, en caracteres del JSON/texto ya redactado. Un cuerpo más
  /// largo viaja cortado como texto con `qbt`/`bt: true`; el tamaño real
  /// va en `qn`/`rn`. En modo diagnóstico sube al tope de la captura
  /// (`ThorNetworkCapture.maxBodyBytes`, 8 KB) si este es menor.
  final int maxBodyBytes;

  /// Textos exactos que son copy de la app y viajan legibles aunque
  /// [maskText] esté encendido — típicamente las cadenas de su l10n
  /// (`{'Pagar', 'Mis pedidos', …}`). Coincidencia exacta del texto
  /// completo: en pantalla y en labels de taps. Para marcar una zona
  /// entera, `ThorReplayShowText`.
  final Set<String> unmaskedTexts;

  /// Manda la URL de cada imagen. Apagado: la imagen es un rectángulo.
  final bool imageUrls;

  /// URL de ingesta (`POST`, cuerpo gzip NDJSON). `null` = solo disco.
  final Uri? endpoint;

  /// Llave de la app para la ingesta (header `x-thor-key`). El servidor
  /// rechaza sin ella (401) salvo en desarrollo.
  final String? apiKey;

  /// Configuración bajo demanda (`POST`, JSON, opcional). Se le pregunta al
  /// arrancar y cada vez que `Thor.setUser` cambia el usuario (una vez por
  /// usuario por sesión) si un operador pidió el replay de este
  /// usuario/sesión desde el dashboard: así se depura la queja de UN
  /// cliente sin subir el 100% de las sesiones. Contesta
  /// `{"upload": bool, "detail": bool, "until": …}`:
  /// - `upload` — esta sesión sube completa, como si cayera en la muestra.
  /// - `detail` — modo diagnóstico: los logs van en todos los niveles
  ///   (no solo warn/error) y el tope de cuerpos de red sube de
  ///   [maxBodyBytes] a 8 KB. En [ThorPrivacy.strict], además, las
  ///   peticiones exitosas llevan cuerpos y headers (ya redactados).
  ///
  /// Un fallo (sin red, 500, JSON raro) se ignora: la sesión sigue con lo
  /// que decidió la muestra. `null` = no se pregunta.
  final Uri? configEndpoint;

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
/// - `{"t":"meta",…}` — sesión, tamaño de pantalla, `iid` (instalación,
///   estable entre lanzamientos) y `device`: `{os, osVersion, locale,
///   model?, simulator?}` (`model` y `simulator` solo si se pudieron
///   saber; ver `Thor.run(deviceInfo:)`).
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
/// - `{"t":"gap","k":"background","ts":…,"ms":…,"from":…,"wall":…}` —
///   la app estuvo en segundo plano `ms` milisegundos reales. El reloj del
///   replay (`ts`) se detiene mientras tanto: ese tiempo NO está en la
///   duración del replay; el marcador existe para que el dashboard lo
///   excluya de la duración de la sesión si la calcula con el reloj de
///   pared. `from`/`wall` son la
///   hora real (UTC) de salida y de regreso: los `ts` no la cuentan.
/// - `{"t":"end","reason":…,"ts":…,"bg":…}` — fin de la sesión: `reason`
///   `clean`/`renewed` (la app la cerró) o `killed`/`crash` (la
///   recuperación del siguiente arranque la derivó del archivo); `bg` =
///   segundos en segundo plano. Sin este registro, la sesión sigue abierta.
/// - `{"t":"ev",…}` — evento de Thor en versión ligera. `sc` = pantalla,
///   `sd` = su contexto fino si lo hay (`Thor.setScreenContext` o el
///   título del AppBar visible). En un tap, `p.l`
///   es el label (string; enmascarado, la lista de largos de palabra como
///   el texto en pantalla); `p.k` la Key, solo si el label es legible.
///   Un log (`k: "log"`) es `p.l` (marca de `Thor.mark`) o
///   `{lv, src, m, n?, err?, x?}` (línea de consola sin secretos; `x` =
///   líneas recortadas por ráfaga; `data?` = campos estructurados de
///   `Thor.log(data: …)`, sin secretos y ≤ 2 KB). Solo warn/error, salvo
///   en modo diagnóstico y los `Thor.log` con `data`.
///   Un evento de negocio (`k: "track"`) es `{n, props?}`
///   (`Thor.track(name, props)`; props sin secretos, ≤ 2 KB).
///   `{l: "report", reason?}` = el usuario tocó "Reportar problema"
///   ([requestUpload]).
///
///   Red (`k: "network"`), TODAS las peticiones (exitosas también; nunca
///   imágenes, fuentes ni assets estáticos):
///   `{m, u, s, d, qh?, rh?, qb?, body?, qbt?, bt?, qn?, rn?, x?, err?, at?}`
///   — método, URL completa con query, status, duración (ms), headers de
///   petición/respuesta, cuerpo de petición (`qb`) y de respuesta
///   (`body`): JSON decodificado si es JSON, texto si no; binarios solo
///   por tamaño. Cada cuerpo hasta [ThorReplayConfig.maxBodyBytes];
///   cortado → texto con `qbt`/`bt: true`. `qn`/`rn` = bytes reales.
///   `err` (mensaje) y `at` (`archivo:línea` de origen) solo si falló.
///   URL, headers y cuerpos ya pasaron por la política: solo los
///   secretos van tapados.
///   En [ThorPrivacy.strict]: `{m, u, s, d}` (sin query) y en un fallo
///   `err`, `at`, `body`; en modo diagnóstico todas `body`, `qb`, `qh`,
///   `rh`, redactados con `RedactionPolicy.strict()`.
///
/// Secuencia (`q`): TODO registro salvo `blk` lleva un número monótono por
/// sesión (1, 2, 3…) para que el servidor deduplique exacto —`(sid, q)`
/// ya visto se descarta— cuando una subida se reintenta o la recuperación
/// repite un tramo. En los mapas es la clave `"q"`; en los arreglos es el
/// ÚLTIMO elemento. `meta` y `user` se escriben una vez por sesión (`user`
/// solo si la identidad cambió; un segundo `meta` corrige el tamaño de la
/// vista si cambió al pintar: el último manda); una copia reenviada lleva
/// el mismo `q`.
///
/// Forma EXACTA de los registros en arreglo (contrato con el servidor;
/// `replay_contract_test.dart` la comprueba), `q` siempre al final:
///
/// - `["st", ts, hash, offs, vps, refs, q]` — 7 elementos.
/// - `["ref", ts, hash, offs, q]` — 5.
/// - `["sc", ts, vp, offset, q]` — 5.
/// - `["p", ts, kind, x, y, q]` — 6 (`kind`: `d`, `m`, `u`).
/// - `["blk", hash, ops]` — 3, SIN `q` (se identifica por su hash).
///
/// Un servidor debe reconocer estos registros por su prefijo e ignorar el
/// `q` final, no por la cantidad exacta de elementos.
///
/// Logs: solo `warn`/`error` llegan al servidor (más los `Thor.log` con
/// `data` y todo en modo diagnóstico). Las líneas informativas de consola,
/// como las `[PERF]`, se quedan en el journal del dispositivo a propósito.
///
/// Subida en dos fases: se mandan los registros sin bloques; el servidor
/// contesta `{"missing": [...]}` y solo esos bloques se mandan después.
/// Una pantalla vista por mil usuarios se sube una vez.
class ThorReplay {
  ThorReplay._(
    this._config,
    this._core,
    this._file,
    this._uploadEnabled,
    this._directory,
  );

  static ThorReplay? _instance;

  /// Archivos de replay cuyo dueño sigue vivo (su `flush` final aún puede
  /// estar subiendo): la recuperación NO los toca. Sin esto, tras una
  /// renovación de sesión la recuperación re-subía —en paralelo con el
  /// flush final del dueño— justo el tramo que este ya estaba mandando.
  static final Set<String> _owned = {};

  /// Hay una recuperación en curso: otra no arranca encima (dos pasadas
  /// sobre los mismos archivos duplican lo que suben).
  static bool _recovering = false;

  /// Instancia activa, si el replay está encendido.
  static ThorReplay? get instance => _instance;

  final ThorReplayConfig _config;
  final ThorCore _core;
  final File? _file;
  final Directory? _directory;

  /// Si esta sesión sube (muestra o ya hubo un error).
  bool _uploadEnabled;

  /// Modo diagnóstico: el replay lleva TODOS los logs (debug/info
  /// incluidos), no solo warn/error, y cuerpos de red hasta 8 KB en vez de
  /// [ThorReplayConfig.maxBodyBytes] (en [ThorPrivacy.strict], además, las
  /// exitosas con cuerpos y headers). Lo enciende el servidor por
  /// sesión/usuario (`detail` de [ThorReplayConfig.configEndpoint]) cuando
  /// hay que perseguir un bug; nunca la app sola.
  bool _diagnostic = false;

  /// Enciende/apaga el modo diagnóstico (ver [_diagnostic]).
  @visibleForTesting
  bool get diagnostic => _diagnostic;
  @visibleForTesting
  set diagnostic(bool value) => _diagnostic = value;

  /// Privacidad efectiva: la pedida, o la que corresponde a la política de
  /// `Thor.run` (ver [ThorReplayConfig.privacy]).
  late final bool _strict = (_config.privacy ??
          (_core.redaction.isSecretsOnly
              ? ThorPrivacy.secretsOnly
              : ThorPrivacy.strict)) ==
      ThorPrivacy.strict;

  /// Texto en pantalla y labels enmascarados.
  bool get _maskText => _config.maskText || _strict;

  /// Limpieza del texto libre que sale (rutas, errores, logs, labels):
  /// solo secretos, o además forma de dato personal en estricto. Sobre un
  /// texto que el núcleo ya limpió es idempotente.
  String _scrub(String text) => _strict
      ? RedactionPolicy.scrubText(text)
      : RedactionPolicy.scrubSecrets(text);

  /// Texto visible para el usuario o su última acción: enmascarado en
  /// `maskText`/estricto; si no, solo secretos.
  String _copyOf(String text) =>
      _maskText ? RedactionPolicy.scrubText(text) : _scrub(text);

  /// Texto de la interfaz (copy de pantalla): con texto enmascarado pierde
  /// su forma de dato; si no, solo secretos.
  String _scrubCopy(String text) =>
      _maskText ? RedactionPolicy.scrubText(text) : _scrub(text);

  final Stopwatch _clock = Stopwatch();
  final List<String> _pendingDisk = [];

  /// Registros aún no confirmados por el servidor (sin bloques), con su
  /// secuencia `q` (0 = un bloque devuelto a la cola).
  final List<({int q, String line})> _pendingUpload = [];

  /// Última secuencia asignada (ver `q` en [ThorReplay]).
  int _seq = 0;

  /// Mayor `q` que el servidor ya confirmó (lo que guarda `.sent`).
  int _ackedSeq = 0;

  /// Identidad ya escrita en el replay (`[uid, uprops]`): un `setUser` con
  /// lo mismo no repite el registro `user`.
  String? _lastUserSig;

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
    for (final url in [config.endpoint, config.configEndpoint]) {
      if (url != null) ThorNetworkCapture.ignoredPrefixes.add(url.toString());
    }
    if (file != null) _owned.add(file.path);
    final sampled = Random().nextDouble() < config.sampleRate;
    final replay =
        _instance = ThorReplay._(config, core, file, sampled, directory)
          .._install();
    if (sampled) replay._markEnabled();
    // Sin await: el arranque de la app no espera a la red.
    unawaited(replay._askConfig());
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
    if (_recovering) return;
    _recovering = true;
    try {
      final http = HttpClient();
      await for (final entity in dir.list()) {
        final path = entity.path;
        if (entity is! File ||
            !path.endsWith('.jsonl') ||
            !path.split('/').last.startsWith('replay-') ||
            path == current.path ||
            _owned.contains(path)) {
          continue;
        }
        final base = path.substring(0, path.length - '.jsonl'.length);
        final on = File('$base.on');
        final sent = File('$base.sent');
        if (on.existsSync()) {
          final sessionId = base.split('/').last.substring('replay-'.length);
          // `q:N` = el servidor ya confirmó hasta la secuencia N; un número
          // suelto es el formato anterior (conteo de registros).
          final mark = sent.existsSync() ? sent.readAsStringSync().trim() : '';
          final acked =
              mark.startsWith('q:') ? int.tryParse(mark.substring(2)) : null;
          final skip = acked == null ? int.tryParse(mark) ?? 0 : 0;
          final blocks = <String, String>{};
          final records = <String>[];
          for (final line in await entity.readAsLines()) {
            if (line.startsWith('["blk","')) {
              blocks[line.substring(8, 24)] = line;
            } else if (line.isNotEmpty) {
              records.add(line);
            }
          }
          // La sesión murió sin cerrar: queda dicho CÓMO (`killed` /
          // `crash`) y cuánto estuvo en segundo plano, para que el dash no
          // tenga que adivinarlo del último evento.
          if (endMarker(records) case final end?) {
            records.add(end);
            try {
              await entity.writeAsString('$end\n', mode: FileMode.append);
            } on Object {
              // Sin escribirlo solo se vuelve a derivar la próxima vez.
            }
          }
          final rest = acked == null
              ? records.skip(skip).toList()
              : [
                  for (final line in records)
                    if ((_seqOf(line) ?? acked + 1) > acked) line,
                ];
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
            // Los registros llegaron pero faltaron bloques: borrar el archivo
            // los perdería para siempre. Se reintenta en el siguiente
            // arranque (el servidor deduplica los registros por `q`).
            if (up.unsentBlocks.isNotEmpty) continue;
          }
        }
        for (final f in [entity, on, sent]) {
          if (f.existsSync()) await f.delete();
        }
      }
      http.close();
    } on Object {
      // La recuperación jamás debe afectar a la app.
    } finally {
      _recovering = false;
    }
  }

  /// El registro de fin de una sesión que murió sin cerrar, derivado de su
  /// propio archivo; `null` si ya lo trae (`stop` lo escribió) o está vacío.
  ///
  /// `reason`: `crash` si hubo un error fatal (zona/plataforma) o murió con
  /// la app en primer plano; `killed` si la última señal de ciclo de vida
  /// fue irse (`inactive`, `hidden`, `paused`, `detached`): la mató el
  /// usuario o el SO. `bg` = segundos en segundo plano (suma de los `gap`).
  @visibleForTesting
  static String? endMarker(List<String> records) {
    if (records.isEmpty) return null;
    var lastTs = 0;
    var lastQ = 0;
    var gapMs = 0;
    String? lastState;
    var fatal = false;
    for (final line in records) {
      if (line.startsWith('{"t":"end"')) return null;
      final q = _seqOf(line);
      if (q != null && q > lastQ) lastQ = q;
      if (!line.startsWith('{')) {
        // Registros en arreglo: `["st", ts, …]` — el ts es el 2.º elemento.
        final m = RegExp(r'^\["\w+",(\d+)').firstMatch(line);
        if (m != null) lastTs = max(lastTs, int.parse(m[1]!));
        continue;
      }
      final isGap = line.startsWith('{"t":"gap"');
      final isEnv = line.contains('"k":"environment"') ||
          line.contains('"signal":"lifecycle"');
      final isFatalErr = line.contains('"k":"error"') &&
          (line.contains('"src":"zone"') || line.contains('"src":"platform"'));
      if (!isGap && !isEnv && !isFatalErr) {
        final m = RegExp(r'"ts":(\d+)').firstMatch(line);
        if (m != null) lastTs = max(lastTs, int.parse(m[1]!));
        continue;
      }
      try {
        final json = jsonDecode(line);
        if (json is! Map) continue;
        final ts = json['ts'];
        if (ts is int) lastTs = max(lastTs, ts);
        if (isGap && json['ms'] is int) gapMs += json['ms'] as int;
        if (isFatalErr) fatal = true;
        final p = json['p'];
        if (isEnv && p is Map && p['signal'] == 'lifecycle') {
          lastState = p['state'] as String?;
        }
      } on Object {
        // Línea a medio escribir (el crash): se ignora.
      }
    }
    final crashed = fatal || lastState == null || lastState == 'resumed';
    return jsonEncode({
      't': 'end',
      'reason': crashed ? 'crash' : 'killed',
      'ts': lastTs,
      'bg': gapMs ~/ 1000,
      'q': lastQ + 1,
    });
  }

  /// Hashes de los bloques que citan los estados (`st`) de [records]: el
  /// 6.º elemento es la lista de refs `[hash, vp, x, y]`. Una línea ilegible
  /// se ignora.
  @visibleForTesting
  static Set<String> referencedHashes(Iterable<String> records) {
    final hashes = <String>{};
    for (final line in records) {
      if (!line.startsWith('["st",')) continue;
      try {
        final json = jsonDecode(line);
        if (json is! List || json.length < 6 || json[5] is! List) continue;
        for (final ref in json[5] as List) {
          if (ref is List && ref.isNotEmpty && ref[0] is String) {
            hashes.add(ref[0] as String);
          }
        }
      } on Object {
        // A medio escribir.
      }
    }
    return hashes;
  }

  /// La secuencia `q` de una línea del archivo: la clave `"q"` al final de
  /// un mapa o el último elemento de un arreglo. `null` si no la trae
  /// (archivo de una versión anterior).
  static int? _seqOf(String line) {
    if (line.endsWith('}')) {
      final i = line.lastIndexOf(',"q":');
      if (i < 0) return null;
      return int.tryParse(line.substring(i + 5, line.length - 1));
    }
    if (line.endsWith(']')) {
      final i = line.lastIndexOf(',');
      if (i < 0) return null;
      return int.tryParse(line.substring(i + 1, line.length - 1));
    }
    return null;
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
    // Una respuesta SIN `missing` no dice "no falta nada": dice que el
    // servidor no contestó la segunda fase (versión vieja, proxy, respuesta
    // vacía). Con estados en el lote se mandan todos los bloques que citan:
    // el servidor los guarda por contenido, así que repetir es barato y
    // perder un bloque no tiene remedio.
    final wanted = first.missing ?? referencedHashes(records);
    final lines = [
      for (final h in wanted)
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
  static Future<({_Sent sent, List<String>? missing})> _post(
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
        // `null` = el servidor no habló de bloques (ver [_upload]).
        missing: json is Map && json['missing'] is List
            ? (json['missing'] as List).cast<String>()
            : null,
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

  /// Guarda hasta qué secuencia confirmó el servidor (`q:N`). Se espera
  /// (las subidas van de una en una): antes eran escrituras sueltas que
  /// podían terminar en desorden y dejar un valor viejo —y la recuperación
  /// re-subía un tramo entero.
  Future<void> _saveSent() async {
    final file = _file;
    if (file == null) return;
    final base = file.path.substring(0, file.path.length - '.jsonl'.length);
    try {
      await File('$base.sent').writeAsString('q:$_ackedSeq', flush: true);
    } on Object {
      // Sin la marca solo se pierde precisión: el servidor deduplica por q.
    }
  }

  /// Tiempo del replay en ms: el reloj de la sesión SIN el tiempo en
  /// segundo plano. Una app que pasa 25 min en background no tiene 25 min
  /// más de video: el reloj se detiene al irse y sigue donde iba al volver.
  int get _ts => (_bgSinceMs ?? _clock.elapsedMilliseconds) - _bgTotalMs;

  /// Tiempo acumulado en segundo plano (ya excluido de [_ts]).
  int _bgTotalMs = 0;

  /// Marca de reloj crudo en la que la app se fue a segundo plano; `null`
  /// en primer plano.
  int? _bgSinceMs;

  /// La app se fue a segundo plano: [_ts] se congela.
  void _enterBackground() {
    if (_bgSinceMs != null) return;
    _bgSinceMs = _clock.elapsedMilliseconds;
    _bgSinceWall = DateTime.now().toUtc();
  }

  /// Hora real (UTC) en la que la app se fue a segundo plano: los `ts` no
  /// cuentan ese tiempo, así que el `gap` lleva la hora absoluta para
  /// alinear el replay con logs externos (backend, Xcode).
  DateTime? _bgSinceWall;

  /// La app volvió: se descuenta lo que estuvo fuera y se deja un registro
  /// `{"t":"gap","k":"background","ts":…,"ms":…}` — `ts` es el punto del
  /// video donde ocurrió y `ms` cuánto duró en realidad, para que el
  /// dashboard excluya ese tiempo de la duración de la sesión.
  void _leaveBackground() {
    final since = _bgSinceMs;
    if (since == null) return;
    final away = _clock.elapsedMilliseconds - since;
    _bgSinceMs = null;
    _bgTotalMs += away;
    final from = _bgSinceWall;
    _bgSinceWall = null;
    _writeJson({
      't': 'gap',
      'k': 'background',
      'ts': _ts,
      'ms': away,
      // Hora real (UTC, ISO 8601) de salida y de regreso.
      if (from != null) 'from': from.toIso8601String(),
      'wall': DateTime.now().toUtc().toIso8601String(),
    });
  }

  void _install() {
    _clock.start();
    _writeMeta();
    _lastUserSig = jsonEncode([_core.userId, _core.userProps]);
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    // Lo que el núcleo ya anotó antes de que el replay arrancara (cómo
    // terminó la sesión anterior) sería invisible para el servidor: vive
    // solo en el journal del dispositivo.
    for (final event in _core.store.ofKind(ThorEventKind.environment)) {
      if (event.payload['signal'] == 'previous_session') _onEvent(event);
    }
    _unsubscribe = _core.recorder.addListener(_onEvent);
    _flushTimer = Timer.periodic(_config.saveEvery, (_) {
      final due = _ts - _lastUploadAt >= _config.uploadEvery.inMilliseconds;
      unawaited(flush(upload: due));
    });
    WidgetsBinding.instance.addObserver(_lifecycle);
    _scheduleSnapshot();
  }

  /// Tamaño (px lógicos) que declara el `meta` vigente de la sesión.
  Size? _metaSize;

  /// Escribe el registro `meta` con el tamaño de la vista de ESTE momento.
  /// Se llama al arrancar y, si la vista cambió de forma (la app arranca
  /// con la orientación del sistema a medias y luego gira), una vez más al
  /// primer snapshot: el último `meta` manda.
  void _writeMeta() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    _metaSize = size;
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
      if (_device() case final device?) 'device': device,
      // Con qué política se grabó: el dash lo muestra y avisa cuándo
      // espera ver datos personales (secretsOnly) y cuándo no (strict).
      'redaction': _strict ? 'strict' : 'secretsOnly',
      if (_core.userId != null) 'uid': _core.userId,
      if (_core.userProps != null) 'uprops': _core.userProps,
    });
  }

  bool _metaChecked = false;

  /// Primer snapshot real: si el tamaño de la vista ya no es el del `meta`
  /// (p. ej. 874×402 al arrancar y 402×874 al pintar), se corrige.
  void _checkMetaSize() {
    if (_metaChecked) return;
    _metaChecked = true;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    final was = _metaSize;
    if (was == null) return;
    if ((size.width - was.width).abs() > 1 ||
        (size.height - was.height).abs() > 1) {
      _writeMeta();
    }
  }

  /// `meta.device`: lo que el adaptador supo del dispositivo sin plugins
  /// (`Thor.run(deviceInfo:)` suma el modelo exacto).
  Map<String, Object?>? _device() {
    final info = _core.session.deviceInfo;
    final device = <String, Object?>{
      for (final key in const ['os', 'osVersion', 'locale', 'model'])
        if (info[key] case final value? when value.isNotEmpty) key: value,
      if (info['simulator'] case final value?) 'simulator': value == 'true',
    };
    return device.isEmpty ? null : device;
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
    // La UI propia de Thor (inspector, reporte de crash) no es contenido
    // de la sesión: el video se queda en la última pantalla real.
    if (ThorUi.openPages > 0) return;
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
        maskText: _maskText,
        imageUrls: _config.imageUrls,
        unmaskedTexts: _config.unmaskedTexts,
      ).build();
      if (wire == null) return;
      (:vps, :refs, :blocks) = split(wire.ops);
      hash = fnv(jsonEncode([vps, refs]));
    } on Object {
      return;
    }
    _snapWatch.stop();
    _checkMetaSize();
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
    if (ThorUi.openPages > 0) return;
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
    // "sesiones del usuario X" sin parsear eventos, con los props que la
    // app mandó a propósito (ya sin secretos).
    if (event.kind == ThorEventKind.environment && p['signal'] == 'user') {
      // Una vez por identidad: el mismo usuario reafirmado no se repite.
      final sig = jsonEncode([p['id'], p['props']]);
      if (sig == _lastUserSig) return;
      _lastUserSig = sig;
      _writeJson({
        't': 'user',
        'ts': _ts,
        'id': p['id'],
        if (p['props'] != null) 'props': p['props'],
      });
      _scheduleConfig();
      return;
    }
    final slim = switch (event.kind) {
      // Un nombre de ruta puede traer secretos (deep link con `?token=`)
      // y, en estricto, datos (`/orders/10293847`).
      ThorEventKind.navigation => {
          'a': p['action'],
          'to': p['to'] is String ? _scrub(p['to']! as String) : p['to'],
          // Sin `from`, "pop SearchScreen → SearchScreen" es ambiguo.
          if (p['from'] is String) 'from': _scrub(p['from']! as String),
        },
      ThorEventKind.interaction => _slimInteraction(p),
      // El mensaje es el toString de la excepción: puede interpolar un
      // token o, en estricto, datos del usuario ("cliente ana@x.com no
      // existe"). Misma limpieza que logs y labels.
      ThorEventKind.error => {
          'type': p['type'],
          'msg': switch (p['message']) {
            final String m when p['source'] == 'ui_error' && _maskText =>
              RedactionPolicy.scrubText(m),
            final String m => _scrub(m),
            final other => other,
          },
          'src': p['source'],
          'at': event.origin,
          // Diagnóstico completo del error: stack (hasta 60 frames/8 KB),
          // contexto de Flutter y, en un desborde, widget y archivo.
          if (p['stack'] is String) 'stack': _scrub(p['stack']! as String),
          if (p['context'] is String) 'ctx': _scrub(p['context']! as String),
          if (p['info'] is String) 'info': _scrub(p['info']! as String),
          if (p['widget'] is String) 'widget': p['widget'],
          if (p['file'] is String) 'file': p['file'],
          // Lo que el usuario vio (texto del diálogo / excepción cruda) y
          // lo último que tocó: con la misma limpieza que el mensaje.
          if (p['text'] is String) 'text': _copyOf(p['text']! as String),
          if (p['lastAction'] is String)
            'lastAction': _copyOf(p['lastAction']! as String),
        },
      ThorEventKind.network => _slimNetwork(p, event.origin),
      ThorEventKind.state => _slimState(p),
      ThorEventKind.log => _slimLog(p),
      ThorEventKind.track => _slimTrack(p),
      ThorEventKind.performance => _slimPerformance(p),
      ThorEventKind.environment => _slimEnvironment(p),
      _ => null,
    };
    if (slim == null) return;
    _writeJson({
      't': 'ev',
      'ts': _ts,
      'k': event.kind.name,
      if (event.screen != null) 'sc': _scrub(event.screen!.display),
      if (event.screen?.detail case final detail?) 'sd': _scrubCopy(detail),
      'p': slim,
    });
    // Una sesión con fallo se sube entera aunque no estuviera en la
    // muestra: es justo la que hay que depurar.
    // Un error INTERNO del SDK (disco del journal) no es motivo para subir
    // la sesión: no es la falla de la app que se quiere depurar.
    final failed = (event.kind == ThorEventKind.error &&
            p['internal'] != true) ||
        (event.kind == ThorEventKind.network && slim.containsKey('err'));
    if (!failed || !_config.uploadOnError) return;
    if (!_uploadEnabled) {
      _enableUpload();
    } else if (event.kind == ThorEventKind.error) {
      // Ya subía (otro fallo antes, la muestra, el dashboard): el error
      // tampoco espera al siguiente ciclo — si la app muere ahora, el
      // dashboard ya lo tiene.
      _flushForError();
    }
  }

  /// Mínimo entre subidas disparadas por errores: un error que se repite
  /// en cada frame no debe convertirse en una subida por frame.
  @visibleForTesting
  static Duration errorFlushGap = const Duration(seconds: 10);
  Timer? _errorFlushTimer;
  int? _errorFlushedAt;

  void _flushForError() {
    if (_errorFlushTimer != null) return;
    final since = _errorFlushedAt == null ? null : _ts - _errorFlushedAt!;
    final wait =
        since == null ? 0 : max(0, errorFlushGap.inMilliseconds - since);
    _errorFlushTimer = Timer(Duration(milliseconds: wait), () {
      _errorFlushTimer = null;
      _errorFlushedAt = _ts;
      unawaited(flush());
    });
  }

  /// Esta sesión pasa a subir COMPLETA (desde el inicio: [_pendingUpload]
  /// guarda todo hasta que el servidor lo confirma). Marca `.on` para
  /// recuperarla si la app muere, y sube ya.
  void _enableUpload() {
    if (_uploadEnabled || _rejected) return;
    _uploadEnabled = true;
    _markEnabled();
    unawaited(flush());
  }

  /// El servidor rechazó la llave o la sesión (401/403): ni un error ni el
  /// dashboard la reactivan — reintentar con la misma llave no sirve.
  bool _rejected = false;

  // ── Configuración bajo demanda ──

  /// Usuarios por los que ya se preguntó en esta sesión ([_userKey]).
  final Set<String> _askedConfig = {};
  Timer? _configTimer;

  /// Espera tras un `setUser` antes de preguntar: el login suele fijar el
  /// id y luego los props en ráfaga; se pregunta una vez, con lo último.
  @visibleForTesting
  static Duration configDebounce = const Duration(milliseconds: 500);

  /// Identidad para "una vez por usuario": el id, o los props si la app
  /// solo manda props (el operador puede buscar por email).
  String _userKey() =>
      _core.userId ??
      (_core.userProps == null ? '' : jsonEncode(_core.userProps));

  void _scheduleConfig() {
    if (_config.configEndpoint == null) return;
    if (_askedConfig.contains(_userKey())) return;
    _configTimer?.cancel();
    _configTimer = Timer(configDebounce, () => unawaited(_askConfig()));
  }

  /// Pregunta a [ThorReplayConfig.configEndpoint] si alguien pidió esta
  /// sesión. Nunca lanza ni bloquea: cualquier fallo deja todo como está.
  Future<void> _askConfig() async {
    final url = _config.configEndpoint;
    if (url == null || _instance != this) return;
    if (!_askedConfig.add(_userKey())) return;
    try {
      final req = await (_http ??= HttpClient())
          .postUrl(url)
          .timeout(const Duration(seconds: 15));
      req.headers.contentType = ContentType.json;
      if (_config.apiKey case final key?) req.headers.set('x-thor-key', key);
      req.write(
        jsonEncode({
          'iid': _core.session.installId,
          'sid': _core.session.sessionId,
          'uid': _core.userId,
          'props': _core.userProps,
        }),
      );
      final res = await req.close().timeout(const Duration(seconds: 15));
      final text = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200 || _instance != this) return;
      final json = jsonDecode(text);
      if (json is! Map) return;
      // `detail` primero: lo que se suba ya va con el nivel pedido.
      if (json['detail'] == true) _diagnostic = true;
      if (json['upload'] == true) _enableUpload();
    } on Object {
      // Sin red, timeout o respuesta rara: la sesión sigue con la muestra.
    }
  }

  /// Para un botón "Reportar problema" en la app: esta sesión sube YA,
  /// completa, con una marca `{"l":"report","reason":…}` en la línea de
  /// tiempo para encontrar el momento. [reason] la escribe el usuario: se
  /// limpia (secretos; en estricto también datos personales) y se recorta
  /// como cualquier log.
  ///
  /// Sin replay encendido es no-op. Normalmente completa cuando el intento
  /// de subida terminó (haya llegado o no: lo que falte se reintenta como
  /// siempre); si ya había una subida en curso, la nueva sale en cuanto
  /// esa termine.
  static Future<void> requestUpload({String? reason}) async {
    final r = _instance;
    if (r == null) return;
    r._writeJson({
      't': 'ev',
      'ts': r._ts,
      'k': ThorEventKind.log.name,
      if (r._core.recorder.currentScreen case final screen?)
        'sc': screen.display,
      'p': {
        'l': 'report',
        if (reason != null && reason.isNotEmpty)
          'reason': ThorCore.cleanLogText(reason, 500, scrub: r._scrub),
      },
    });
    if (!r._uploadEnabled && !r._rejected) {
      r
        .._uploadEnabled = true
        .._markEnabled();
    }
    await r.flush();
  }

  /// Tap: el label sigue la misma regla que el texto en pantalla.
  ///
  /// - Dentro de `ThorReplayIgnore`: ni label ni Key (la zona no existe
  ///   para el replay).
  /// - Texto visible (default): legible, solo sin secretos
  ///   ([RedactionPolicy.scrubSecrets]).
  /// - Enmascarado (`maskText` o [ThorPrivacy.strict]): copy de la
  ///   interfaz (`copy: true` de InteractionCapture) o texto en
  ///   [ThorReplayConfig.unmaskedTexts] legibles pero sin forma de dato
  ///   ([RedactionPolicy.scrubText]: "Llamar 55 1234 5678" → "Llamar
  ///   :n"); lo demás (ListTile, InkWell, GestureDetector con texto
  ///   arbitrario, labels semánticos que FUSIONAN el texto de los hijos)
  ///   como largos de palabra. La Key (`k`) solo viaja con el label
  ///   legible: en una lista suele ser el id o el nombre del item
  ///   (`ValueKey(cliente.email)`).
  Map<String, Object?> _slimInteraction(Map<String, Object?> p) {
    // Gestos de arrastre: geometría sin datos (dirección, distancia,
    // duración, coordenadas de pantalla).
    final drag = <String, Object?>{
      for (final k in const [
        'dir', 'distance', 'durationMs', 'start', 'end', 'axis', 'edge', //
        'popped', //
        'obscure', 'keyboard', //
        // Entrada de texto: solo tamaños y banderas, jamás el contenido.
        'length', 'startLength', 'empty', 'edits', 'source', //
      ])
        if (p[k] != null) k: p[k],
    };
    if (p['hidden'] == true) {
      return {'g': p['gesture'], 'w': p['widget'], ...drag};
    }
    final label = p['label'] as String?;
    final key = p['key'] as String?;
    final mask = _maskText;
    final readable = !mask ||
        p['copy'] == true ||
        (label != null && _config.unmaskedTexts.contains(label));
    String clean(String text) =>
        mask ? RedactionPolicy.scrubText(text) : _scrub(text);
    return {
      'g': p['gesture'],
      'l': label == null
          ? null
          : readable
              ? clean(label)
              : WireframeBuilder.mask(label),
      'w': p['widget'],
      if (key != null && readable) 'k': clean(key),
      ...drag,
    };
  }

  /// Log: las marcas siempre; las líneas de consola solo warn/error (las
  /// de debug/info son volumen sin valor para quien mira el replay), todas
  /// en [_diagnostic]. El mensaje ya viene limpio de `ThorCore.log` con la
  /// política de `Thor.run`; aquí se vuelve a pasar por [_scrub] por si el
  /// replay es más estricto que esa política.
  Map<String, Object?>? _slimLog(Map<String, Object?> p) {
    if (p['label'] != null) return {'l': p['label']};
    final level = ThorLogLevel.tryParse(p['level']);
    if (level == null) return null;
    // Un `Thor.log` con `data` es deliberado (la app quiso dejar campos
    // estructurados): entra en cualquier nivel. La consola sigue filtrada.
    final deliberate = p['source'] == 'thor' && p['data'] != null;
    if (!level.isHigh && !_diagnostic && !deliberate) return null;
    Object? clean(Object? v) => v is String ? _scrub(v) : v;
    return {
      'lv': level.name,
      'src': p['source'],
      'm': clean(p['message']),
      if (p['data'] != null) 'data': _slimData(p['data']),
      if (p['name'] != null) 'n': clean(p['name']),
      if (p['error'] != null) 'err': clean(p['error']),
      if (p['burst'] == true) 'x': p['dropped'],
    };
  }

  /// Evento de negocio (`Thor.track`): `{n, props?}`. Las props ya vienen
  /// sin secretos del núcleo; en [ThorPrivacy.strict] se re-redactan con
  /// la política estricta (valores enmascarados).
  Map<String, Object?> _slimTrack(Map<String, Object?> p) => {
        'n': switch (p['name']) {
          final String n => _scrub(n),
          final other => other,
        },
        if (p['props'] != null) 'props': _slimData(p['props']),
      };

  /// Rendimiento (`startup`, `screen_load`, `jank`, `anr`, `custom`): solo
  /// números y nombres de pantalla/medida (con la limpieza de siempre);
  /// el `data` de un `custom` sigue la regla de [_slimData].
  Map<String, Object?> _slimPerformance(Map<String, Object?> p) {
    Object? clean(Object? v) => v is String ? _scrub(v) : v;
    return {
      'kind': p['kind'],
      for (final k in const [
        'ms', 'until', 'slow', 'frozen', 'worstMs', 'frames', 'nodes', //
        'interrupted', 'capped', 'startAt', 'via', //
      ])
        if (p[k] != null) k: p[k],
      for (final k in const ['screen', 'from', 'name'])
        if (p[k] != null) k: clean(p[k]),
      if (p['data'] != null) 'data': _slimData(p['data']),
    };
  }

  /// Contexto del dispositivo (`lifecycle`, `memory_pressure`, `locale`,
  /// `text_scale`, `brightness`, `connectivity`): solo la señal y su valor
  /// escalar. El `user` no llega aquí (tiene registro propio).
  Map<String, Object?> _slimEnvironment(Map<String, Object?> p) => {
        'signal': p['signal'],
        for (final k in const [
          'state', 'value', 'online', 'widget', 'transition', //
          // permission / external_surface / system_overlay / sesión.
          'kind', 'before', 'after', 'prompt', 'host', 'mode', 'ms', //
          'source', 'reason', 'session', 'backgroundMs', 'transient', //
        ])
          if (p[k] != null)
            k: p[k] is String
                ? (p['signal'] == 'screen_context' ? _scrubCopy : _scrub)(
                    p[k]! as String,
                  )
                : p[k],
        // Texto de un diálogo/snackbar de la app: copy escrito por la app,
        // pero puede interpolar datos; con texto enmascarado pierde su forma.
        if (p['text'] is String)
          'text': _maskText
              ? RedactionPolicy.scrubText(p['text']! as String)
              : _scrub(p['text']! as String),
      };

  /// Campos estructurados (`data` de un log, `props` de un track): tal
  /// cual (solo secretos tapados) o re-redactados en estricto.
  Object? _slimData(Object? data) =>
      _strict ? _strictPolicy.redactValue(data) : data;

  static final _staticAsset = RegExp(
    r'(assets|img|cdn)[^/]*\.|\.(png|jpe?g|webp|svg|gif|woff2?)(\?|$)',
  );

  /// Imágenes, fuentes y video por content-type de la respuesta: un CDN
  /// sin extensión en la URL también es estático.
  static bool _staticType(Object? headers) {
    if (headers is! Map) return false;
    for (final MapEntry(:key, :value) in headers.entries) {
      if ('$key'.toLowerCase() != 'content-type') continue;
      final type = '$value'.toLowerCase();
      return type.startsWith('image/') ||
          type.startsWith('font/') ||
          type.startsWith('video/') ||
          type.startsWith('audio/');
    }
    return false;
  }

  static const _strictPolicy = RedactionPolicy.strict();

  /// Red: TODAS las peticiones con su detalle (ver el formato en
  /// [ThorReplay]). Lo que llega aquí ya pasó por la política de
  /// `Thor.run` (por defecto solo secretos tapados); en [ThorPrivacy.strict]
  /// se re-redacta con `RedactionPolicy.strict()` y vuelve el formato
  /// mínimo de antes.
  Map<String, Object?>? _slimNetwork(Map<String, Object?> p, String? at) {
    final url = (p['url'] as String?) ?? '';
    if (_staticAsset.hasMatch(url) || _staticType(p['responseHeaders'])) {
      return null;
    }
    final status = p['statusCode'] as int?;
    final failed = status == null || status >= 400 || p['error'] != null;
    final err = p['errorMessage'];
    final failure = {
      if (failed) ...{
        'err': err is String ? _scrub(err) : 'HTTP $status',
        'at': at,
      },
    };
    if (_strict) return _slimNetworkStrict(p, url, failed, failure);
    // Diagnóstico: todo lo que retuvo la captura (nunca menos que lo
    // configurado).
    final base = _diagnostic
        ? max(_config.maxBodyBytes, ThorNetworkCapture.maxBodyBytes)
        : _config.maxBodyBytes;
    // Una regla de endpoint (`ThorBodyRule.maxBytes`) sube el tope de ESA
    // ruta; nunca por debajo del global.
    final ruleCap = p['bodyCap'];
    final cap = ruleCap is int ? max(base, ruleCap) : base;
    final qb =
        _clipBody(p['requestBody'], cap, omitted: p['requestBodyOmitted']);
    final body =
        _clipBody(p['responseBody'], cap, omitted: p['responseBodyOmitted']);
    final qn = p['requestBytes'];
    final rn = p['responseBytes'];
    return {
      'm': p['method'],
      'u': url,
      's': status,
      'd': p['durationMs'],
      if (p['requestHeaders'] case final Map<Object?, Object?> h
          when h.isNotEmpty)
        'qh': h,
      if (p['responseHeaders'] case final Map<Object?, Object?> h
          when h.isNotEmpty)
        'rh': h,
      if (qb.value != null) 'qb': qb.value,
      if (qb.cut || p['requestBodyTruncated'] == true) 'qbt': true,
      if (qn is int && qn > 0) 'qn': qn,
      if (body.value != null) 'body': body.value,
      if (body.cut || p['responseBodyTruncated'] == true) 'bt': true,
      if (rn is int && rn > 0) 'rn': rn,
      // Cifras extraídas por una regla de endpoint (`$..quantity` → n/sum…).
      if (p['extracts'] case final Map<Object?, Object?> x when x.isNotEmpty)
        'x': x,
      ...failure,
    };
  }

  /// Un cuerpo para el replay: tal cual si cabe en [cap]; si no, el
  /// principio de su JSON/texto (`cut`). Un binario omitido no viaja (su
  /// tamaño va en `qn`/`rn`).
  static ({Object? value, bool cut}) _clipBody(
    Object? body,
    int cap, {
    Object? omitted,
  }) {
    if (body == null || omitted == true) return (value: null, cut: false);
    final String text;
    try {
      text = body is String ? body : jsonEncode(body);
    } on Object {
      return (value: null, cut: false);
    }
    if (text.length <= cap) return (value: body, cut: false);
    return (value: text.substring(0, max(0, cap)), cut: true);
  }

  /// El formato mínimo de [ThorPrivacy.strict] (el de siempre): exitosas
  /// con lo esencial; fallidas con cuerpo de respuesta y origen; en
  /// [_diagnostic] todas con cuerpos y headers. Re-redactado con
  /// `RedactionPolicy.strict()` — idempotente si `Thor.run` ya era
  /// estricto, y cierra la fuga si no lo era.
  Map<String, Object?> _slimNetworkStrict(
    Map<String, Object?> p,
    String url,
    bool failed,
    Map<String, Object?> failure,
  ) {
    final uri = Uri.tryParse(url.split('?').first);
    Object? body(String key) =>
        p['${key}Omitted'] == true ? p[key] : _strictPolicy.redactValue(p[key]);
    Map<String, String>? headers(Object? h) => h is Map
        ? _strictPolicy.redactFlatMap({
            for (final MapEntry(:key, :value) in h.entries) '$key': '$value',
          })
        : null;
    return {
      'm': p['method'],
      'u': uri == null
          ? url.split('?').first
          : ThorNetworkCapture.redactUrl(uri, _strictPolicy).toString(),
      's': p['statusCode'],
      'd': p['durationMs'],
      ...failure,
      if (failed || _diagnostic) ...{
        'body': body('responseBody'),
        // El cuerpo cortado lo dice (tope de captura o recorte de la
        // política), también en estricto.
        if (p['responseBodyTruncated'] == true ||
            ThorNetworkCapture.bodyWasCut(body('responseBody')))
          'bt': true,
      },
      if (_diagnostic) ...{
        if (p['requestBody'] != null) 'qb': body('requestBody'),
        if (p['requestBody'] != null &&
            (p['requestBodyTruncated'] == true ||
                ThorNetworkCapture.bodyWasCut(body('requestBody'))))
          'qbt': true,
        if (headers(p['requestHeaders']) case final h?) 'qh': h,
        if (headers(p['responseHeaders']) case final h?) 'rh': h,
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

  void _writeJson(Map<String, Object?> record) {
    final q = ++_seq;
    _line(jsonEncode({...record, 'q': q}), q);
  }

  void _write(List<Object?> record) {
    final q = ++_seq;
    _line(jsonEncode([...record, q]), q);
  }

  void _line(String line, int q) {
    _pendingDisk.add(line);
    if (_config.endpoint != null) _pendingUpload.add((q: q, line: line));
    // En segundo plano no hay "siguiente ciclo" garantizado: el sistema
    // puede matar la app justo después. Lo escrito tras el flush de `paused`
    // (otros observadores, el último evento) sale en un flush corto.
    if (_bgSinceMs != null) _flushSoon();
  }

  /// Espera del flush corto en segundo plano (ver [_flushSoon]).
  @visibleForTesting
  static Duration backgroundFlushDelay = const Duration(milliseconds: 300);
  Timer? _bgFlushTimer;

  void _flushSoon() {
    if (_bgFlushTimer != null || _instance != this) return;
    _bgFlushTimer = Timer(backgroundFlushDelay, () {
      _bgFlushTimer = null;
      if (_instance == this) unawaited(flush());
    });
  }

  late final _lifecycle = _ReplayLifecycle(this);
  int _lastUploadAt = 0;

  Future<void>? _running;
  bool _again = false;
  bool _againUpload = false;

  /// Escribe lo pendiente a disco (registros y bloques nuevos) y, si la
  /// sesión sube y [upload], manda el lote. Un fallo de red lo deja para
  /// después.
  ///
  /// De una en una: si ya hay un flush en curso, este no arranca otro en
  /// paralelo (dos escrituras al mismo archivo salían en desorden y dos
  /// subidas mandaban el mismo lote); pide una pasada más cuando termine
  /// la actual —una subida pedida YA (error, dashboard, "Reportar
  /// problema") no espera al siguiente ciclo— y devuelve el mismo futuro.
  Future<void> flush({bool upload = true}) {
    final running = _running;
    if (running != null) {
      _again = true;
      _againUpload = _againUpload || upload;
      return running;
    }
    // En la zona raíz a propósito: el flush es IO de Thor, no de la app.
    // Fuera de la zona de `Thor.run` sus errores no pasan por los
    // capturadores (un fallo de red del propio replay no se vuelve error de
    // la app), y quien lo dispara desde una zona de prueba con reloj falso
    // no deja la cola de flush colgada de microtareas que nadie bombea.
    final started = Zone.root.run(() => _flushLoop(upload));
    _running = started;
    return started;
  }

  Future<void> _flushLoop(bool upload) async {
    try {
      var up = upload;
      while (true) {
        _again = false;
        _againUpload = false;
        await _flushOnce(upload: up);
        if (!_again) return;
        up = _againUpload;
      }
    } on Object {
      // Disco o red: lo que no salió se reintenta en el siguiente ciclo.
    } finally {
      _running = null;
    }
  }

  Future<void> _flushOnce({required bool upload}) async {
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
      final unsaved = _unsavedBlocks;
      _pendingDisk.clear();
      if (!_diskDisabled) {
        // Un fallo de disco NO debe frenar la subida (los registros van
        // también en `_pendingUpload`) ni salir como error de la app.
        if (await _appendToDisk(file, '${lines.join('\n')}\n')) {
          _savedBlocks.addAll(unsaved);
        }
      }
    } else {
      _pendingDisk.clear();
    }
    if (!upload || !_uploadEnabled || _pendingUpload.isEmpty) return;
    // 429: el servidor pidió esperar.
    if (_retryAt case final at? when _ts < at) return;
    _lastUploadAt = _ts;
    final endpoint = _config.endpoint!;
    final batch = List.of(_pendingUpload);
    final up = await _upload(
      _http ??= HttpClient(),
      endpoint,
      _config.apiKey,
      _core.session.sessionId,
      [for (final r in batch) r.line],
      _blocks,
    );
    switch (up.sent) {
      case _Ok(:final bytes):
        uploadedBytes += bytes;
        _pendingUpload
          ..removeRange(0, batch.length)
          ..insertAll(0, [for (final b in up.unsentBlocks) (q: 0, line: b)]);
        final acked = batch.fold<int>(_ackedSeq, (m, r) => max(m, r.q));
        if (acked > _ackedSeq) {
          _ackedSeq = acked;
          await _saveSent();
        }
      case _Later(:final after):
        if (after != null) _retryAt = _ts + after.inMilliseconds;
      case _Rejected(:final status):
        if (status == 413) {
          // Solo este lote: el resto de la sesión puede caber.
          _pendingUpload.removeRange(0, batch.length);
        } else {
          // Llave o sesión rechazadas: esta sesión ya no sube.
          _uploadEnabled = false;
          _rejected = true;
          _pendingUpload.clear();
          _unmarkEnabled();
        }
    }
  }

  /// Fallos de disco seguidos y apagado del archivo del replay: tras
  /// [_maxDiskFailures] el replay sigue en memoria y subiendo, pero deja de
  /// escribir el archivo (y avisa UNA vez con un error `source: 'thor'`).
  int _diskFailures = 0;
  bool _diskDisabled = false;
  static const _maxDiskFailures = 3;

  /// Añade [text] al archivo; si el directorio desapareció (reinstalación
  /// del build) lo recrea y reintenta una vez. `false` si no se pudo.
  Future<bool> _appendToDisk(File file, String text) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        if (attempt > 0) await file.parent.create(recursive: true);
        await file.writeAsString(text, mode: FileMode.append, flush: true);
        _diskFailures = 0;
        return true;
      } on Object catch (e) {
        if (attempt == 1) {
          if (++_diskFailures >= _maxDiskFailures) {
            _diskDisabled = true;
            _pendingDisk.clear();
            _core.recordInternalError('replay_disk', e);
          }
        }
      }
    }
    return false;
  }

  final Set<String> _savedBlocks = {};
  Iterable<String> get _unsavedBlocks =>
      _blocks.keys.where((h) => !_savedBlocks.contains(h)).toList();

  /// Apaga el replay (tests / logout). Deja el registro de fin
  /// `{"t":"end","reason":…,"ts":…,"bg":…}`: `reason` es `clean` (cierre
  /// normal) o el motivo dado (`renewed`…); `bg` los segundos que la sesión
  /// pasó en segundo plano. Una sesión sin ese registro murió (`killed` /
  /// `crash`: lo anota la recuperación en el siguiente arranque).
  static Future<void> stop({String reason = 'clean'}) async {
    final r = _instance;
    if (r == null) return;
    _instance = null;
    r._writeJson({
      't': 'end',
      'reason': reason,
      'ts': r._ts,
      'bg': (r._bgTotalMs + _openBackgroundMs(r)) ~/ 1000,
      'wall': DateTime.now().toUtc().toIso8601String(),
    });
    r._idleTimer?.cancel();
    r._flushTimer?.cancel();
    r._configTimer?.cancel();
    r._errorFlushTimer?.cancel();
    r._bgFlushTimer?.cancel();
    r._unsubscribe?.call();
    WidgetsBinding.instance.removeObserver(r._lifecycle);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(r._onPointer);
    try {
      await r.flush();
    } finally {
      // Recién ahora (la última subida terminó, bien o mal) la
      // recuperación puede ocuparse de lo que quede en el archivo.
      if (r._file case final file?) _owned.remove(file.path);
    }
  }

  /// Renovación de sesión: apaga el replay vigente (con su última subida,
  /// sin esperar a la red más de [flushTimeout]), corre [between] — que
  /// renueva el núcleo — y vuelve a encender el replay con la MISMA
  /// configuración sobre la sesión nueva. Sin replay encendido solo corre
  /// [between].
  static Future<void> renewAround(
    Future<void> Function() between, {
    Duration flushTimeout = const Duration(seconds: 5),
  }) async {
    final r = _instance;
    final config = r?._config;
    final directory = r?._directory;
    if (r != null) {
      await stop(reason: 'renewed').timeout(flushTimeout, onTimeout: () {});
    }
    await between();
    if (config != null) await start(config, directory: directory);
  }

  /// Milisegundos de un segundo plano que sigue abierto al cerrar.
  static int _openBackgroundMs(ThorReplay r) {
    final since = r._bgSinceMs;
    return since == null ? 0 : r._clock.elapsedMilliseconds - since;
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
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        replay._enterBackground();
        unawaited(replay.flush());
        // Lo que otros observadores escriban tras este (el propio evento
        // `paused`) no espera a un relanzamiento.
        replay._flushSoon();
      case AppLifecycleState.resumed:
        replay._leaveBackground();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
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
