import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/src/environment_capture.dart';
import 'package:thor_flutter/thor_flutter.dart';

/// Contrato de `environment`: lifecycle, memory_pressure, locale,
/// text_scale, brightness (y connectivity, que infiere el núcleo).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Map<String, Object?>> env() => [
        for (final e
            in ThorCore.instance!.store.ofKind(ThorEventKind.environment))
          e.payload,
      ];

  setUp(() async {
    ThorCore.debugReset();
    await ThorCore.init();
    EnvironmentCapture.memoryPressureGap = Duration.zero;
  });

  tearDown(() {
    EnvironmentCapture.uninstall();
    ThorCore.debugReset();
    EnvironmentCapture.memoryPressureGap = const Duration(seconds: 5);
  });

  group('señales del dispositivo', () {
    testWidgets('lifecycle con todos los estados', (tester) async {
      EnvironmentCapture.install();
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      expect(env(), [
        for (final s in ['inactive', 'hidden', 'paused'])
          {'signal': 'lifecycle', 'state': s},
        // Al volver trae cuánto estuvo en segundo plano (para excluirlo de
        // la duración de la sesión).
        {'signal': 'lifecycle', 'state': 'resumed', 'backgroundMs': isA<int>()},
      ]);
    });

    testWidgets('memory_pressure, espaciada', (tester) async {
      EnvironmentCapture.memoryPressureGap = const Duration(minutes: 1);
      EnvironmentCapture.install();
      tester.binding.handleMemoryPressure();
      tester.binding.handleMemoryPressure();
      expect(env(), [
        {'signal': 'memory_pressure'},
      ]);
    });

    testWidgets('locale, text_scale y brightness solo si cambian',
        (tester) async {
      final d = tester.platformDispatcher;
      addTearDown(d.clearAllTestValues);
      EnvironmentCapture.install();

      void apply() {
        d
          ..localeTestValue = const Locale('es', 'MX')
          ..localesTestValue = const [Locale('es', 'MX')]
          ..textScaleFactorTestValue = 1.3
          ..platformBrightnessTestValue = Brightness.dark;
      }

      apply();
      // Mismos valores otra vez: nada nuevo.
      apply();

      expect(
        env(),
        containsAll([
          {'signal': 'locale', 'value': 'es_MX'},
          {'signal': 'text_scale', 'value': 1.3},
          {'signal': 'brightness', 'value': 'dark'},
        ]),
      );
      expect(env().where((e) => e['signal'] == 'locale'), hasLength(1));
      expect(env().where((e) => e['signal'] == 'text_scale'), hasLength(1));
      expect(env().where((e) => e['signal'] == 'brightness'), hasLength(1));
    });

    testWidgets('install es idempotente y sin Thor no hace nada',
        (tester) async {
      EnvironmentCapture.install();
      EnvironmentCapture.install();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(env(), hasLength(1));

      ThorCore.debugReset();
      // Apagado = inofensivo.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(ThorCore.instance, isNull);
    });
  });

  group('replay', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('thor_env_replay'));

    tearDown(() async {
      await ThorReplay.stop();
      dir.deleteSync(recursive: true);
    });

    testWidgets('las señales viajan slim al replay', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('x')));
      await tester.runAsync(
        () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
      );
      EnvironmentCapture.install();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleMemoryPressure();
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      // Conectividad inferida por el núcleo (dos hosts con DNS caído).
      for (final host in ['a.com', 'b.com']) {
        ThorCore.instance!.recorder.record(ThorEventKind.network, {
          'url': 'https://$host/x',
          'error': 'SocketException',
          'errorMessage': 'SocketException: Failed host lookup',
        });
      }

      await tester.runAsync(ThorReplay.stop);
      final file = dir
          .listSync()
          .whereType<File>()
          .singleWhere((f) => f.path.endsWith('.jsonl'));
      final evs = [
        for (final line in file.readAsLinesSync())
          if (jsonDecode(line) case final Map<String, Object?> m
              when m['t'] == 'ev' && m['k'] == 'environment')
            (m['p']! as Map).cast<String, Object?>(),
      ];
      expect(evs, [
        {'signal': 'lifecycle', 'state': 'paused'},
        {'signal': 'memory_pressure'},
        {'signal': 'text_scale', 'value': 1.5},
        {'signal': 'connectivity', 'online': false},
      ]);
    });
  });
}
