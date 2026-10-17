import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:clock/clock.dart';
import 'package:meta/meta.dart';

import 'package:thor/src/model/event.dart';
import 'package:thor/src/network/raw_network_store.dart';
import 'package:thor/src/redaction/redaction_policy.dart';
import 'package:thor/src/thor_core.dart';
import 'package:thor/src/util/origin.dart';

/// Captura universal de red vía [HttpOverrides.global].
///
/// En Dart móvil/desktop TODO cliente HTTP (dio, package:http, HttpClient
/// crudo) termina construyendo un `HttpClient` de `dart:io`, y
/// `HttpOverrides.global` intercepta esa construcción. **Una instalación
/// captura todo el tráfico de la app sin registrar interceptores.**
/// (Excepción: Flutter Web no tiene dart:io — ahí se necesita adaptador.)
///
/// Compone con overrides previos (proxies corporativos, pinning): el
/// cliente interno se pide al override anterior si existía.
class ThorNetworkCapture {
  ThorNetworkCapture._();

  static bool _installed = false;

  /// Máximo de bytes de cuerpo (petición y respuesta) retenidos por evento.
  static const int maxBodyBytes = 8 * 1024;

  /// Si además del cURL redactado se retiene el CRUDO (reproducible) en el
  /// [RawNetworkStore] — solo memoria, jamás persistido. Apágalo si ni
  /// siquiera en RAM quieres tokens retenidos.
  static bool captureRawCurl = true;

  /// Prefijos de URL que NO se graban: el transporte del propio Thor
  /// (subida del replay) — sin esto cada subida se graba a sí misma.
  static final Set<String> ignoredPrefixes = {};

  static bool _ignored(Uri url) {
    if (ignoredPrefixes.isEmpty) return false;
    final s = url.toString();
    return ignoredPrefixes.any(s.startsWith);
  }

  /// La URL tal como la graba Thor (query por allowlist, ruta sin datos
  /// personales). Expuesta para tests.
  @visibleForTesting
  static Uri redactUrl(Uri uri, RedactionPolicy redaction) =>
      _SpyRequest._redactUrl(uri, redaction);

  /// Instala la captura. Idempotente.
  static void install() {
    if (_installed) return;
    _installed = true;
    HttpOverrides.global = _ThorHttpOverrides(HttpOverrides.current);
  }

  /// Desinstala (tests).
  static void uninstall() {
    if (!_installed) return;
    _installed = false;
    final current = HttpOverrides.current;
    HttpOverrides.global =
        current is _ThorHttpOverrides ? current.previous : null;
  }
}

class _ThorHttpOverrides extends HttpOverrides {
  _ThorHttpOverrides(this.previous);

  /// Override que existía antes de instalar Thor (se respeta su cliente).
  final HttpOverrides? previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner =
        previous?.createHttpClient(context) ?? super.createHttpClient(context);
    return _SpyHttpClient(inner);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      previous?.findProxyFromEnvironment(url, environment) ??
      super.findProxyFromEnvironment(url, environment);
}

/// HttpClient espía: delega todo al [inner] y envuelve las peticiones.
class _SpyHttpClient implements HttpClient {
  _SpyHttpClient(this.inner);

  final HttpClient inner;

  @override
  Future<HttpClientRequest> open(
    String method,
    String host,
    int port,
    String path,
  ) =>
      openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (ThorNetworkCapture._ignored(url)) return inner.openUrl(method, url);
    // El origen se resuelve AQUÍ, en el disparo. `currentOrigin` atraviesa
    // los gaps asíncronos (app → bloc → dio) cuando la zona captura la
    // cadena — sin ella, `StackTrace.current` solo trae frames de dio.
    final origin = currentOrigin(skipFrames: 2);
    final startedAt = clock.now();
    try {
      final request = await inner.openUrl(method, url);
      return _SpyRequest(request, origin: origin);
    } on Object catch (error) {
      // La conexión puede morir ANTES de que exista la petición
      // (connection refused, DNS): también es un evento de red.
      final core = ThorCore.instance;
      core?.recorder.record(
        ThorEventKind.network,
        {
          'method': method,
          'url': _SpyRequest._redactUrl(url, core.redaction).toString(),
          'durationMs': clock.now().difference(startedAt).inMilliseconds,
          'error': error.runtimeType.toString(),
          'errorMessage': error.toString(),
        },
        origin: origin,
      );
      rethrow;
    }
  }

  // ── Métodos de conveniencia: todos canalizan por openUrl (espiados) ──
  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  // ── Delegación 1:1 del resto de la interfaz ──
  @override
  bool get autoUncompress => inner.autoUncompress;
  @override
  set autoUncompress(bool value) => inner.autoUncompress = value;
  @override
  Duration? get connectionTimeout => inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => inner.connectionTimeout = value;
  @override
  Duration get idleTimeout => inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => inner.idleTimeout = value;
  @override
  int? get maxConnectionsPerHost => inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => inner.maxConnectionsPerHost = value;
  @override
  String? get userAgent => inner.userAgent;
  @override
  set userAgent(String? value) => inner.userAgent = value;
  @override
  set authenticate(
    Future<bool> Function(Uri url, String scheme, String? realm)? f,
  ) =>
      inner.authenticate = f;
  @override
  set authenticateProxy(
    Future<bool> Function(String host, int port, String scheme, String? realm)?
        f,
  ) =>
      inner.authenticateProxy = f;
  @override
  set badCertificateCallback(
    bool Function(X509Certificate cert, String host, int port)? callback,
  ) =>
      inner.badCertificateCallback = callback;
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(
      Uri url,
      String? proxyHost,
      int? proxyPort,
    )? f,
  ) =>
      inner.connectionFactory = f;
  @override
  set findProxy(String Function(Uri url)? f) => inner.findProxy = f;
  @override
  set keyLog(void Function(String line)? callback) => inner.keyLog = callback;
  @override
  void addCredentials(
    Uri url,
    String realm,
    HttpClientCredentials credentials,
  ) =>
      inner.addCredentials(url, realm, credentials);
  @override
  void addProxyCredentials(
    String host,
    int port,
    String realm,
    HttpClientCredentials credentials,
  ) =>
      inner.addProxyCredentials(host, port, realm, credentials);
  @override
  void close({bool force = false}) => inner.close(force: force);
}

/// Envoltura de la petición: acumula los bytes del cuerpo de salida (hasta
/// el tope) y al cerrar cronometra y espía la respuesta.
class _SpyRequest implements HttpClientRequest {
  _SpyRequest(this.inner, {this.origin}) : startedAt = clock.now();

  final HttpClientRequest inner;
  final String? origin;
  final DateTime startedAt;

  final BytesBuilder _requestBody = BytesBuilder(copy: false);
  bool _recorded = false;

  void _tee(List<int> chunk) {
    final remaining = ThorNetworkCapture.maxBodyBytes - _requestBody.length;
    if (remaining <= 0) return;
    _requestBody.add(
      chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
    );
  }

  @override
  void add(List<int> data) {
    _tee(data);
    inner.add(data);
  }

  @override
  void write(Object? object) {
    final text = object?.toString() ?? '';
    _tee(utf8.encode(text));
    inner.write(object);
  }

  @override
  void writeln([Object? object = '']) => write('$object\n');

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  Future<void> addStream(Stream<List<int>> stream) => inner.addStream(
        stream.map((chunk) {
          _tee(chunk);
          return chunk;
        }),
      );

  @override
  Future<HttpClientResponse> close() async {
    try {
      final response = await inner.close();
      return _spyResponse(response);
    } on Object catch (error) {
      _recordFailure(error);
      rethrow;
    }
  }

  @override
  Future<HttpClientResponse> get done async {
    try {
      final response = await inner.done;
      return _spyResponse(response);
    } on Object catch (error) {
      _recordFailure(error);
      rethrow;
    }
  }

  HttpClientResponse _spyResponse(HttpClientResponse response) {
    if (_recorded) return response;
    _recorded = true;
    return _SpyResponse(
      response,
      onDone: (bodyBytes, {required truncated}) => _record(
        response: response,
        responseBody: bodyBytes,
        responseTruncated: truncated,
      ),
    );
  }

  void _recordFailure(Object error) {
    if (_recorded) return;
    _recorded = true;
    _record(error: error);
  }

  void _record({
    HttpClientResponse? response,
    List<int>? responseBody,
    bool responseTruncated = false,
    Object? error,
  }) {
    final core = ThorCore.instance;
    if (core == null) return;
    final redaction = core.redaction;
    final elapsed = clock.now().difference(startedAt);

    final requestHeaders = _headersToMap(inner.headers);
    final payload = <String, Object?>{
      'method': inner.method,
      'url': _redactUrl(inner.uri, redaction).toString(),
      'durationMs': elapsed.inMilliseconds,
      'requestHeaders': redaction.redactFlatMap(requestHeaders),
      'requestBytes': _requestBody.length,
      if (_requestBody.isNotEmpty)
        'requestBody': _decodeBody(
          _requestBody.toBytes(),
          inner.headers.contentType?.mimeType,
          redaction,
        ),
      if (response != null) ...{
        'statusCode': response.statusCode,
        'responseHeaders':
            redaction.redactFlatMap(_headersToMap(response.headers)),
        'responseBytes': response.contentLength,
        if (responseBody != null && responseBody.isNotEmpty)
          'responseBody': _decodeBody(
            responseBody,
            response.headers.contentType?.mimeType,
            redaction,
          ),
        if (responseTruncated) 'responseBodyTruncated': true,
      },
      if (error != null) ...{
        'error': error.runtimeType.toString(),
        'errorMessage': error.toString(),
      },
      'curl': _buildRedactedCurl(redaction, requestHeaders),
    };

    final event =
        core.recorder.record(ThorEventKind.network, payload, origin: origin);

    // cURL CRUDO (reproducible): SOLO memoria, jamás en el payload — el
    // payload viaja al journal/reportes y un token no debe tocar disco.
    if (event != null && ThorNetworkCapture.captureRawCurl) {
      RawNetworkStore.put(event.seq, _buildRawCurl(requestHeaders));
    }
  }

  /// cURL con headers/body/query YA redactados — para tickets y chats sin
  /// fugar el token. Documenta; para reproducir está el crudo del
  /// [RawNetworkStore].
  String _buildRedactedCurl(
    RedactionPolicy redaction,
    Map<String, String> headers,
  ) {
    final parts = ['curl', '-X', inner.method];
    redaction.redactFlatMap(headers).forEach(
          (k, v) => parts.add("-H ${_sq('$k: $v')}"),
        );
    if (_requestBody.isNotEmpty) {
      final body = _decodeBody(
        _requestBody.toBytes(),
        inner.headers.contentType?.mimeType,
        redaction,
      );
      if (body is String) parts.add('-d ${_sq(body)}');
      if (body is Map || body is List) {
        parts.add('-d ${_sq(jsonEncode(body))}');
      }
    }
    parts.add(_sq(_redactUrl(inner.uri, redaction).toString()));
    return parts.join(' ');
  }

  /// cURL crudo, ejecutable tal cual (headers reales, body real, URL real).
  String _buildRawCurl(Map<String, String> headers) {
    final parts = ['curl', '-X', inner.method];
    headers.forEach((k, v) => parts.add('-H ${_sq('$k: $v')}'));
    if (_requestBody.isNotEmpty) {
      final body = utf8.decode(_requestBody.toBytes(), allowMalformed: true);
      parts.add('-d ${_sq(body)}');
    }
    parts.add(_sq(inner.uri.toString()));
    return parts.join(' ');
  }

  /// Envuelve en comillas simples con escape POSIX (`'` → `'\''`) — un body
  /// con apóstrofos rompía el comando generado.
  static String _sq(String value) => "'${value.replaceAll("'", r"'\''")}'";

  /// Redacta la URL: query por allowlist y, en la RUTA, los segmentos que
  /// suelen ser datos de la persona. Bug real (una app de producción):
  /// `/cache/profile/<email>` viajaba tal cual porque solo se limpiaba la
  /// query. Los reemplazos son marcadores legibles que mantienen la URL
  /// válida y agrupable (`/profile/:email`).
  static Uri _redactUrl(Uri uri, RedactionPolicy redaction) {
    final segments = uri.pathSegments;
    final cleanPath = segments.any((s) => redactPathSegment(s) != s);
    if (uri.queryParameters.isEmpty && !cleanPath) return uri;
    return uri.replace(
      pathSegments: cleanPath ? segments.map(redactPathSegment) : null,
      queryParameters: uri.queryParameters.isEmpty
          ? null
          : {
              for (final MapEntry(:key, :value) in uri.queryParameters.entries)
                key: redaction.isKeyAllowed(key)
                    ? value
                    : RedactionPolicy.redactedMarker,
            },
    );
  }

  /// Un segmento de ruta con forma de dato personal → marcador (regla de
  /// [RedactionPolicy.personalMarker], compartida con los labels de taps
  /// del replay). Lo demás pasa igual.
  static String redactPathSegment(String segment) =>
      RedactionPolicy.personalMarker(Uri.decodeComponent(segment)) ?? segment;

  static Map<String, String> _headersToMap(HttpHeaders headers) {
    final map = <String, String>{};
    headers.forEach((name, values) => map[name] = values.join(', '));
    return map;
  }

  /// Decodifica un cuerpo si su content-type está permitido; si no, solo
  /// deja constancia del tamaño. JSON se redacta estructuralmente.
  static Object? _decodeBody(
    List<int> bytes,
    String? mimeType,
    RedactionPolicy redaction,
  ) {
    final mime = mimeType ?? 'application/octet-stream';
    if (!redaction.allowedBodyContentTypes.contains(mime)) {
      return '<omitido: ${bytes.length} bytes, $mime>';
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    if (mime == 'application/json') {
      try {
        return redaction.redactValue(jsonDecode(text));
      } on FormatException {
        return redaction.redactValue(text);
      }
    }
    return redaction.redactValue(text);
  }

  // ── Delegación 1:1 del resto de HttpClientRequest ──
  @override
  bool get bufferOutput => inner.bufferOutput;
  @override
  set bufferOutput(bool value) => inner.bufferOutput = value;
  @override
  int get contentLength => inner.contentLength;
  @override
  set contentLength(int value) => inner.contentLength = value;
  @override
  Encoding get encoding => inner.encoding;
  @override
  set encoding(Encoding value) => inner.encoding = value;
  @override
  bool get followRedirects => inner.followRedirects;
  @override
  set followRedirects(bool value) => inner.followRedirects = value;
  @override
  int get maxRedirects => inner.maxRedirects;
  @override
  set maxRedirects(int value) => inner.maxRedirects = value;
  @override
  bool get persistentConnection => inner.persistentConnection;
  @override
  set persistentConnection(bool value) => inner.persistentConnection = value;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) =>
      inner.abort(exception, stackTrace);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      inner.addError(error, stackTrace);
  @override
  HttpConnectionInfo? get connectionInfo => inner.connectionInfo;
  @override
  List<Cookie> get cookies => inner.cookies;
  @override
  Future<void> flush() => inner.flush();
  @override
  HttpHeaders get headers => inner.headers;
  @override
  String get method => inner.method;
  @override
  Uri get uri => inner.uri;
}

/// Envoltura de la respuesta: cuenta y retiene (hasta el tope) los bytes del
/// cuerpo sin alterar el stream que ve la app.
class _SpyResponse extends Stream<List<int>> implements HttpClientResponse {
  _SpyResponse(this.inner, {required this.onDone});

  final HttpClientResponse inner;
  final void Function(List<int> body, {required bool truncated}) onDone;

  final BytesBuilder _body = BytesBuilder(copy: false);
  bool _truncated = false;
  bool _notified = false;

  /// El tap va como TRANSFORMADOR, no como handlers de la suscripción:
  /// un consumidor puede reemplazar sus handlers después de suscribirse
  /// (`drain()` hace exactamente eso vía `asFuture`, que pisa `onDone`) y
  /// eso borraría la notificación. `handleDone` del transformador corre en
  /// la tubería, intocable para el consumidor. (Bug real cazado por test.)
  late final Stream<List<int>> _tapped = inner.transform(
    StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (chunk, sink) {
        final remaining = ThorNetworkCapture.maxBodyBytes - _body.length;
        if (remaining > 0) {
          _body.add(
            chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
          );
          if (chunk.length > remaining) _truncated = true;
        } else {
          _truncated = true;
        }
        sink.add(chunk);
      },
      handleError: (error, stack, sink) {
        _notify();
        sink.addError(error, stack);
      },
      handleDone: (sink) {
        _notify();
        sink.close();
      },
    ),
  );

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _tapped.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  void _notify() {
    if (_notified) return;
    _notified = true;
    onDone(_body.toBytes(), truncated: _truncated);
  }

  // ── Delegación 1:1 ──
  @override
  X509Certificate? get certificate => inner.certificate;
  @override
  HttpClientResponseCompressionState get compressionState =>
      inner.compressionState;
  @override
  HttpConnectionInfo? get connectionInfo => inner.connectionInfo;
  @override
  int get contentLength => inner.contentLength;
  @override
  List<Cookie> get cookies => inner.cookies;
  @override
  Future<Socket> detachSocket() => inner.detachSocket();
  @override
  HttpHeaders get headers => inner.headers;
  @override
  bool get isRedirect => inner.isRedirect;
  @override
  bool get persistentConnection => inner.persistentConnection;
  @override
  String get reasonPhrase => inner.reasonPhrase;
  @override
  Future<HttpClientResponse> redirect([
    String? method,
    Uri? url,
    bool? followLoops,
  ]) =>
      inner.redirect(method, url, followLoops);
  @override
  List<RedirectInfo> get redirects => inner.redirects;
  @override
  int get statusCode => inner.statusCode;
}
