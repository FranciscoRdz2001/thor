import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('inicio'));
}

void main() {
  setUp(() async {
    ThorCore.debugReset();
    await ThorCore.init();
    ThorNavigatorObserver.overlayEnabled = true;
  });

  tearDown(() {
    ThorOverlayManager.detach();
    ThorNavigatorObserver.overlayEnabled = false;
    ThorCore.debugReset();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ThorNavigatorObserver()],
        home: const HomePage(),
      ),
    );
    await tester.pump();
  }

  testWidgets('la burbuja se monta sola al primer push (integración cero)',
      (tester) async {
    await pumpApp(tester);
    expect(ThorOverlayManager.attached, isTrue);
    expect(find.text('⚡'), findsOneWidget);
  });

  testWidgets('overlayEnabled=false: sin burbuja', (tester) async {
    ThorNavigatorObserver.overlayEnabled = false;
    await pumpApp(tester);
    expect(ThorOverlayManager.attached, isFalse);
  });

  testWidgets('tap en la burbuja abre el inspector y SILENCIA el grabador',
      (tester) async {
    // Un evento de red previo para que la pestaña Red tenga contenido.
    ThorCore.instance!.recorder.record(ThorEventKind.network, {
      'method': 'POST',
      'url': 'https://api.x/orders',
      'statusCode': 500,
      'durationMs': 210,
    });
    await pumpApp(tester);
    final eventsBefore = ThorCore.instance!.store.length;

    await tester.tap(find.text('⚡'));
    await tester.pumpAndSettle();

    expect(find.byType(ThorInspectorPage), findsOneWidget);
    expect(ThorCore.instance!.recorder.muted, isTrue);
    // Nada de lo que pasó al abrir el inspector quedó grabado.
    expect(ThorCore.instance!.store.length, eventsBefore);

    // La petición aparece listada.
    expect(find.textContaining('POST /orders'), findsOneWidget);
  });

  testWidgets('al cerrar el inspector el grabador vuelve a grabar',
      (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('⚡'));
    await tester.pumpAndSettle();
    expect(ThorCore.instance!.recorder.muted, isTrue);

    // Regresar (pop del inspector).
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(ThorCore.instance!.recorder.muted, isFalse);
    expect(find.byType(ThorInspectorPage), findsNothing);
  });

  testWidgets('detalle de petición muestra cURL y cuerpos', (tester) async {
    ThorCore.instance!.recorder.record(ThorEventKind.network, {
      'method': 'POST',
      'url': 'https://api.x/orders',
      'statusCode': 422,
      'durationMs': 310,
      'responseBody': {'message': 'turno cerrado'},
      'curl': "curl -X POST 'https://api.x/orders'",
    });
    await pumpApp(tester);
    await tester.tap(find.text('⚡'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('POST /orders'));
    await tester.pumpAndSettle();

    expect(find.textContaining('turno cerrado'), findsOneWidget);
    expect(find.textContaining('curl -X POST'), findsOneWidget);
  });

  testWidgets('pestaña Pasos muestra la narrativa', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('⚡'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pasos'));
    await tester.pumpAndSettle();

    // La navegación inicial de la app quedó narrada.
    expect(find.textContaining('Abrió'), findsOneWidget);
  });

  testWidgets('pestaña Errores agrupa por huella con conteo', (tester) async {
    for (var i = 0; i < 3; i++) {
      ThorCore.instance!.recorder.record(
        ThorEventKind.error,
        {'type': 'StateError', 'message': 'boom'},
        origin: 'package:app/c.dart:1',
      );
    }
    await pumpApp(tester);
    await tester.tap(find.text('⚡'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Errores'));
    await tester.pumpAndSettle();

    expect(find.text('×3'), findsOneWidget);
    expect(find.text('StateError'), findsOneWidget);
  });
}
