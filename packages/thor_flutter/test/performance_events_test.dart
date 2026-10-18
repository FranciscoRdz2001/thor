import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

/// Contrato de `performance`: startup, screen_load, jank por pantalla, anr
/// y custom (`Thor.measure`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var fakeUs = 0;

  setUp(() async {
    ThorCore.debugReset();
    await ThorCore.init();
    fakeUs = 1000000;
    PerformanceCapture.nowUs = () => fakeUs;
    PerformanceCapture.markRunStart();
    PerformanceCapture.attach();
  });

  tearDown(() {
    PerformanceCapture.uninstall();
    ThorCore.debugReset();
  });

  List<Map<String, Object?>> perf([String? kind]) => [
        for (final e
            in ThorCore.instance!.store.ofKind(ThorEventKind.performance))
          if (kind == null || e.payload['kind'] == kind) e.payload,
      ];

  void nav(String to, {String action = 'push', String? from}) =>
      ThorCore.instance!.recorder.record(ThorEventKind.navigation, {
        'action': action,
        'to': to,
        if (from != null) 'from': from,
      });

  group('startup', () {
    test('first_frame: ms desde Thor.run, una sola vez', () {
      fakeUs += 850000;
      PerformanceCapture.onFirstFrame();
      PerformanceCapture.onFirstFrame();
      expect(perf('startup'), [
        {'kind': 'startup', 'ms': 850, 'until': 'first_frame'},
      ]);
    });

    test('first_screen: con la primera navegación, no con las siguientes', () {
      fakeUs += 1200000;
      nav('HomePage');
      fakeUs += 500000;
      nav('CartPage', from: 'HomePage');
      final startups = perf('startup');
      expect(startups, hasLength(1));
      expect(startups.single['until'], 'first_screen');
      expect(startups.single['ms'], 1200);
    });
  });

  group('screen_load', () {
    test('de la navegación al último frame, sin contar la espera de quietud',
        () {
      nav('CartPage', from: 'HomePage');
      fakeUs += 120000;
      PerformanceCapture.onFrame();
      fakeUs += 180000;
      PerformanceCapture.onFrame(); // último frame: 300 ms tras la nav.
      fakeUs += 300000; // quietud (no cuenta)
      PerformanceCapture.onIdle();
      expect(perf('screen_load'), [
        {
          'kind': 'screen_load',
          'screen': 'CartPage',
          'ms': 300,
          'from': 'HomePage',
        },
      ]);
      PerformanceCapture.onIdle(); // sin pendiente: nada más.
      expect(perf('screen_load'), hasLength(1));
    });

    test('dos navegaciones antes de la quietud: mide desde la primera', () {
      nav('Splash');
      fakeUs += 100000;
      PerformanceCapture.onFrame();
      nav('HomePage', from: 'Splash');
      fakeUs += 100000;
      PerformanceCapture.onFrame();
      PerformanceCapture.onIdle();
      final load = perf('screen_load').single;
      expect(load['screen'], 'HomePage');
      expect(load['ms'], 200);
      expect(load.containsKey('from'), isFalse);
    });

    test('pantalla detectada por el árbol: desde el inicio de la ráfaga', () {
      PerformanceCapture.onFrame(); // inicio de ráfaga
      fakeUs += 250000;
      PerformanceCapture.onFrame();
      nav('TabB', action: 'screen', from: 'TabA'); // se detecta al final
      PerformanceCapture.onIdle();
      expect(perf('screen_load').single['ms'], 250);
    });

    test('sin navegación no hay screen_load', () {
      PerformanceCapture.onFrame();
      PerformanceCapture.onIdle();
      expect(perf('screen_load'), isEmpty);
    });
  });

  group('jank por pantalla', () {
    test('el lote lleva la pantalla vigente', () {
      ThorCore.instance!.setScreen('CatalogoPage');
      PerformanceCapture.handleFrameTotals([
        for (var i = 0; i < 5; i++) const Duration(milliseconds: 50),
        const Duration(milliseconds: 800),
      ]);
      expect(perf('jank').single, {
        'kind': 'jank',
        'screen': 'CatalogoPage',
        'slow': 6,
        'frozen': 1,
        'worstMs': 800,
        'frames': 6,
      });
    });

    test('el agregado del reporte cuenta solo jank', () {
      ThorCore.instance!.setScreen('CatalogoPage');
      PerformanceCapture.handleFrameTotals(
        List.filled(4, const Duration(milliseconds: 60)),
      );
      Thor.measure('x', 5);
      AnrWatchdog.recordAnr(2500);
      final stats = ThorAggregates.slowFramesByScreen(
        ThorCore.instance!.store.timeline(),
      );
      expect(stats, {
        'CatalogoPage': {'slowFrames': 4, 'worstMs': 60},
      });
    });
  });

  group('Thor.measure', () {
    test('custom con nombre, ms y data sin secretos', () {
      Thor.measure('checkout', 840.4, data: {'items': 3, 'token': 'abc123'});
      Thor.measure('sin_data', 12);
      final events = perf('custom');
      expect(events[0]['name'], 'checkout');
      expect(events[0]['ms'], 840);
      final data = events[0]['data']! as Map;
      expect(data['items'], 3);
      expect(data['token'], isNot('abc123'));
      expect(events[1].containsKey('data'), isFalse);
    });

    test('ms inválido se ignora; Thor apagado no revienta', () {
      Thor.measure('nan', double.nan);
      Thor.measure('neg', -1);
      expect(perf('custom'), isEmpty);
      ThorCore.debugReset();
      expect(() => Thor.measure('off', 5), returnsNormally);
    });
  });

  group('ANR watchdog (isolate real)', () {
    tearDown(AnrWatchdog.stop);

    Future<void> startDog() async {
      await AnrWatchdog.start(
        threshold: const Duration(milliseconds: 300),
        force: true,
      );
      // Deja que el handshake y algunos pings fluyan.
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    void block(Duration d) {
      final sw = Stopwatch()..start();
      while (sw.elapsed < d) {}
    }

    test('un bloqueo >= umbral se reporta con duración y pantalla', () async {
      ThorCore.instance!.setScreen('PesadaPage');
      await startDog();
      expect(perf('anr'), isEmpty, reason: 'sana: sin falsos positivos');
      block(const Duration(milliseconds: 900));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final anr = perf('anr').single;
      expect(anr['ms'], inInclusiveRange(800, 1300));
      expect(anr['screen'], 'PesadaPage');
    });

    test('un bloqueo menor al umbral no se reporta', () async {
      await startDog();
      block(const Duration(milliseconds: 150));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(perf('anr'), isEmpty);
    });

    test('en segundo plano no mide ni despierta; al volver, sí', () async {
      await startDog();
      AnrWatchdog.setActive(active: false);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      block(const Duration(milliseconds: 700));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(perf('anr'), isEmpty);

      AnrWatchdog.setActive(active: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      block(const Duration(milliseconds: 700));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(perf('anr'), hasLength(1));
    });

    test('stop mata el isolate; sin force no arranca en tests', () async {
      await AnrWatchdog.start();
      expect(AnrWatchdog.running, isFalse, reason: 'FLUTTER_TEST');
      await startDog();
      expect(AnrWatchdog.running, isTrue);
      AnrWatchdog.stop();
      expect(AnrWatchdog.running, isFalse);
      block(const Duration(milliseconds: 600));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(perf('anr'), isEmpty);
    });
  });
}
