import 'package:clock/clock.dart';
import 'package:test/test.dart';
import 'package:thor/thor.dart';

void main() {
  group('Conectividad inferida de las peticiones', () {
    late DateTime now;

    setUp(() async {
      ThorCore.debugReset();
      await ThorCore.init();
      now = DateTime.utc(2026);
    });
    tearDown(ThorCore.debugReset);

    void fail(String host, {String msg = 'Failed host lookup', String? err}) =>
        withClock(Clock(() => now), () {
          ThorCore.instance!.recorder.record(ThorEventKind.network, {
            'url': 'https://$host/x',
            'error': err ?? 'SocketException',
            'errorMessage': 'SocketException: $msg',
          });
        });

    void ok() => ThorCore.instance!.recorder.record(ThorEventKind.network, {
          'url': 'https://api.a.com/x',
          'statusCode': 200,
        });

    List<Object?> signals() => ThorCore.instance!.store
        .ofKind(ThorEventKind.environment)
        .where((e) => e.payload['signal'] == 'connectivity')
        .map((e) => e.payload['online'])
        .toList();

    test('un solo fallo DNS no es offline', () {
      fail('api.a.com');
      expect(signals(), isEmpty);
    });

    test('dos hosts distintos fallando = offline; una respuesta = online', () {
      fail('api.a.com');
      fail('cdn.b.com');
      fail('api.a.com');
      ok();
      ok();
      expect(signals(), [false, true]);
    });

    test('tres fallos del mismo host = offline', () {
      fail('api.a.com');
      fail('api.a.com');
      expect(signals(), isEmpty);
      fail('api.a.com');
      expect(signals(), [false]);
    });

    test('connection refused y timeouts no cuentan (servidor caído)', () {
      for (var i = 0; i < 5; i++) {
        fail('a.com', msg: 'Connection refused');
        fail('b.com', err: 'TimeoutException');
      }
      expect(signals(), isEmpty);
    });

    test('fallos viejos fuera de la ventana no se acumulan', () {
      fail('a.com');
      now = now.add(const Duration(seconds: 30));
      fail('b.com');
      expect(signals(), isEmpty);
    });

    test('el narrador y el diff entienden la señal', () {
      ThorCore.instance!.recorder.record(
        ThorEventKind.navigation,
        {'action': 'push', 'to': 'A'},
      );
      fail('a.com');
      fail('b.com');
      ok();
      final steps = ThorNarrator.narrate(ThorCore.instance!.store.timeline());
      expect(steps, contains('Sin conexión'));
      expect(steps, contains('Conexión restablecida'));
    });
  });
}
