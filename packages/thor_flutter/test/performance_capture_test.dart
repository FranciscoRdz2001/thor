import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

void main() {
  setUp(() async {
    ThorCore.debugReset();
    await ThorCore.init();
  });

  tearDown(ThorCore.debugReset);

  List<ThorEvent> perf() =>
      ThorCore.instance!.store.ofKind(ThorEventKind.performance);

  test('lote de frames sanos NO genera evento (anti-ruido)', () {
    PerformanceCapture.handleFrameTotals(
      List.filled(60, const Duration(milliseconds: 10)),
    );
    expect(perf(), isEmpty);
  });

  test('1-2 frames lentos aislados tampoco (bajo el mínimo)', () {
    PerformanceCapture.handleFrameTotals([
      const Duration(milliseconds: 40),
      const Duration(milliseconds: 45),
      const Duration(milliseconds: 10),
    ]);
    expect(perf(), isEmpty);
  });

  test('ráfaga de jank genera UN evento con conteo y peor frame', () {
    PerformanceCapture.handleFrameTotals([
      const Duration(milliseconds: 40),
      const Duration(milliseconds: 90),
      const Duration(milliseconds: 55),
      const Duration(milliseconds: 12),
    ]);
    final event = perf().single;
    expect(event.payload['kind'], 'jank');
    expect(event.payload['slow'], 3);
    expect(event.payload['worstMs'], 90);
    expect(event.payload['frozen'], 0);
    expect(event.payload['frames'], 4);
  });

  test('un solo frame CONGELADO se reporta aunque no haya ráfaga', () {
    PerformanceCapture.handleFrameTotals([
      const Duration(milliseconds: 900),
    ]);
    final event = perf().single;
    expect(event.payload['frozen'], 1);
    expect(event.payload['worstMs'], 900);
  });

  test('un frame de 1 s o más emite freeze con pantalla y hora de inicio', () {
    // La navegación ocurrió ANTES de que empezara el frame congelado.
    withClock(
      Clock.fixed(DateTime.now().toUtc().subtract(const Duration(minutes: 1))),
      () => ThorCore.instance!.recorder.record(ThorEventKind.navigation, {
        'action': 'push',
        'to': 'CartPage',
      }),
    );
    PerformanceCapture.handleFrameTotals(
      [
        const Duration(milliseconds: 10),
        const Duration(milliseconds: 6700),
      ],
      startAgoUs: (i) => 8000000,
    );
    final freeze = perf().firstWhere((e) => e.payload['kind'] == 'freeze');
    expect(freeze.payload['ms'], 6700);
    expect(freeze.payload['screen'], 'CartPage');
    final start = DateTime.parse(freeze.payload['startAt']! as String);
    expect(start.isUtc, isTrue);
    expect(
      DateTime.now().toUtc().difference(start).inMilliseconds,
      inInclusiveRange(7900, 9000),
    );
    // Y el lote de jank sigue contándolo como congelado.
    final jank = perf().firstWhere((e) => e.payload['kind'] == 'jank');
    expect(jank.payload['frozen'], 1);
  });

  test('0.9 s no es freeze (sí jank congelado); 1.9 s sí', () {
    PerformanceCapture.handleFrameTotals(
      [const Duration(milliseconds: 900)],
    );
    expect(perf().map((e) => e.payload['kind']), ['jank']);
    PerformanceCapture.handleFrameTotals(
      [const Duration(milliseconds: 1900)],
    );
    expect(perf().map((e) => e.payload['kind']), ['jank', 'jank', 'freeze']);
  });

  group('freeze como problema (T-N11) y ANR sin watchdog (T-N08)', () {
    List<ThorEvent> errors() =>
        ThorCore.instance!.store.ofKind(ThorEventKind.error);

    test('un freeze deja UN error source freeze con pantalla y ms', () {
      ThorCore.instance!.setScreen('CartPage');
      PerformanceCapture.handleFrameTotals([
        const Duration(milliseconds: 1500),
        const Duration(milliseconds: 4400),
      ]);
      final problem = errors().single.payload;
      expect(problem['source'], 'freeze');
      expect(problem['fatal'], false);
      expect(problem['message'], contains('CartPage'));
    });

    test('varios freeze seguidos son un solo problema (no inunda)', () {
      PerformanceCapture.handleFrameTotals([
        const Duration(milliseconds: 1200),
        const Duration(milliseconds: 1300),
        const Duration(milliseconds: 1400),
      ]);
      expect(errors(), hasLength(1));
    });

    test('sin watchdog (debug) un frame de 2 s o más también es anr', () {
      PerformanceCapture.handleFrameTotals([
        const Duration(milliseconds: 4400),
      ]);
      final anr = perf().firstWhere((e) => e.payload['kind'] == 'anr');
      expect(anr.payload['ms'], 4400);
      expect(anr.payload['via'], 'frame');
    });

    test('un freeze de 1.2 s es problema pero no anr', () {
      PerformanceCapture.handleFrameTotals([
        const Duration(milliseconds: 1200),
      ]);
      expect(errors(), hasLength(1));
      expect(perf().where((e) => e.payload['kind'] == 'anr'), isEmpty);
    });
  });

  test('dos congeladas en un lote son dos eventos freeze', () {
    PerformanceCapture.handleFrameTotals([
      const Duration(milliseconds: 2500),
      const Duration(milliseconds: 3000),
    ]);
    expect(perf().where((e) => e.payload['kind'] == 'freeze'), hasLength(2));
  });

  test('jank lleva hora de inicio del primer frame lento', () {
    PerformanceCapture.handleFrameTotals(
      [
        const Duration(milliseconds: 40),
        const Duration(milliseconds: 90),
        const Duration(milliseconds: 55),
      ],
      startAgoUs: (i) => 500000 - i * 100000,
    );
    final jank = perf().single;
    final start = DateTime.parse(jank.payload['startAt']! as String);
    expect(
      DateTime.now().toUtc().difference(start).inMilliseconds,
      inInclusiveRange(450, 1500),
    );
  });

  test('Thor apagado: no revienta', () {
    ThorCore.debugReset();
    expect(
      () => PerformanceCapture.handleFrameTotals(
        [const Duration(milliseconds: 900)],
      ),
      returnsNormally,
    );
  });
}
