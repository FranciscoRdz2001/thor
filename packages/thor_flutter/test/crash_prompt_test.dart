import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/src/overlay/thor_ui.dart';
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
  void plantCrashedSession([List<String> extra = const []]) {
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
      ...extra,
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
      tester.pump(const Duration(seconds: 7));

  testWidgets('sesión previa muerta → banner al arrancar', (tester) async {
    plantCrashedSession();
    await initAndPump(tester);

    expect(
      find.textContaining('se cayó'),
      findsOneWidget,
    );
    await drainJournalTimers(tester);
  });

  testWidgets('Ver reporte abre la página con la narrativa del crash',
      (tester) async {
    plantCrashedSession();
    await initAndPump(tester);

    await tester.tap(find.text('Ver'));
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

    expect(find.textContaining('se cayó'), findsNothing);
    await drainJournalTimers(tester);
  });

  testWidgets('sesión previa LIMPIA → sin banner', (tester) async {
    plantCleanSession();
    await initAndPump(tester);

    expect(find.textContaining('se cayó'), findsNothing);
    await drainJournalTimers(tester);
  });

  String lifecycleLine(int seq, String state) => jsonEncode({
        'type': 'event',
        'seq': seq,
        'kind': 'environment',
        'atUtc': '2026-08-20T01:00:0$seq.000Z',
        'utcOffsetUs': 0,
        'payload': {'signal': 'lifecycle', 'state': state},
      });

  testWidgets('sesión previa matada en segundo plano (paused) → sin banner',
      (tester) async {
    plantCrashedSession([lifecycleLine(1, 'paused')]);
    // El error del helper no es fatal: el último estado manda.
    await initAndPump(tester);

    expect(find.textContaining('se cayó'), findsNothing);
    await drainJournalTimers(tester);
  });

  testWidgets('sesión previa con error FATAL → banner aunque terminara paused',
      (tester) async {
    plantCrashedSession([
      jsonEncode({
        'type': 'event',
        'seq': 2,
        'kind': 'error',
        'atUtc': '2026-08-20T01:00:02.000Z',
        'utcOffsetUs': 0,
        'payload': {'type': 'StateError', 'fatal': true, 'source': 'zone'},
      }),
      lifecycleLine(3, 'paused'),
    ]);
    await initAndPump(tester);

    expect(find.textContaining('se cayó'), findsOneWidget);
    await drainJournalTimers(tester);
  });

  testWidgets('se descarta solo a los 6 s', (tester) async {
    plantCrashedSession();
    await initAndPump(tester);
    expect(find.textContaining('se cayó'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    expect(find.textContaining('se cayó'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('se cayó'), findsNothing);
    await drainJournalTimers(tester);
  });

  testWidgets(
      'compacto y arriba: no tapa la barra inferior y los toques fuera '
      'de su recuadro llegan a la app', (tester) async {
    plantCrashedSession();
    ThorCore.debugReset();
    await tester.runAsync(() => ThorCore.init(storageDirectory: tmp));
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ThorNavigatorObserver()],
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => tapped++,
                ),
              ),
            ],
          ),
          bottomNavigationBar: BottomAppBar(
            child: TextButton(
              onPressed: () => tapped += 100,
              child: const Text('Aplicar filtros'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final banner = tester.getRect(find.textContaining('se cayó'));
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(banner.top, lessThan(80), reason: 'va arriba');
    expect(banner.height, lessThan(60), reason: 'compacto');
    expect(
      banner.width,
      lessThan(screen.width - 24),
      reason: 'no ocupa todo el ancho',
    );

    // Botón de abajo y área vacía junto al aviso: pasan a la app.
    await tester.tap(find.text('Aplicar filtros'));
    expect(tapped, 100);
    await tester.tapAt(Offset(screen.width - 5, banner.center.dy));
    expect(tapped, 101);
    await drainJournalTimers(tester);
  });

  testWidgets(
      'la UI de Thor no cuenta como app: ni navegación, ni interacción, '
      'ni screen_load, ni pantalla activa', (tester) async {
    plantCrashedSession();
    ThorCore.debugReset();
    await tester.runAsync(() => ThorCore.init(storageDirectory: tmp));
    InteractionCapture.install();
    ScreenCapture.install();
    addTearDown(() {
      InteractionCapture.uninstall();
      ScreenCapture.uninstall();
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ThorNavigatorObserver()],
        home: const HomePage(),
      ),
    );
    await tester.pump();
    await tester.pump();
    final core = ThorCore.instance!;
    final before = core.store.length;
    final screenBefore = core.recorder.currentScreen?.display;

    // Tocar el aviso y abrir el reporte.
    await tester.tap(find.text('Ver'));
    await tester.pumpAndSettle();
    expect(find.byType(ThorCrashReportPage), findsOneWidget);
    // Dar tiempo a ScreenCapture (quietud 300 ms) y a screen_load.
    await tester.pump(const Duration(seconds: 1));
    ScreenCapture.check();

    // También la burbuja y el inspector.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('⚡'));
    await tester.pumpAndSettle();
    expect(find.byType(ThorInspectorPage), findsOneWidget);
    await tester.tap(find.text('Pasos'));
    await tester.pumpAndSettle();
    ScreenCapture.check();
    await tester.pageBack();
    await tester.pumpAndSettle();

    final fresh = core.store.timeline().skip(before).toList();
    bool isThorNav(ThorEvent e) =>
        e.kind == ThorEventKind.navigation ||
        e.kind == ThorEventKind.interaction ||
        (e.kind == ThorEventKind.performance &&
            e.payload['kind'] == 'screen_load');
    expect(
      fresh.where(isThorNav).map((e) => '${e.kind.name}:${e.payload}'),
      isEmpty,
    );
    expect(core.recorder.currentScreen?.display, screenBefore);
    expect(ThorUi.openPages, 0);
    expect(core.recorder.muted, isFalse);
    ScreenCapture.uninstall(); // cancela su timer de quietud
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
