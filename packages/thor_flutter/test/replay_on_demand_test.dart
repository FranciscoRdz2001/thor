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

  Future<void> start({bool config = true, ThorPrivacy? privacy}) =>
      ThorReplay.start(
        ThorReplayConfig(
          privacy: privacy,
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
    // Por defecto una exitosa ya lleva su detalle (sin modo diagnóstico).
    final net = dash.events('network').single;
    expect(net['body'], {'total': 99});
    expect(net['qh'], {'authorization': RedactionPolicy.redactedMarker});
    expect(
      ThorNetworkCapture.ignoredPrefixes,
      containsAll([dash.configUrl.toString(), dash.ingestUrl.toString()]),
    );
  });

  test('strict without detail: a success carries no body nor headers',
      () async {
    dash.answer = jsonEncode({'upload': true, 'detail': false, 'until': null});
    await start(privacy: ThorPrivacy.strict);
    _networkEvent(status: 200);
    await _until(() => dash.ingested.isNotEmpty, reason: 'subida');
    await ThorReplay.stop();
    final net = dash.events('network').single;
    expect(net.keys, unorderedEquals(['m', 'u', 's', 'd']));
    expect(net['u'], 'https://api.example.com/cart');
  });

  test('default detail: logs at all levels, body cap raised to 8 KB', () async {
    dash.answer = jsonEncode({'upload': true, 'detail': true, 'until': null});
    await start();
    await _until(() => ThorReplay.instance!.diagnostic, reason: 'detail');
    final big = 'x' * 6000;
    ThorCore.instance!.recorder.record(ThorEventKind.network, {
      'method': 'GET',
      'url': 'https://api.example.com/big',
      'durationMs': 3,
      'statusCode': 200,
      'responseBody': big,
      'responseBytes': 6000,
    });
    Thor.log('detalle ana@x.com', level: ThorLogLevel.debug);
    await ThorReplay.stop();

    final net = dash.events('network').single;
    expect(net['body'], big, reason: '6000 > 4096 pero < 8 KB');
    expect(net.containsKey('bt'), isFalse);
    final log = dash.events('log').single;
    expect(log['lv'], 'debug');
    expect(log['m'], 'detalle ana@x.com');
  });

  test(
      'strict detail: successful requests keep redacted bodies, logs at all '
      'levels', () async {
    dash.answer = jsonEncode({'upload': true, 'detail': true, 'until': null});
    await start(privacy: ThorPrivacy.strict);
    await _until(() => ThorReplay.instance!.diagnostic, reason: 'detail');
    _networkEvent(status: 200);
    Thor.log('detalle ana@x.com', level: ThorLogLevel.debug);
    await ThorReplay.stop();

    final net = dash.events('network').single;
    expect(net['s'], 200);
    // Re-redactado con RedactionPolicy.strict(): solo claves estructurales.
    const m = RedactionPolicy.redactedMarker;
    expect(net['body'], {'total': 99});
    expect(net['qb'], {'sku': m});
    expect(net['qh'], {'authorization': m});
    expect(net['rh'], {'content-type': 'application/json'});
    expect(net['u'], 'https://api.example.com/cart');
    final log = dash.events('log').single;
    expect(log['lv'], 'debug');
    expect(jsonEncode(dash.ingested), isNot(contains('ana@x.com')));
  });

  test(
      'requestUpload: uploads now with a report mark, reason without '
      'secrets', () async {
    await start(config: false);
    expect(onMarker(), isFalse);
    await ThorReplay.requestUpload(
      reason: 'no carga, soy ana@x.com password=hunter2',
    );

    expect(dash.configCalls, isEmpty);
    expect(dash.ingested.first, contains('"t":"meta"'));
    final report = dash.events('log').single;
    expect(report['l'], 'report');
    expect(
      report['reason'],
      'no carga, soy ana@x.com password=${RedactionPolicy.redactedMarker}',
    );
    expect(onMarker(), isTrue);
  });

  test('strict: requestUpload reason scrubbed of personal data', () async {
    await start(config: false, privacy: ThorPrivacy.strict);
    await ThorReplay.requestUpload(reason: 'no carga, soy ana@x.com');
    expect(dash.events('log').single['reason'], 'no carga, soy :email');
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

  void recordError() =>
      ThorCore.instance!.recorder.record(ThorEventKind.error, {
        'type': 'StateError',
        'message': 'Bad state: cliente ana@x.com tel 55 1234 5678 token=abc',
        'source': 'zone',
      });

  test('an uploaded error message keeps its data, loses its secrets', () async {
    await start(config: false);
    recordError();
    await _until(() => dash.events('error').isNotEmpty, reason: 'error');
    const m = RedactionPolicy.redactedMarker;
    expect(
      dash.events('error').single['msg'],
      'Bad state: cliente ana@x.com tel 55 1234 5678 token=$m',
    );
  });

  test('strict: an uploaded error message is scrubbed like logs', () async {
    await start(config: false, privacy: ThorPrivacy.strict);
    recordError();
    await _until(() => dash.events('error').isNotEmpty, reason: 'error');
    const m = RedactionPolicy.redactedMarker;
    expect(
      dash.events('error').single['msg'],
      'Bad state: cliente :email tel :n token=$m',
    );
  });

  test(
      'network contract: every request with full detail; truncation, sizes, '
      'failures; images never', () async {
    await start(config: false);
    final core = ThorCore.instance!;
    final bigBody = {
      'items': [for (var i = 0; i < 400; i++) 'producto-$i'],
    };
    core.recorder
      ..record(ThorEventKind.network, {
        'method': 'GET',
        'url': 'https://api.example.com/clientes/ana@mail.com?tienda=431',
        'durationMs': 40,
        'statusCode': 200,
        'requestHeaders': {'x-app': '3.2'},
        'requestBytes': 0,
        'responseHeaders': {'content-type': 'application/json'},
        'responseBody': bigBody,
        'responseBytes': 20000,
        'responseBodyTruncated': true,
      })
      ..record(ThorEventKind.network, {
        'method': 'GET',
        'url': 'https://cdn.example.com/p/123',
        'durationMs': 5,
        'statusCode': 200,
        'responseHeaders': {'Content-Type': 'image/webp'},
        'responseBody': '<omitido: 9000 bytes, image/webp>',
        'responseBodyOmitted': true,
      })
      ..record(ThorEventKind.network, {
        'method': 'GET',
        'url': 'https://api.example.com/logo.png',
        'durationMs': 5,
        'statusCode': 200,
      })
      ..record(ThorEventKind.network, {
        'method': 'POST',
        'url': 'https://api.example.com/upload',
        'durationMs': 5,
        'statusCode': 201,
        'requestBody': '<omitido: 512 bytes, application/pdf>',
        'requestBodyOmitted': true,
        'requestBytes': 512,
      })
      ..record(
        ThorEventKind.network,
        {
          'method': 'POST',
          'url': 'https://api.example.com/pagar',
          'durationMs': 90,
          'statusCode': 502,
          'requestBody': {'monto': 99},
          'responseBody': {'message': 'gateway'},
        },
        origin: 'lib/pago.dart:42',
      );
    await ThorReplay.stop();
    final nets = dash.events('network');
    expect(nets, hasLength(3), reason: 'imágenes fuera');

    final ok = nets[0];
    expect(ok['u'], 'https://api.example.com/clientes/ana@mail.com?tienda=431');
    expect(ok['qh'], {'x-app': '3.2'});
    expect(ok['rh'], {'content-type': 'application/json'});
    expect(ok['body'], isA<String>(), reason: 'cortado: viaja como texto');
    expect((ok['body']! as String).length, 4096);
    expect(ok['bt'], isTrue);
    expect(ok['rn'], 20000);
    expect(ok.containsKey('err'), isFalse);
    expect(ok.containsKey('qn'), isFalse, reason: 'sin cuerpo de petición');

    final pdf = nets[1];
    expect(pdf.containsKey('qb'), isFalse, reason: 'binario: solo tamaño');
    expect(pdf['qn'], 512);

    final failed = nets[2];
    expect(failed['s'], 502);
    expect(failed['err'], 'HTTP 502');
    expect(failed['at'], 'lib/pago.dart:42');
    expect(failed['qb'], {'monto': 99});
    expect(failed['body'], {'message': 'gateway'});
  });

  test('an error after uploading already started goes up right away', () async {
    // Caso real: la app tiene un 404 en el arranque que enciende la
    // subida; un crash minutos después no debe esperar al siguiente ciclo
    // (uploadEvery) — si la app muere, se pierde hasta el próximo arranque.
    await start(config: false);
    _networkEvent(status: 404);
    await _until(() => dash.ingested.isNotEmpty, reason: 'subida por 404');

    ThorCore.instance!.recorder.record(ThorEventKind.error, {
      'source': 'zone',
      'type': 'StateError',
      'message': 'Bad state: boom',
    });
    await _until(
      () => dash.events('error').isNotEmpty,
      reason: 'el error sube sin esperar a uploadEvery',
    );
    expect(dash.events('error').single['msg'], 'Bad state: boom');
  });
}
