import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

/// Servidor local con las dos rutas del dashboard: `/api/replay-config`
/// (contesta [answer]) y `/api/ingest` (guarda lo que llega).
class _Dash {
  late HttpServer server;
  final configCalls = <Map<String, Object?>>[];
  final configKeys = <String?>[];
  final ingested = <String>[];
  int configStatus = 200;
  String answer = jsonEncode({'upload': false, 'detail': false, 'until': null});

  Uri get configUrl =>
      Uri.parse('http://127.0.0.1:${server.port}/api/replay-config');
  Uri get ingestUrl => Uri.parse('http://127.0.0.1:${server.port}/api/ingest');

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final bytes = await req.expand((c) => c).toList();
      if (req.uri.path == '/api/replay-config') {
        configKeys.add(req.headers.value('x-thor-key'));
        configCalls.add(
          (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>(),
        );
        req.response
          ..statusCode = configStatus
          ..write(answer);
      } else {
        ingested.addAll(
          const LineSplitter().convert(utf8.decode(gzip.decode(bytes))),
        );
        req.response.write(jsonEncode({'missing': <String>[]}));
      }
      await req.response.close();
    });
  }

  List<Map<String, Object?>> events(String kind) => [
        for (final line in ingested)
          if (jsonDecode(line) case final Map<String, Object?> m
              when m['t'] == 'ev' && m['k'] == kind)
            (m['p']! as Map).cast<String, Object?>(),
      ];
}

/// Espera (con tiempo real) a que [cond] se cumpla.
Future<void> _until(bool Function() cond, {String? reason}) async {
  final watch = Stopwatch()..start();
  while (!cond()) {
    if (watch.elapsed > const Duration(seconds: 5)) {
      fail('timeout: ${reason ?? 'condición'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void _networkEvent({required int status}) {
  ThorCore.instance!.recorder.record(ThorEventKind.network, {
    'method': 'POST',
    'url': 'https://api.example.com/cart?id=1',
    'durationMs': 12,
    'statusCode': status,
    'requestHeaders': {'authorization': RedactionPolicy.redactedMarker},
    'requestBody': {'sku': 'A1'},
    'responseHeaders': {'content-type': 'application/json'},
    'responseBody': {'total': 99},
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _Dash dash;
  final debounce = ThorReplay.configDebounce;

  setUp(() async {
    // El binding de test cambia HttpClient por uno falso que contesta 400:
    // aquí se quiere el servidor local de verdad.
    HttpOverrides.global = null;
    ThorReplay.configDebounce = const Duration(milliseconds: 50);
    dir = Directory.systemTemp.createTempSync('thor_on_demand');
    dash = _Dash();
    await dash.start();
    await ThorCore.init();
  });

  tearDown(() async {
    await ThorReplay.stop();
    ThorCore.debugReset();
    ThorReplay.configDebounce = debounce;
    await dash.server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  Future<void> start({bool config = true}) => ThorReplay.start(
        ThorReplayConfig(
          endpoint: dash.ingestUrl,
          configEndpoint: config ? dash.configUrl : null,
          apiKey: 'app:0123456789abcdef',
          // Fuera de la muestra: solo sube si el dashboard lo pide.
          sampleRate: 0,
        ),
        directory: dir,
      );

  bool onMarker() => dir.listSync().any((f) => f.path.endsWith('.on'));

  test('config says upload: the whole session uploads, marked .on', () async {
    dash.answer = jsonEncode({'upload': true, 'detail': false, 'until': null});
    await start();
    _networkEvent(status: 200);
    await _until(() => dash.ingested.isNotEmpty, reason: 'subida');

    final call = dash.configCalls.single;
    expect(call['sid'], ThorCore.instance!.session.sessionId);
    expect(call['iid'], ThorCore.instance!.session.installId);
    expect(call.containsKey('uid'), isTrue);
    expect(call['uid'], isNull);
    expect(dash.configKeys.single, 'app:0123456789abcdef');
    // Completa desde el inicio: el meta viaja.
    expect(dash.ingested.first, contains('"t":"meta"'));
    expect(onMarker(), isTrue);
    await ThorReplay.stop();
    // Sin modo diagnóstico, una exitosa no lleva cuerpo ni headers.
    final net = dash.events('network').single;
    expect(net.keys, isNot(contains('body')));
    expect(net.keys, isNot(contains('qh')));
    expect(
      ThorNetworkCapture.ignoredPrefixes,
      containsAll([dash.configUrl.toString(), dash.ingestUrl.toString()]),
    );
  });

  test('detail: successful requests keep redacted bodies, logs at all levels',
      () async {
    dash.answer = jsonEncode({'upload': true, 'detail': true, 'until': null});
    await start();
    await _until(() => ThorReplay.instance!.diagnostic, reason: 'detail');
    _networkEvent(status: 200);
    Thor.log('detalle ana@x.com', level: ThorLogLevel.debug);
    await ThorReplay.stop();

    final net = dash.events('network').single;
    expect(net['s'], 200);
    expect(net['body'], {'total': 99});
    expect(net['qb'], {'sku': 'A1'});
    expect(net['qh'], {'authorization': RedactionPolicy.redactedMarker});
    expect(net['rh'], {'content-type': 'application/json'});
    expect(net['u'], 'https://api.example.com/cart');
    final log = dash.events('log').single;
    expect(log['lv'], 'debug');
    expect(jsonEncode(dash.ingested), isNot(contains('ana@x.com')));
  });

  test('requestUpload: uploads now with a report mark, reason scrubbed',
      () async {
    await start(config: false);
    expect(onMarker(), isFalse);
    await ThorReplay.requestUpload(reason: 'no carga, soy ana@x.com');

    expect(dash.configCalls, isEmpty);
    expect(dash.ingested.first, contains('"t":"meta"'));
    final report = dash.events('log').single;
    expect(report['l'], 'report');
    expect(report['reason'], 'no carga, soy :email');
    expect(onMarker(), isTrue);
  });

  test('requestUpload without replay is a no-op', () async {
    await ThorReplay.requestUpload(reason: 'x');
    expect(ThorReplay.instance, isNull);
  });

  test('config failure (500, garbage, no server) changes nothing', () async {
    dash
      ..configStatus = 500
      ..answer = 'no es json';
    await start();
    await _until(() => dash.configCalls.isNotEmpty, reason: 'config');
    ThorCore.instance!.setUser('u1');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await ThorReplay.stop();
    expect(dash.configCalls, hasLength(2));
    expect(dash.ingested, isEmpty, reason: 'fuera de la muestra, sin error');
    expect(onMarker(), isFalse);
    final file = dir.listSync().whereType<File>().single;
    expect(file.readAsStringSync(), contains('"t":"user"'));

    // Servidor caído: tampoco rompe nada.
    ThorCore.debugReset();
    await ThorCore.init();
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    await ThorReplay.start(
      ThorReplayConfig(
        endpoint: dash.ingestUrl,
        configEndpoint: Uri.parse('http://127.0.0.1:$port/api/replay-config'),
        sampleRate: 0,
      ),
      directory: dir,
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(ThorReplay.instance, isNotNull);
    await ThorReplay.stop();
    expect(dash.ingested, isEmpty);
  });

  test('a user change asks again, once per user (debounced)', () async {
    await start();
    await _until(() => dash.configCalls.isNotEmpty, reason: 'arranque');
    final core = ThorCore.instance!
      ..setUser('u1')
      ..setUser('u1', props: {'email': 'ana@x.com'});
    await _until(() => dash.configCalls.length == 2, reason: 'u1');
    // Mismo usuario con otros props: no vuelve a preguntar.
    core.setUser('u1', props: {'email': 'ana@x.com', 'cart': 3});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(dash.configCalls, hasLength(2));
    // La ráfaga del login se pregunta una vez, con lo último.
    expect(dash.configCalls[1]['uid'], 'u1');
    expect(dash.configCalls[1]['props'], {'email': 'ana@x.com'});
  });

  test('an uploaded error message is scrubbed like logs', () async {
    await start(config: false);
    ThorCore.instance!.recorder.record(ThorEventKind.error, {
      'type': 'StateError',
      'message': 'Bad state: cliente ana@x.com tel 55 1234 5678 token=abc',
      'source': 'zone',
    });
    await _until(() => dash.events('error').isNotEmpty, reason: 'error');
    const m = RedactionPolicy.redactedMarker;
    expect(
      dash.events('error').single['msg'],
      'Bad state: cliente :email tel :n token=$m',
    );
  });
}
