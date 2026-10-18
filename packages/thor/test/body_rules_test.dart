import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thor/thor.dart';

void main() {
  group('JsonPath', () {
    final tree = {
      'categories': [
        {
          'name': 'Frutas',
          'quantity': 12,
          'children': [
            {'name': 'Manzanas', 'quantity': 5},
            {'name': 'Peras', 'quantity': 7},
          ],
        },
        {'name': 'Carnes', 'quantity': 3, 'children': <Object?>[]},
      ],
      'total': 15,
    };

    test('raíz, claves, índices y comodines', () {
      expect(JsonPath.parse(r'$.total').eval(tree), [15]);
      expect(JsonPath.parse(r'$.categories[0].name').eval(tree), ['Frutas']);
      expect(JsonPath.parse(r'$.categories[-1].name').eval(tree), ['Carnes']);
      expect(
        JsonPath.parse(r'$.categories[*].name').eval(tree),
        ['Frutas', 'Carnes'],
      );
      expect(JsonPath.parse(r"$['total']").eval(tree), [15]);
      expect(JsonPath.parse(r'$.nada').eval(tree), isEmpty);
    });

    test(r'$..quantity baja a cualquier profundidad', () {
      expect(JsonPath.parse(r'$..quantity').eval(tree), [12, 5, 7, 3]);
    });

    test('resumen numérico y de textos', () {
      expect(
        JsonPath.summarize(JsonPath.parse(r'$..quantity').eval(tree)),
        {
          'n': 4,
          'sum': 27,
          'min': 3,
          'max': 12,
          'values': [12, 5, 7, 3],
        },
      );
      expect(
        JsonPath.summarize(JsonPath.parse(r'$..name').eval(tree))['first'],
        ['Frutas', 'Manzanas', 'Peras', 'Carnes'],
      );
    });

    test('rutas inválidas lanzan al compilar; evaluar no lanza', () {
      expect(() => JsonPath.parse('total'), throwsFormatException);
      expect(() => JsonPath.parse(r'$.a['), throwsFormatException);
      expect(JsonPath.parse(r'$.a.b').eval('texto'), isEmpty);
    });
  });

  group('reglas por endpoint', () {
    late HttpServer server;
    late Uri base;

    setUp(() async {
      ThorCore.debugReset();
      await ThorCore.init();
      ThorNetworkCapture.bodyRules.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((request) async {
        // Un árbol de ~140 KB: muy por encima del tope global de 8 KB.
        final categories = [
          for (var i = 0; i < 1500; i++)
            {
              'id': i,
              'name': 'Categoria numero $i con un texto largo para pesar',
              'quantity': i % 7,
              'access_token': 'secreto-$i',
            },
        ];
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'categories': categories}));
        await request.response.close();
      });
      ThorNetworkCapture.install();
    });

    tearDown(() async {
      ThorNetworkCapture.bodyRules.clear();
      ThorNetworkCapture.uninstall();
      await server.close(force: true);
      ThorCore.debugReset();
    });

    Future<ThorEvent> hit(String path) async {
      final client = HttpClient();
      final request = await client.getUrl(base.replace(path: path));
      final response = await request.close();
      await response.drain<void>();
      client.close();
      return ThorCore.instance!.store.ofKind(ThorEventKind.network).last;
    }

    test('sin regla: cuerpo cortado a 8 KB y marcado, sin extractos', () async {
      final event = await hit('/CategoryTree');
      expect(event.payload['responseBodyTruncated'], isTrue);
      expect(event.payload.containsKey('extracts'), isFalse);
      expect(event.payload['responseBytes'], greaterThan(100000));
    });

    test(r'extracto $..quantity sobre el cuerpo ENTERO, sin retenerlo',
        () async {
      ThorNetworkCapture.bodyRules.add(
        const ThorBodyRule(
          pathPattern: '/CategoryTree',
          extracts: {'quantity': r'$..quantity', 'ids': r'$..id'},
        ),
      );
      final event = await hit('/CategoryTree');
      final x = event.payload['extracts']! as Map;
      final q = x['quantity']! as Map;
      var expected = 0;
      for (var i = 0; i < 1500; i++) {
        expected += i % 7;
      }
      expect(q['n'], 1500, reason: 'vio el árbol completo, no 8 KB');
      expect(q['sum'], expected);
      expect(q['max'], 6);
      expect(q['values']! as List, hasLength(JsonPath.maxSummaryValues));
      // El evento no engorda: el cuerpo sigue acotado y marcado.
      expect(event.payload['responseBodyTruncated'], isTrue);
      expect(
        jsonEncode(event.payload['responseBody']).length,
        lessThan(ThorNetworkCapture.maxBodyBytes * 2),
      );
    });

    test('los extractos salen del cuerpo YA redactado (no filtran secretos)',
        () async {
      ThorNetworkCapture.bodyRules.add(
        const ThorBodyRule(
          pathPattern: '/CategoryTree',
          extracts: {'tokens': r'$..access_token'},
        ),
      );
      final event = await hit('/CategoryTree');
      final text = jsonEncode(event.payload['extracts']);
      expect(text, isNot(contains('secreto-')));
      expect(text, contains(RedactionPolicy.redactedMarker));
    });

    test('maxBytes sube el tope solo para ese endpoint', () async {
      ThorNetworkCapture.bodyRules.add(
        const ThorBodyRule(pathPattern: '/Grande', maxBytes: 64 * 1024),
      );
      final big = await hit('/Grande');
      final small = await hit('/Otro');
      final bigLen = jsonEncode(big.payload['responseBody']).length;
      final smallLen = jsonEncode(small.payload['responseBody']).length;
      expect(bigLen, greaterThan(smallLen * 3));
      expect(big.payload['bodyCap'], 64 * 1024);
      expect(small.payload.containsKey('bodyCap'), isFalse);
      expect(big.payload['responseBodyTruncated'], isTrue);
    });

    test('un JSONPath inválido deja _error, no tumba la captura', () async {
      ThorNetworkCapture.bodyRules.add(
        const ThorBodyRule(
          pathPattern: '/CategoryTree',
          extracts: {'mala': 'sin-dolar'},
        ),
      );
      final event = await hit('/CategoryTree');
      final x = event.payload['extracts']! as Map;
      expect((x['mala']! as Map).containsKey('_error'), isTrue);
    });

    test('cuerpo más grande que extractMaxBytes: error claro', () async {
      ThorNetworkCapture.bodyRules.add(
        const ThorBodyRule(
          pathPattern: '/CategoryTree',
          extracts: {'q': r'$..quantity'},
          extractMaxBytes: 20 * 1024,
        ),
      );
      final event = await hit('/CategoryTree');
      final q = (event.payload['extracts']! as Map)['q']! as Map;
      expect(q['_error'], contains('extractMaxBytes'));
    });
  });
}
