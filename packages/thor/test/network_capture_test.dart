import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thor/thor.dart';

void main() {
  late HttpServer server;
  late Uri base;

  setUp(() async {
    ThorCore.debugReset();
    await ThorCore.init(
      redaction: const RedactionPolicy(
        allowedKeys: {'status', 'message', 'content-type', 'page'},
      ),
    );
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      if (request.uri.path == '/falla') {
        request.response.statusCode = 500;
      }
      request.response.headers.contentType = ContentType.json;
      await request.response.close();
    });
    ThorNetworkCapture.install();
  });

  tearDown(() async {
    ThorNetworkCapture.uninstall();
    await server.close(force: true);
    ThorCore.debugReset();
  });

  List<ThorEvent> networkEvents() =>
      ThorCore.instance!.store.ofKind(ThorEventKind.network);

  Future<void> hit(
    Uri url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
  }) async {
    // HttpClient CRUDO: si esto se captura, dio y http también (todos
    // construyen HttpClient por la misma fábrica interceptada).
    final client = HttpClient();
    final request = await client.openUrl(method, url);
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    final response = await request.close();
    await response.drain<void>();
    client.close();
  }

  test('HttpClient crudo queda capturado con status y duración', () async {
    await hit(base.replace(path: '/ok'));
    final event = networkEvents().single;
    expect(event.payload['method'], 'GET');
    expect(event.payload['statusCode'], 200);
    expect(event.payload['durationMs'], isA<int>());
    expect(event.payload['url'], contains('/ok'));
  });

  test('el header Authorization JAMÁS aparece — ni en headers ni en cURL',
      () async {
    await hit(
      base.replace(path: '/ok'),
      headers: {'Authorization': 'Bearer super-secreto'},
    );
    final event = networkEvents().single;
    expect(event.toJson().toString(), isNot(contains('super-secreto')));
    final curl = event.payload['curl']! as String;
    expect(curl, contains('curl -X GET'));
    expect(curl, contains(RedactionPolicy.redactedMarker));
  });

  test('query params fuera de allowlist se redactan en la URL grabada',
      () async {
    await hit(
      base.replace(
        path: '/ok',
        queryParameters: {'page': '2', 'telefono': '6641234567'},
      ),
    );
    final url = networkEvents().single.payload['url']! as String;
    expect(url, contains('page=2'));
    expect(url, isNot(contains('6641234567')));
  });

  test('cuerpo JSON de petición se captura redactado estructuralmente',
      () async {
    await hit(
      base.replace(path: '/ok'),
      method: 'POST',
      body: jsonEncode({'message': 'hola', 'password': 'hunter2'}),
    );
    final event = networkEvents().single;
    final body = event.payload['requestBody']! as Map;
    expect(body['message'], 'hola');
    expect(event.toJson().toString(), isNot(contains('hunter2')));
  });

  test('status 500 queda con su código (la petición no es "error", es dato)',
      () async {
    await hit(base.replace(path: '/falla'));
    expect(networkEvents().single.payload['statusCode'], 500);
  });

  test('fallo de conexión graba el evento con error y sin response',
      () async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 200);
    // Puerto cerrado: nadie escucha.
    try {
      final request =
          await client.openUrl('GET', Uri.parse('http://127.0.0.1:1'));
      await request.close();
      fail('debió lanzar');
    } on Object {
      // esperado
    }
    client.close();
    final event = networkEvents().single;
    expect(event.payload['error'], isNotNull);
    expect(event.payload.containsKey('statusCode'), isFalse);
  });

  test('uninstall restaura el mundo: sin captura después', () async {
    ThorNetworkCapture.uninstall();
    await hit(base.replace(path: '/ok'));
    expect(networkEvents(), isEmpty);
    ThorNetworkCapture.install(); // para el tearDown simétrico
  });
}
