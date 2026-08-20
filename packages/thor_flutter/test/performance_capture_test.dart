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
    expect(event.payload['slowFrames'], 3);
    expect(event.payload['worstMs'], 90);
    expect(event.payload['frozenFrames'], 0);
  });

  test('un solo frame CONGELADO se reporta aunque no haya ráfaga', () {
    PerformanceCapture.handleFrameTotals([
      const Duration(milliseconds: 900),
    ]);
    final event = perf().single;
    expect(event.payload['frozenFrames'], 1);
    expect(event.payload['worstMs'], 900);
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
