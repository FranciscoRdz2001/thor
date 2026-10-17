import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thor/thor.dart';

/// Default de Thor: SOLO se tapan secretos. Emails, ids, nombres, rutas y
/// headers normales pasan tal cual — sin ellos no se puede depurar un
/// servicio. `RedactionPolicy.strict()` sigue disponible como opt-in.
void main() {
  const m = RedactionPolicy.redactedMarker;
  const policy = RedactionPolicy.secretsOnly();

  group('RedactionPolicy.secretsOnly', () {
    test('headers: pasan todos menos los de secreto', () {
      expect(
        policy.redactFlatMap({
          'Authorization': 'Bearer abc',
          'Proxy-Authorization': 'Basic xyz',
          'Cookie': 'sid=1',
          'set-cookie': 'sid=2',
          'X-Api-Key': 'k',
          'x-auth-token': 't',
          'X-VTEX-API-AppKey': 'vtexappkey-x',
          'X-VTEX-API-AppToken': 'vt',
          'x-request-id': 'req-42',
          'x-user-email': 'ana@mail.com',
          'content-type': 'application/json',
        }),
        {
          'Authorization': m,
          'Proxy-Authorization': m,
          'Cookie': m,
          'set-cookie': m,
          'X-Api-Key': m,
          'x-auth-token': m,
          'X-VTEX-API-AppKey': m,
          'X-VTEX-API-AppToken': m,
          'x-request-id': 'req-42',
          'x-user-email': 'ana@mail.com',
          'content-type': 'application/json',
        },
      );
    });

    test('JSON: secretos tapados a cualquier profundidad, lo demás tal cual',
        () {
      final out = policy.redactValue({
        'email': 'ana@mail.com',
        'id': 1737154,
        'nombre': 'Ana Pérez',
        'telefono': '55 1234 5678',
        'direccion': {'calle': 'Reforma 1', 'cp': '06600'},
        'password': 'hunter2',
        'session': {
          'access_token': 'eyJ.a.b',
          'refreshToken': 'r1',
          'id_token': 'i1',
          'jwt': 'j1',
          'expires_in': 3600,
          'token_type': 'Bearer',
        },
        'pago': [
          {'cardNumber': '4111111111111111', 'cvv': '123', 'pin': '0000'},
          {'last4': '1111', 'clientSecret': 'cs'},
        ],
        'nota': 'mandé Bearer abcdefgh12345',
      });
      expect(out, {
        'email': 'ana@mail.com',
        'id': 1737154,
        'nombre': 'Ana Pérez',
        'telefono': '55 1234 5678',
        'direccion': {'calle': 'Reforma 1', 'cp': '06600'},
        'password': m,
        'session': {
          'access_token': m,
          'refreshToken': m,
          'id_token': m,
          'jwt': m,
          'expires_in': 3600,
          'token_type': 'Bearer',
        },
        'pago': [
          {'cardNumber': m, 'cvv': m, 'pin': m},
          {'last4': '1111', 'clientSecret': m},
        ],
        'nota': 'mandé Bearer $m',
      });
    });

    test('texto libre: solo secretos (scrub), emails y números legibles', () {
      expect(
        policy.scrub('ana@x.com pidió 10293847 con token=abc'),
        'ana@x.com pidió 10293847 con token=$m',
      );
      // Estricto conserva la limpieza de forma personal.
      expect(
        const RedactionPolicy.strict().scrub('ana@x.com pidió 10293847'),
        ':email pidió :n',
      );
    });

    test('cuerpos de texto se capturan; binarios no', () {
      for (final mime in [
        'application/json',
        'application/problem+json',
        'text/plain',
        'text/html',
        'application/xml',
        'application/x-www-form-urlencoded',
      ]) {
        expect(policy.capturesBody(mime), isTrue, reason: mime);
      }
      for (final mime in ['image/png', 'application/pdf', null]) {
        expect(policy.capturesBody(mime), isFalse, reason: '$mime');
      }
      expect(
        const RedactionPolicy.strict().capturesBody('text/plain'),
        isFalse,
      );
    });

    test('URL: ruta intacta, query completa salvo secretos', () {
      String clean(String url) =>
          ThorNetworkCapture.redactUrl(Uri.parse(url), policy).toString();
      const plain = 'https://x.io/cache/profile/mango1251@yahoo.com/orders/'
          '1737154?email=ana%40mail.com&page=2&page=3';
      expect(clean(plain), plain);
      final withSecret = clean(
        'https://x.io/u/ana@mail.com?api_key=AIzaXYZ&q=leche&access_token=t',
      );
      expect(withSecret, contains('/u/ana@mail.com'));
      expect(withSecret, contains('q=leche'));
      expect(withSecret, isNot(contains('AIzaXYZ')));
      expect(withSecret, isNot(contains('access_token=t')));
    });
  });

  // Intentos de colar un secreto por el default (revisión adversarial).
  group('secretsOnly: fugas cerradas', () {
    test('JSON dentro de un string JSON (print de jsonEncode)', () {
      final out = policy.scrub(
        jsonEncode({
          'query': 'mutation { login(password: "hunter2") }',
          'data': jsonEncode({'token': 'tk-123', 'sku': 'A1'}),
        }),
      );
      expect(out, isNot(contains('hunter2')));
      expect(out, isNot(contains('tk-123')));
      expect(out, contains('A1'));
    });

    test('valor cortado por el tope (comilla sin cerrar)', () {
      expect(
        policy.scrub('{"user":"ana","password":"hunt'),
        '{"user":"ana","password":"$m"',
      );
    });

    test('Cookie con varias cookies: caen todas', () {
      expect(policy.scrub('cookie: sid=abc; theme=x'), 'cookie: $m');
      expect(
        policy.scrub('{cookie: sid=abc; csrf=zz, accept: */*}'),
        '{cookie: $m, accept: */*}',
      );
    });

    test('JWT suelto, contraseña en URL y tarjeta en texto libre', () {
      const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.'
          'dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U';
      expect(policy.scrub('token guardado $jwt ok'), 'token guardado $m ok');
      expect(
        policy.scrub('SocketException: https://ana:pw123@h.io/x'),
        'SocketException: https://ana:$m@h.io/x',
      );
      expect(
        policy.scrub('pagó con 4111 1111 1111 1111 el 55 1234 5678'),
        'pagó con $m el 55 1234 5678',
      );
      // Ni ids largos ni epochs en ms (no empiezan como tarjeta / no
      // pasan Luhn).
      expect(
        policy.scrub('ts=1697568000000 pedido 4111111111111112'),
        'ts=1697568000000 pedido 4111111111111112',
      );
    });

    test('claves de secreto con otros nombres', () {
      expect(
        policy.redactValue({
          'pass': 'a',
          'otpCode': '1',
          'securityCode': '2',
          'ccNumber': '3',
          'credit_card': '4',
          'aws_access_key_id': '5',
          'X-Amz-Signature': '6',
          'JSESSIONID': '7',
          'auth': {'method': 'google'},
        }),
        {
          'pass': m,
          'otpCode': m,
          'securityCode': m,
          'ccNumber': m,
          'credit_card': m,
          'aws_access_key_id': m,
          'X-Amz-Signature': m,
          'JSESSIONID': m,
          // Un objeto `auth` conserva su forma; sus secretos caen por clave.
          'auth': {'method': 'google'},
        },
      );
      expect(
        policy
            .redactFlatMap({
              'Authentication': 'abc',
              'Ocp-Apim-Subscription-Key': 'k',
              'x-session-id': 's',
            })
            .values
            .toSet(),
        {m},
      );
    });

    test('URL: fragmento OAuth, usuario:contraseña y JWT en la ruta', () {
      String clean(String url) =>
          ThorNetworkCapture.redactUrl(Uri.parse(url), policy).toString();
      final oauth = clean(
        'https://ana:pw123@h.io/cb?x=1#access_token=at-9&state=st&id_token=it',
      );
      for (final secret in ['pw123', 'at-9', 'id_token=it']) {
        expect(oauth, isNot(contains(secret)), reason: secret);
      }
      expect(oauth, contains('ana:'));
      expect(oauth, contains('state=st'));
      expect(
        clean('https://h.io/reset/eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc'),
        isNot(contains('eyJ')),
      );
      // Sin secretos la URL no se toca (orden, repetidos, codificación).
      const plain = 'https://h.io/a?b=1&a=2&b=3&q=leche%20light';
      expect(clean(plain), plain);
    });
  });

  group('captura de red con la política por defecto', () {
    late HttpServer server;
    late Uri base;

    setUp(() async {
      ThorCore.debugReset();
      await ThorCore.init(); // default = secretsOnly
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((request) async {
        final res = request.response;
        switch (request.uri.path) {
          case '/grande':
            res.headers.contentType = ContentType.json;
            res.write(
              jsonEncode({
                'items': [
                  for (var i = 0; i < 2000; i++) {'id': i, 'nombre': 'x$i'},
                ],
              }),
            );
          case '/png':
            res.headers.contentType = ContentType('image', 'png');
            res.add(List.filled(300, 7));
          default:
            res.headers
              ..contentType = ContentType.json
              ..set('x-request-id', 'req-42')
              ..set('set-cookie', 'sid=secreto-de-sesion');
            res.write(
              jsonEncode({
                'cliente': {'email': 'ana@mail.com', 'id': 1737154},
                'refresh_token': 'rt-secreto',
              }),
            );
        }
        await res.close();
      });
      ThorNetworkCapture.install();
    });

    tearDown(() async {
      ThorNetworkCapture.uninstall();
      await server.close(force: true);
      ThorCore.debugReset();
    });

    Future<Map<String, Object?>> hit(
      Uri url, {
      String method = 'GET',
      Map<String, String> headers = const {},
      String? body,
      ContentType? contentType,
    }) async {
      final client = HttpClient();
      final request = await client.openUrl(method, url);
      headers.forEach(request.headers.set);
      if (contentType != null) request.headers.contentType = contentType;
      if (body != null) request.write(body);
      final response = await request.close();
      await response.drain<void>();
      client.close();
      return ThorCore.instance!.store
          .ofKind(ThorEventKind.network)
          .last
          .payload;
    }

    test(
        'éxito con detalle: URL completa, headers, cuerpos; solo secretos '
        'tapados', () async {
      final p = await hit(
        base.replace(
          path: '/clientes/ana@mail.com',
          queryParameters: {'tienda': '431', 'token': 'tk-secreto'},
        ),
        method: 'POST',
        headers: {
          'Authorization': 'Bearer super-secreto-123',
          'x-app-version': '3.2.1',
        },
        contentType: ContentType.json,
        body: jsonEncode({
          'usuario': {'email': 'ana@mail.com', 'password': 'hunter2'},
          'pedido': 10293847,
        }),
      );
      final all = jsonEncode(p);
      for (final secret in [
        'super-secreto-123',
        'tk-secreto',
        'hunter2',
        'rt-secreto',
        'secreto-de-sesion',
      ]) {
        expect(all, isNot(contains(secret)), reason: secret);
      }
      expect(p['url'], contains('/clientes/ana@mail.com'));
      expect(p['url'], contains('tienda=431'));
      // El marcador se lee tal cual, no `%E2%96%88…`.
      expect(p['url'], contains('token=$m'));
      expect(p['curl'], contains('token=$m'));
      expect((p['requestHeaders']! as Map)['x-app-version'], '3.2.1');
      expect((p['responseHeaders']! as Map)['x-request-id'], 'req-42');
      expect(p['requestBody'], {
        'usuario': {'email': 'ana@mail.com', 'password': m},
        'pedido': 10293847,
      });
      expect(p['responseBody'], {
        'cliente': {'email': 'ana@mail.com', 'id': 1737154},
        'refresh_token': m,
      });
      // El cURL redactado tampoco fuga, pero sí documenta.
      expect(p['curl'], contains('x-app-version: 3.2.1'));
      expect(p['curl'], isNot(contains('super-secreto-123')));
    });

    test(
        'JSON mandado como text/plain se lee como JSON y se redacta por '
        'clave', () async {
      final p = await hit(
        base.replace(path: '/ok'),
        method: 'POST',
        contentType: ContentType.text,
        body: '{"pin": "0000", "sku": "A1"}',
      );
      expect(p['requestBody'], {'pin': m, 'sku': 'A1'});
    });

    test('formulario: secretos fuera del texto', () async {
      final p = await hit(
        base.replace(path: '/ok'),
        method: 'POST',
        contentType: ContentType('application', 'x-www-form-urlencoded'),
        body: 'username=ana%40mail.com&password=hunter2&grant_type=password',
      );
      expect(
        p['requestBody'],
        'username=ana%40mail.com&password=$m&grant_type=password',
      );
    });

    test('cuerpo grande: se marca el corte y queda el tamaño real', () async {
      final p = await hit(base.replace(path: '/grande'));
      expect(p['responseBodyTruncated'], isTrue);
      expect(p['responseBytes'], greaterThan(ThorNetworkCapture.maxBodyBytes));
      // Cortado, no es JSON válido: viaja como texto (sin secretos).
      expect(p['responseBody'], isA<String>());
      expect(
        (p['responseBody']! as String).length,
        lessThanOrEqualTo(ThorNetworkCapture.maxBodyBytes),
      );
    });

    test('petición grande: tamaño real y corte marcados', () async {
      final big = jsonEncode({'blob': 'x' * 20000});
      final p = await hit(
        base.replace(path: '/ok'),
        method: 'POST',
        contentType: ContentType.json,
        body: big,
      );
      expect(p['requestBytes'], big.length);
      expect(p['requestBodyTruncated'], isTrue);
    });

    test('binario: solo el tamaño, jamás el contenido', () async {
      final p = await hit(base.replace(path: '/png'));
      expect(p['responseBodyOmitted'], isTrue);
      expect(p['responseBody'], startsWith('<omitido: 300 bytes'));
      expect(p['responseBytes'], 300);
    });
  });
}
