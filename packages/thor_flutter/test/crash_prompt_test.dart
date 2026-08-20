import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('inicio'));
}

void main() {
  late Directory tmp;

  // OJO: los cuerpos de testWidgets corren en FakeAsync — el I/O real de
  // disco ahí se cuelga para siempre. Regla de este archivo: I/O solo
  // SÍNCRONO (File.writeAsStringSync) o dentro de tester.runAsync.
  // (Cazado en carne propia: la suite entera se colgó.)

  setUp(() {
    ThorCore.debugReset();
    ThorCrashPrompt.debugReset();
    ThorNavigatorObserver.overlayEnabled = true;
    tmp = Directory.systemTemp.createTempSync('thor_crash_prompt');
  });

  tearDown(() {
    ThorOverlayManager.detach();
    ThorNavigatorObserver.overlayEnabled = false;
    ThorCore.debugReset();
    ThorCrashPrompt.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// Deja en disco (SÍNCRONO) el journal de una sesión que "murió":
  /// cabecera + un error, SIN marca de fin.
  void plantCrashedSession() {
    final lines = [
      jsonEncode({
        'type': 'session',
        'sessionId': 'muerta',
        'installId': 'i1',
        'startedAtUtc': '2026-08-20T00:00:00.000Z',
        'utcOffsetUs': 0,
        'appInfo': {'flavor': 'qa'},
        'deviceInfo': <String, String>{},
      }),
      jsonEncode({
        'type': 'event',
        'seq': 0,
        'kind': 'error',
        'atUtc': '2026-08-20T01:00:00.000Z',
        'utcOffsetUs': 0,
        'payload': {'type': 'StateError', 'message': 'kaboom'},
      }),
    ];
    File('${tmp.path}/thor-muerta.jsonl')
        .writeAsStringSync('${lines.join('\n')}\n');
  }

  void plantCleanSession() {
    final lines = [
      jsonEncode({
        'type': 'session',
        'sessionId': 'limpia',
        'installId': 'i1',
        'startedAtUtc': '2026-08-20T00:00:00.000Z',
        'utcOffsetUs': 0,
        'appInfo': <String, String>{},
        'deviceInfo': <String, String>{},
      }),
      jsonEncode({'type': 'end', 'atUtc': '2026-08-20T02:00:00.000Z'}),
    ];
    File('${tmp.path}/thor-limpia.jsonl')
        .writeAsStringSync('${lines.join('\n')}\n');
  }

  Future<void> initAndPump(WidgetTester tester) async {
    // I/O real (leer journals) fuera de FakeAsync.
    await tester.runAsync(() => ThorCore.init(storageDirectory: tmp));
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ThorNavigatorObserver()],
        home: const HomePage(),
      ),
    );
    await tester.pump(); // post-frame: burbuja + aviso
    await tester.pump();
  }

  /// El journal agenda un timer de flush (2s) por cada evento grabado; en
  /// FakeAsync un timer pendiente al terminar el test es fallo. Avanzar el
  /// reloj lo dispara y lo limpia.
  Future<void> drainJournalTimers(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 3));

  testWidgets('sesión previa muerta → banner al arrancar', (tester) async {
    plantCrashedSession();
    await initAndPump(tester);

    expect(
      find.textContaining('terminó de forma inesperada'),
      findsOneWidget,
    );
    await drainJournalTimers(tester);
  });

  testWidgets('Ver reporte abre la página con la narrativa del crash',
      (tester) async {
    plantCrashedSession();
    await initAndPump(tester);

    await tester.tap(find.text('Ver reporte'));
    await tester.pumpAndSettle();

    expect(find.byType(ThorCrashReportPage), findsOneWidget);
    expect(find.textContaining('StateError'), findsOneWidget);
    expect(find.textContaining('crashRecovery'), findsOneWidget);
    await drainJournalTimers(tester);
  });

  testWidgets('Descartar quita el banner', (tester) async {
    plantCrashedSession();
    await initAndPump(tester);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(find.textContaining('terminó de forma inesperada'), findsNothing);
    await drainJournalTimers(tester);
  });

  testWidgets('sesión previa LIMPIA → sin banner', (tester) async {
    plantCleanSession();
    await initAndPump(tester);

    expect(find.textContaining('terminó de forma inesperada'), findsNothing);
    await drainJournalTimers(tester);
  });

  testWidgets(
      'mute selectivo: la red de fondo SÍ se graba con inspector abierto',
      (tester) async {
    await ThorCore.init(); // sin storage: cero I/O, seguro en FakeAsync
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ThorNavigatorObserver()],
        home: const HomePage(),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('⚡'));
    await tester.pumpAndSettle();
    expect(ThorCore.instance!.recorder.muted, isTrue);

    // Simula sync de fondo mientras QA mira el panel.
    final recorded = ThorCore.instance!.recorder.record(
      ThorEventKind.network,
      {'method': 'POST', 'url': '/sync', 'statusCode': 200, 'durationMs': 40},
    );
    expect(recorded, isNotNull, reason: 'la red nunca se silencia');

    // Pero la navegación propia del inspector NO se graba.
    final nav = ThorCore.instance!.recorder.record(
      ThorEventKind.navigation,
      const {'action': 'push', 'to': 'thor/x'},
    );
    expect(nav, isNull);
  });
}
