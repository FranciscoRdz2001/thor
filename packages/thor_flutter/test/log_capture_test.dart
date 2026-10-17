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

    test('print: llega a la consola INTACTO y se graba limpio', () {
      final out = <String>[];
      _withConsole(out, () => print('login ana@x.com token=abc123'));
      expect(out, ['login ana@x.com token=abc123']);
      final log = _logs().single;
      expect(log['source'], 'print');
      expect(log['level'], 'debug');
      expect(
        log['message'],
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

    Future<List<Map<String, Object?>>> logRecords(WidgetTester tester) async {
      await tester.runAsync(ThorReplay.stop);
      final file = dir
          .listSync()
          .whereType<File>()
          .singleWhere((f) => f.path.endsWith('.jsonl'));
      return [
        for (final line in file.readAsLinesSync())
          if (jsonDecode(line) case final Map<String, Object?> m
              when m['t'] == 'ev' && m['k'] == 'log')
            (m['p']! as Map).cast<String, Object?>(),
      ];
    }

    void logAllLevels(String tag) {
      for (final level in ThorLogLevel.values) {
        Thor.log('$tag ${level.name} ana@x.com', level: level);
      }
    }

    testWidgets('por defecto solo warn/error; en diagnóstico todos',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('x')));
      await tester.runAsync(
        () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
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
