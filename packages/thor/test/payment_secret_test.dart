import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thor/thor.dart';

/// Los códigos de pago (QR/token de cobro) son secretos: por clave y por
/// regla de endpoint (`monedero/pagar` los devuelve en un genérico `data`).
void main() {
  const m = RedactionPolicy.redactedMarker;
  const policy = RedactionPolicy.secretsOnly();

  group('claves de código de pago', () {
    test('qr, qrCode, codigoPago, paymentCode, otp y cvv son secretos', () {
      for (final k in [
        'qr',
        'QR',
        'qrCode',
        'qr_code',
        'qrToken',
        'codigoPago',
        'codigo_pago',
        'codigoQr',
        'paymentCode',
        'payment_token',
        'codigoDePago',
        'qrPayment',
        'codePayment',
        'otp',
        'cvv',
      ]) {
        expect(RedactionPolicy.isSecretKey(k), isTrue, reason: k);
      }
    });

    test('claves parecidas que no son secreto siguen pasando', () {
      for (final k in ['qty', 'query', 'qrs_total', 'payment_method', 'data']) {
        expect(RedactionPolicy.isSecretKey(k), isFalse, reason: k);
      }
    });

    test('redactValue las tapa a cualquier profundidad', () {
      final out = policy.redactValue({
        'ok': true,
        'pago': {'qrCode': '123-ABC', 'codigoPago': '9', 'monto': 50},
      })! as Map;
      expect(out['pago'], {'qrCode': m, 'codigoPago': m, 'monto': 50});
    });
  });

  group('reglas por endpoint', () {
    test('monedero/pagar: data tapado en la respuesta, resto intacto', () {
      final out = policy.redactEndpointBody(
        '/api/monedero/pagar',
        {'code': 0, 'message': 'ok', 'data': '1234567-998877'},
      )! as Map;
      expect(out, {'code': 0, 'message': 'ok', 'data': m});
    });

    test('otro endpoint: misma instancia, nada se toca', () {
      final body = {'data': 'x'};
      expect(policy.redactEndpointBody('/api/carrito', body), same(body));
    });

    test('data anidado y en listas', () {
      final out = policy.redactEndpointBody(
        '/v1/monedero-beneficio/pagar',
        {
          'r': [
            {'data': 'a', 'n': 1},
          ],
        },
      );
      expect(out, {
        'r': [
          {'data': m, 'n': 1},
        ],
      });
    });

    test('cuerpo cortado (texto) también se tapa', () {
      final out = policy.redactEndpointBody(
        '/monedero/pagar',
        '{"code":0,"data":"1234567-998877-aaaaaaaaaaaa',
      )! as String;
      expect(out, isNot(contains('998877')));
      expect(out, contains('"code":0'));
    });

    test('regla propia, y keys vacío oculta el cuerpo entero', () {
      const custom = RedactionPolicy.secretsOnly(
        secretEndpoints: [
          ...RedactionPolicy.defaultSecretEndpoints,
          SecretEndpointRule(r'/ticket/\d+/codigo$', keys: {'valor'}),
          SecretEndpointRule('/wallet/seed'),
        ],
      );
      expect(
        custom.redactEndpointBody('/ticket/7/codigo', {'valor': 'z', 'a': 1}),
        {'valor': m, 'a': 1},
      );
      expect(custom.redactEndpointBody('/wallet/seed', {'a': 1}), m);
      expect(
        custom.redactEndpointBody('/monedero/pagar', {'data': 1}),
        {'data': m},
      );
    });

    test('lista vacía desactiva las reglas por defecto', () {
      const off = RedactionPolicy.secretsOnly(secretEndpoints: []);
      expect(
        off.redactEndpointBody('/monedero/pagar', {'data': 'q'}),
        {'data': 'q'},
      );
    });

    test('regex inválida no lanza', () {
      const bad = RedactionPolicy.secretsOnly(
        secretEndpoints: [
          SecretEndpointRule('(', keys: {'x'}),
        ],
      );
      expect(bad.redactEndpointBody('/a', {'x': 1}), {'x': 1});
    });
  });

  group('captura de red', () {
    late HttpServer server;
    late Uri base;

    setUp(() async {
      ThorCore.debugReset();
      await ThorCore.init();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path == '/big') {
          request.response.write(jsonEncode({'items': 'x' * 20000}));
        } else {
          request.response
              .write(jsonEncode({'code': 0, 'data': '1234567-QR998877'}));
        }
        await request.response.close();
      });
      ThorNetworkCapture.install();
    });

    tearDown(() async {
      ThorNetworkCapture.uninstall();
      await server.close(force: true);
      ThorCore.debugReset();
    });

    Future<void> hit(String path) async {
      final client = HttpClient();
      final request = await client.openUrl('POST', base.replace(path: path));
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({'idCliente': 7, 'qrCode': 'REQ-QR-1'}));
      final response = await request.close();
      await response.drain<void>();
      client.close();
    }

    test('monedero/pagar: el código no toca el evento ni el cURL', () async {
      await hit('/monedero/pagar');
      final event =
          ThorCore.instance!.store.ofKind(ThorEventKind.network).single;
      final text = jsonEncode(event.payload);
      expect(text, isNot(contains('QR998877')));
      expect(text, isNot(contains('REQ-QR-1')));
      expect((event.payload['responseBody']! as Map)['code'], 0);
      expect((event.payload['responseBody']! as Map)['data'], m);
    });

    test('otro endpoint: data pasa (solo secretos)', () async {
      await hit('/carrito');
      final event =
          ThorCore.instance!.store.ofKind(ThorEventKind.network).single;
      expect(
        (event.payload['responseBody']! as Map)['data'],
        '1234567-QR998877',
      );
    });

    test('cuerpo cortado lleva responseBodyTruncated', () async {
      await hit('/big');
      final event =
          ThorCore.instance!.store.ofKind(ThorEventKind.network).single;
      expect(event.payload['responseBodyTruncated'], isTrue);
    });
  });
}
