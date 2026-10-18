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

  test('un frame de 2 s o más emite freeze con pantalla y hora de inicio', () {
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

  test('1.9 s no es freeze (sí jank congelado)', () {
    PerformanceCapture.handleFrameTotals(
      [const Duration(milliseconds: 1900)],
    );
    expect(perf().map((e) => e.payload['kind']), ['jank']);
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
