import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

void main() {
  setUp(() async {
    ThorCore.debugReset();
    ThorScreenshot.clear();
    await ThorCore.init();
  });

  tearDown(() {
    ThorScreenshot.clear();
    ThorCore.debugReset();
  });

  testWidgets('captura la pantalla montada y deja PNG en latest',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('cobrar'))),
      ),
    );

    // toImage necesita el pipeline real: fuera de FakeAsync.
    final bytes = await tester.runAsync(ThorScreenshot.capture);

    expect(bytes, isNotNull);
    expect(bytes!.length, greaterThan(0));
    // Firma PNG: 89 50 4E 47.
    expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    expect(ThorScreenshot.latest, same(bytes));
    expect(ThorScreenshot.latestAtUtc, isNotNull);
  });

  testWidgets('sin árbol montado devuelve null, no lanza', (tester) async {
    final bytes = await tester.runAsync(ThorScreenshot.capture);
    expect(bytes, isNull);
  });

  testWidgets('clear olvida la captura retenida', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('x'))),
    );
    await tester.runAsync(ThorScreenshot.capture);
    expect(ThorScreenshot.latest, isNotNull);

    ThorScreenshot.clear();
    expect(ThorScreenshot.latest, isNull);
    expect(ThorScreenshot.latestAtUtc, isNull);
  });

  testWidgets('un desborde de layout dispara captura automática',
      (tester) async {
    ErrorCapture.install();
    // Row más ancho que la pantalla → RenderFlex overflow real.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [SizedBox(width: 5000, height: 20)],
          ),
        ),
      ),
    );
    // flutter_test trata todo FlutterError como fallo del test: se
    // consume la excepción esperada para poder afirmar sobre lo grabado.
    expect(tester.takeException(), isA<FlutterError>());

    final errors = ThorCore.instance!.store.ofKind(ThorEventKind.error);
    expect(errors, isNotEmpty);
    expect(
      errors.any((e) => e.payload['source'] == 'layout_overflow'),
      isTrue,
      reason: 'el desborde debe etiquetarse aparte',
    );
    // La captura se dispara en background; se deja correr el pipeline.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  });
}
