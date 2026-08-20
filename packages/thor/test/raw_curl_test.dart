import 'dart:io';

import 'package:test/test.dart';
import 'package:thor/thor.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late Directory tmp;

  setUp(() async {
    ThorCore.debugReset();
    RawNetworkStore.clear();
    tmp = await Directory.systemTemp.createTemp('thor_raw_curl');
    await ThorCore.init(storageDirectory: tmp);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      await request.response.close();
    });
    ThorNetworkCapture.install();
  });

  tearDown(() async {
    ThorNetworkCapture.uninstall();
    RawNetworkStore.clear();
    await server.close(force: true);
    ThorCore.debugReset();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<int> hitWithSecret() async {
    final client = HttpClient();
    final request = await client.postUrl(base.replace(path: '/orders'));
    request.headers
      ..set('Authorization', 'Bearer token-super-secreto')
      ..contentType = ContentType.json;
    request.write('{"password":"hunter2","note":"con \'apostrofo\'"}');
    final response = await request.close();
    await response.drain<void>();
    client.close();
    return ThorCore.instance!.store
        .ofKind(ThorEventKind.network)
        .last
        .seq;
  }

  test('el cURL crudo es reproducible: token y body reales, con escape',
      () async {
    final seq = await hitWithSecret();
    final raw = RawNetworkStore.forSeq(seq);
    expect(raw, isNotNull);
    expect(raw, contains('Bearer token-super-secreto'));
    expect(raw, contains('hunter2'));
    // Apóstrofo del body escapado a la POSIX: no rompe el comando.
    expect(raw, contains(r"'\''apostrofo'\''"));
    expect(raw, startsWith('curl -X POST'));
  });

  test('el EVENTO sigue redactado aunque exista el crudo', () async {
    final seq = await hitWithSecret();
    final event = ThorCore.instance!.store
        .ofKind(ThorEventKind.network)
        .lastWhere((e) => e.seq == seq);
    final serialized = event.toJson().toString();
    expect(serialized, isNot(contains('token-super-secreto')));
    expect(serialized, isNot(contains('hunter2')));
  });

  test('el secreto JAMÁS toca el journal en disco', () async {
    await hitWithSecret();
    await ThorCore.instance!.journal!.flush();
    final content =
        await ThorCore.instance!.journal!.file.readAsString();
    expect(content, contains('"kind":"network"'));
    expect(content, isNot(contains('token-super-secreto')));
    expect(content, isNot(contains('hunter2')));
  });

  test('captureRawCurl=false: ni siquiera en memoria', () async {
    ThorNetworkCapture.captureRawCurl = false;
    addTearDown(() => ThorNetworkCapture.captureRawCurl = true);
    final seq = await hitWithSecret();
    expect(RawNetworkStore.forSeq(seq), isNull);
    expect(RawNetworkStore.length, 0);
  });

  test('cuota del store: los viejos se expulsan', () {
    for (var i = 0; i < RawNetworkStore.capacity + 10; i++) {
      RawNetworkStore.put(i, 'curl-$i');
    }
    expect(RawNetworkStore.length, RawNetworkStore.capacity);
    expect(RawNetworkStore.forSeq(0), isNull); // el más viejo se fue
    expect(
      RawNetworkStore.forSeq(RawNetworkStore.capacity + 9),
      isNotNull,
    );
  });

  test('dispose limpia los cURLs crudos (mueren con la sesión)', () async {
    final seq = await hitWithSecret();
    expect(RawNetworkStore.forSeq(seq), isNotNull);
    await ThorCore.instance!.dispose();
    expect(RawNetworkStore.length, 0);
  });
}
