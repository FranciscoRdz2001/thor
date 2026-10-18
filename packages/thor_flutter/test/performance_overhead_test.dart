import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

/// Benchmark del costo de la captura de rendimiento. Imprime los números
/// (corre con `flutter test test/performance_overhead_test.dart`) y pone
/// techos muy holgados para que solo una regresión grande lo rompa.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    ThorCore.debugReset();
    await ThorCore.init();
  });

  tearDown(() {
    AnrWatchdog.stop();
    PerformanceCapture.uninstall();
    ThorCore.debugReset();
  });

  test('costo por frame: onFrame (screen_load) y lote sano de 60 frames', () {
    const n = 1000000;
    PerformanceCapture.attach();
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      PerformanceCapture.onFrame();
    }
    sw.stop();
    final nsPerFrame = sw.elapsedMicroseconds * 1000 / n;

    final healthy = List.filled(60, const Duration(milliseconds: 8));
    const batches = 100000;
    final sw2 = Stopwatch()..start();
    for (var i = 0; i < batches; i++) {
      PerformanceCapture.handleFrameTotals(healthy);
    }
    sw2.stop();
    final nsPerBatch = sw2.elapsedMicroseconds * 1000 / batches;

    // ignore: avoid_print, salida del benchmark.
    print('BENCH onFrame: ${nsPerFrame.toStringAsFixed(1)} ns/frame; '
        'lote sano (60 frames): ${nsPerBatch.toStringAsFixed(0)} ns/lote '
        '(${(nsPerBatch / 60).toStringAsFixed(1)} ns/frame)');
    // Una lectura de reloj + dos asignaciones: debe ser ínfimo.
    expect(nsPerFrame, lessThan(2000));
    expect(nsPerBatch / 60, lessThan(2000));
  });

  test('watchdog de ANR: throughput de la UI isolate con y sin él', () async {
    // Trabajo en rodajas de ~1 ms cediendo al event loop (como una app
    // ocupada); se cuentan las rodajas completadas en 2 s.
    Future<int> slices() async {
      final end = Stopwatch()..start();
      var count = 0;
      var acc = 0;
      while (end.elapsedMilliseconds < 2000) {
        final slice = Stopwatch()..start();
        while (slice.elapsedMicroseconds < 1000) {
          acc += count;
        }
        count++;
        await Future<void>.delayed(Duration.zero);
      }
      return count + (acc & 0);
    }

    await slices(); // calentamiento
    final without = await slices();

    await AnrWatchdog.start(force: true); // umbral y cadencia por defecto
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final withDog = await slices();

    final delta = (without - withDog) / without * 100;
    final falsePositives = ThorCore.instance!.store
        .ofKind(ThorEventKind.performance)
        .where((e) => e.payload['kind'] == 'anr');
    // ignore: avoid_print, salida del benchmark.
    print('BENCH ANR watchdog (umbral 2 s, ping/500 ms): '
        'sin=$without rodajas/2s, con=$withDog rodajas/2s '
        '(${delta.toStringAsFixed(2)}% menos); '
        'falsos positivos: ${falsePositives.length}');
    expect(falsePositives, isEmpty);
    // Ruido de medición incluido: nunca debe costar más de un 10 %.
    expect(delta, lessThan(10));
  });
}
