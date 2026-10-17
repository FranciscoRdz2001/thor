import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

class CobroPage extends StatelessWidget {
  const CobroPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(
          children: [
            TextField(
              key: const Key('campo-cliente'),
              decoration: const InputDecoration(labelText: 'Cliente'),
              controller: TextEditingController(text: 'dato sensible'),
            ),
            ElevatedButton(
              onPressed: () {},
              child: const Text('Cobrar'),
            ),
          ],
        ),
      );
}

void main() {
  setUp(() async {
    ThorCore.debugReset();
    await ThorCore.init();
    InteractionCapture.install();
  });

  tearDown(() {
    InteractionCapture.uninstall();
    ThorCore.debugReset();
  });

  List<ThorEvent> taps() =>
      ThorCore.instance!.store.ofKind(ThorEventKind.interaction);

  testWidgets('tap en botón captura label y tipo', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CobroPage()));
    await tester.tap(find.text('Cobrar'));
    await tester.pump();

    final tap = taps().last;
    expect(tap.payload['widget'], 'ElevatedButton');
    expect(tap.payload['label'], 'Cobrar');
    expect(tap.payload['isTextInput'], false);
  });

  testWidgets('tap en TextField: label de decoración SÍ, contenido JAMÁS',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CobroPage()));
    await tester.tap(find.byKey(const Key('campo-cliente')));
    await tester.pump();

    final tap = taps().last;
    expect(tap.payload['isTextInput'], true);
    expect(tap.payload['label'], 'Cliente');
    expect(tap.payload.toString(), isNot(contains('dato sensible')));
  });

  testWidgets('retro-corrección: el tap fija la clase de página real',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: CobroPage()));
    // Simula que el observer no pudo resolver (ruta custom).
    ThorCore.instance!.recorder.currentScreen =
        const ScreenId(routeType: 'PageRouteBuilder');
    await tester.tap(find.text('Cobrar'));
    await tester.pump();

    expect(
      ThorCore.instance!.recorder.currentScreen?.widgetClass,
      'CobroPage',
    );
  });

  testWidgets('tap fuera de todo interactivo no genera evento', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Center(child: Text('nada')))),
    );
    final before = taps().length;
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(taps().length, before);
  });
}
