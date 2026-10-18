import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thor/thor.dart';

void main() {
  group('Logs estructurados y Thor.track (núcleo)', () {
    setUp(() async {
      ThorCore.debugReset();
      await ThorCore.init();
    });
    tearDown(ThorCore.debugReset);

    List<ThorEvent> of(ThorEventKind k) => ThorCore.instance!.store.ofKind(k);

    test('log con data: JSON, secretos tapados, resto legible', () {
      ThorCore.instance!.log(
        'cobro',
        data: {
          'orderId': 42,
          'email': 'ana@x.com',
          'password': 'hunter2',
          'nested': {'token': 'abc', 'ok': true},
          'odd': DateTime.utc(2026),
        },
      );
      final data = of(ThorEventKind.log).single.payload['data']! as Map;
      expect(data['orderId'], 42);
      expect(data['email'], 'ana@x.com');
      expect(data['password'], RedactionPolicy.redactedMarker);
      expect((data['nested'] as Map)['token'], RedactionPolicy.redactedMarker);
      expect((data['nested'] as Map)['ok'], true);
      expect(data['odd'], isA<String>());
    });

    test('log sin data no trae la clave; data pesada se descarta', () {
      ThorCore.instance!
        ..log('a')
        ..log('b', data: {'blob': 'x' * 5000});
      final logs = of(ThorEventKind.log);
      expect(logs[0].payload.containsKey('data'), isFalse);
      expect(logs[1].payload['data'], {'_truncated': true});
    });

    test('track: nombre + props sin secretos, tope ~2 KB', () {
      ThorCore.instance!
        ..track('add_to_cart', {'sku': 'A1', 'qty': 2, 'api_key': 'zzz'})
        ..track('sin_props')
        ..track('enorme', {'x': 'y' * 3000});
      final t = of(ThorEventKind.track);
      expect(t[0].payload['name'], 'add_to_cart');
      expect(t[0].payload['props'], {
        'sku': 'A1',
        'qty': 2,
        'api_key': RedactionPolicy.redactedMarker,
      });
      expect(t[1].payload.containsKey('props'), isFalse);
      expect(t[2].payload['props'], {'_truncated': true});
    });

    test('un mapa cíclico no tumba a quien registra', () {
      final cyclic = <String, Object?>{};
      cyclic['self'] = cyclic;
      ThorCore.instance!.track('ciclo', cyclic);
      expect(of(ThorEventKind.track).single.payload['props'], isNotNull);
    });

    test('el narrador cuenta tracks y data de logs', () {
      final core = ThorCore.instance!
        ..track('checkout_ok', {'total': 99})
        ..log('falló cobro', level: ThorLogLevel.error, data: {'code': 'E1'});
      final steps = ThorNarrator.narrate(core.store.timeline());
      expect(steps, contains('1. [+0.0s] ★ checkout_ok {"total":99}'));
      expect(steps, contains('data: {"code":"E1"}'));
    });

    test('track y log con data llegan al journal', () async {
      ThorCore.debugReset();
      final dir = Directory.systemTemp.createTempSync('thor_track');
      addTearDown(() => dir.deleteSync(recursive: true));
      final core = await ThorCore.init(storageDirectory: dir);
      core
        ..track('pagó', {'monto': 10})
        ..log('x', data: {'a': 1});
      await core.dispose();
      final text = dir
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.readAsStringSync())
          .join('\n');
      expect(text, contains('"kind":"track"'));
      expect(text, contains(jsonEncode('pagó')));
      expect(text, contains('"data":{"a":1}'));
    });
  });
}
