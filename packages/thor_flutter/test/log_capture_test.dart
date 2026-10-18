// Este archivo prueba justamente la captura de print.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

/// Corre [body] con la consola de verdad redirigida a [out] (el padre de la
/// zona de Thor), y con el `print` de Thor encima: así se ve a la vez qué
/// llegó a la consola y qué se grabó.
T _withConsole<T>(List<String> out, T Function() body) => runZoned(
      () => runZoned(body, zoneSpecification: LogCapture.zoneSpecification),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => out.add(line),
      ),
    );

List<Map<String, Object?>> _logs() => [
      for (final e in ThorCore.instance!.store.ofKind(ThorEventKind.log))
        e.payload,
    ];

void main() {
  group('LogCapture', () {
    late DebugPrintCallback saved;

    setUp(() async {
      saved = debugPrint;
      await ThorCore.init();
    });

    tearDown(() {
      LogCapture.uninstall();
      debugPrint = saved;
      ThorCore.debugReset();
    });

    test('print: llega a la consola INTACTO y se graba sin secretos', () {
      final out = <String>[];
      _withConsole(out, () => print('login ana@x.com token=abc123'));
      expect(out, ['login ana@x.com token=abc123']);
      final log = _logs().single;
      expect(log['source'], 'print');
      expect(log['level'], 'debug');
      // Por defecto (solo secretos) el email queda: hace falta al depurar.
      expect(
        log['message'],
        'login ana@x.com token=${RedactionPolicy.redactedMarker}',
      );
    });

    test('strict: print se graba también sin datos personales', () async {
      ThorCore.debugReset();
      await ThorCore.init(redaction: const RedactionPolicy.strict());
      _withConsole(<String>[], () => print('login ana@x.com token=abc123'));
      expect(
        _logs().single['message'],
        'login :email token=${RedactionPolicy.redactedMarker}',
      );
    });

    test('print con pinta de error se graba como error', () {
      _withConsole(<String>[], () => print('Error al cobrar el pedido'));
      expect(_logs().single['level'], 'error');
    });

    test('debugPrint: se graba UNA vez como debugPrint y delega al de la app',
        () {
      final appOut = <String?>[];
      debugPrint = (message, {wrapWidth}) => appOut.add(message);
      LogCapture.install();
      _withConsole(<String>[], () => debugPrint('⚠ cache vieja'));
      expect(appOut, ['⚠ cache vieja']);
      final log = _logs().single;
      expect(log['source'], 'debugPrint');
      expect(log['level'], 'warn');
      LogCapture.uninstall();
      expect(debugPrint, isNot(same(saved)));
      debugPrint('después');
      expect(appOut.last, 'después', reason: 'restaura el de la app');
    });

    test('debugPrintThrottled no se duplica como print (ni lo diferido)',
        () async {
      debugPrint = debugPrintThrottled;
      LogCapture.install();
      final out = <String>[];
      // >12 KB: debugPrintThrottled imprime una parte ya y el resto desde
      // un Timer, un segundo después.
      final line = 'x' * 1000;
      _withConsole(out, () {
        for (var i = 0; i < 20; i++) {
          debugPrint('$i $line');
        }
      });
      expect(out.length, lessThan(20), reason: 'algo quedó diferido');
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(out, hasLength(20));
      final logs = _logs();
      expect(logs.every((l) => l['source'] == 'debugPrint'), isTrue);
      // 20 líneas, tope de 20 por segundo: todas grabadas, ninguna doble.
      expect(logs, hasLength(20));
    });

    test('el volcado de FlutterError no se duplica como logs', () {
      final savedOnError = FlutterError.onError;
      final console = <String?>[];
      debugPrint = (message, {wrapWidth}) => console.add(message);
      // El volcado de texto de siempre (presentError puede ser el
      // estructurado del inspector, que no pasa por debugPrint).
      FlutterError.onError = FlutterError.dumpErrorToConsole;
      LogCapture.install();
      ErrorCapture.install();
      try {
        _withConsole(
          <String>[],
          () => FlutterError.reportError(
            FlutterErrorDetails(exception: StateError('boom')),
          ),
        );
      } finally {
        FlutterError.onError = savedOnError;
      }
      expect(console, isNotEmpty, reason: 'la consola recibe el volcado');
      expect(
        ThorCore.instance!.store.ofKind(ThorEventKind.error),
        hasLength(1),
      );
      expect(_logs(), isEmpty);
    });

    test('silenced: lo impreso adentro no se graba', () {
      final out = <String>[];
      _withConsole(out, () => LogCapture.silenced(() => print('volcado')));
      expect(out, ['volcado']);
      expect(_logs(), isEmpty);
    });

    test('ráfaga de print: tope con resumen', () {
      _withConsole(<String>[], () {
        for (var i = 0; i < 50; i++) {
          print('tick $i');
        }
      });
      ThorCore.instance!.recorder.flushBursts();
      final logs = _logs();
      expect(logs.where((l) => l['burst'] != true), hasLength(20));
      expect(logs.singleWhere((l) => l['burst'] == true)['dropped'], 30);
    });

    test('mensaje largo se recorta', () {
      _withConsole(<String>[], () => print('a' * 2000));
      expect(
        (_logs().single['message']! as String).length,
        lessThan(520),
      );
    });
  });

  test('sin Thor: print y debugPrint como siempre, nada se graba', () {
    ThorCore.debugReset();
    final out = <String>[];
    _withConsole(out, () => print('hola'));
    expect(out, ['hola']);
    expect(ThorCore.instance, isNull);
    // La fachada apagada es no-op, nunca error.
    Thor.log('nada', level: ThorLogLevel.error);
  });

  group('replay', () {
    late Directory dir;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('thor_log_replay');
      await ThorCore.init();
    });

    tearDown(() async {
      await ThorReplay.stop();
      ThorCore.debugReset();
      dir.deleteSync(recursive: true);
    });

    Future<List<Map<String, Object?>>> evRecords(
      WidgetTester tester,
      String kind,
    ) async {
      await tester.runAsync(ThorReplay.stop);
      final file = dir
          .listSync()
          .whereType<File>()
          .singleWhere((f) => f.path.endsWith('.jsonl'));
      return [
        for (final line in file.readAsLinesSync())
          if (jsonDecode(line) case final Map<String, Object?> m
              when m['t'] == 'ev' && m['k'] == kind)
            (m['p']! as Map).cast<String, Object?>(),
      ];
    }

    Future<List<Map<String, Object?>>> logRecords(WidgetTester tester) =>
        evRecords(tester, 'log');

    void logAllLevels(String tag) {
      for (final level in ThorLogLevel.values) {
        Thor.log('$tag ${level.name} ana@x.com', level: level);
      }
    }

    testWidgets(
        'por defecto solo warn/error; en diagnóstico todos; sin '
        'secretos', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('x')));
      await tester.runAsync(
        () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
      );
      Thor.log('sesión password=hunter2', level: ThorLogLevel.error);
      ThorReplay.instance!.diagnostic = true;
      Thor.log('diag token=abc123', level: ThorLogLevel.debug);

      final logs = await logRecords(tester);
      final body = jsonEncode(logs);
      expect(body, isNot(contains('hunter2')));
      expect(body, isNot(contains('abc123')));
      expect(logs.map((p) => p['lv']), ['error', 'debug']);
    });

    testWidgets('Thor.log con data y Thor.track viajan al replay',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('x')));
      await tester.runAsync(
        () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
      );
      Thor.log('cobro', data: {'orderId': 7, 'token': 'zzz'});
      Thor.track('add_to_cart', {'sku': 'A1', 'password': 'pw'});
      Thor.track('sin_props');

      final logs = await logRecords(tester);
      final log = logs.singleWhere((p) => p['m'] == 'cobro');
      expect(log['lv'], 'info');
      expect(log['data'], {
        'orderId': 7,
        'token': RedactionPolicy.redactedMarker,
      });
      final tracks = await evRecords(tester, 'track');
      expect(tracks[0], {
        'n': 'add_to_cart',
        'props': {'sku': 'A1', 'password': RedactionPolicy.redactedMarker},
      });
      expect(tracks[1], {'n': 'sin_props'});
    });

    testWidgets('performance (measure, anr, jank) viaja al replay',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('x')));
      await tester.runAsync(
        () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
      );
      Thor.setScreen('CobroPage');
      Thor.measure('checkout', 840, data: {'items': 3, 'token': 'zzz'});
      AnrWatchdog.recordAnr(2400);
      PerformanceCapture.handleFrameTotals(
        List.filled(4, const Duration(milliseconds: 60)),
      );

      final perf = await evRecords(tester, 'performance');
      expect(perf[0], {
        'kind': 'custom',
        'name': 'checkout',
        'ms': 840,
        'data': {'items': 3, 'token': RedactionPolicy.redactedMarker},
      });
      expect(perf[1], {
        'kind': 'anr',
        'ms': 2400,
        'screen': 'CobroPage',
        'startAt': isA<String>(),
      });
      expect(perf[2], {
        'kind': 'jank',
        'screen': 'CobroPage',
        'slow': 4,
        'frozen': 0,
        'worstMs': 60,
        'frames': 4,
      });
    });

    testWidgets('strict: solo warn/error; en diagnóstico todos; sin emails',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('x')));
      await tester.runAsync(
        () => ThorReplay.start(
          const ThorReplayConfig(privacy: ThorPrivacy.strict),
          directory: dir,
        ),
      );
      logAllLevels('normal');
      Thor.mark('marca');
      ThorReplay.instance!.diagnostic = true;
      logAllLevels('diag');

      final logs = await logRecords(tester);
      final normal = logs.where((p) => '${p['m']}'.startsWith('normal'));
      expect(normal.map((p) => p['lv']), ['warn', 'error']);
      expect(normal.first['src'], 'thor');
      // Limpio: el email nunca viaja.
      expect(jsonEncode(logs), isNot(contains('ana@x.com')));
      expect(logs.any((p) => p['l'] == 'marca'), isTrue);
      final diag = logs.where((p) => '${p['m']}'.startsWith('diag'));
      expect(diag.map((p) => p['lv']), ['debug', 'info', 'warn', 'error']);
    });
  });
}
