import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

class TabShellPage extends StatelessWidget {
  const TabShellPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: const FavoritosBody(),
        bottomNavigationBar: TextButton(
          onPressed: () {},
          child: const Text('Favoritos'),
        ),
      );
}

class FavoritosBody extends StatelessWidget {
  const FavoritosBody({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox.expand(
        child: ColoredBox(color: Colors.white, child: Text('lista')),
      );
}

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

  testWidgets(
      'un tap en la barra de tabs no baja la pantalla fijada por el árbol',
      (tester) async {
    ScreenCapture.install();
    await tester.pumpWidget(const MaterialApp(home: TabShellPage()));
    ScreenCapture.check();
    final recorder = ThorCore.instance!.recorder;
    expect(recorder.currentScreen?.widgetClass, 'FavoritosBody');

    await tester.tap(find.text('Favoritos'));
    await tester.pump(const Duration(milliseconds: 400));

    // La barra vive en TabShellPage, pero la pantalla real es la tab.
    expect(recorder.currentScreen?.widgetClass, 'FavoritosBody');
    ScreenCapture.uninstall();
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

  group('gestos', () {
    Widget list() => MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                for (var i = 0; i < 40; i++) ListTile(title: Text('Fila $i')),
              ],
            ),
          ),
        );

    testWidgets('scroll: dirección, distancia, ejes y duración, sin tap',
        (tester) async {
      await tester.pumpWidget(list());
      await tester.drag(find.text('Fila 3'), const Offset(0, -200));
      await tester.pump();
      final ev = taps().single.payload;
      expect(ev['gesture'], 'scroll');
      expect(ev['axis'], 'vertical');
      expect(ev['dir'], 'up');
      expect(ev['distance'], 200);
      expect(ev['start'], isA<List<Object?>>());
      expect(ev['durationMs'], isA<int>());
    });

    testWidgets('varios arrastres seguidos se funden en un evento',
        (tester) async {
      await tester.pumpWidget(list());
      await tester.drag(find.text('Fila 3'), const Offset(0, -100));
      await tester.drag(find.text('Fila 9'), const Offset(0, -100));
      await tester.pump();
      expect(
        taps().where((e) => e.payload['gesture'] == 'scroll'),
        hasLength(1),
      );
    });

    testWidgets('swipe fuera de lo desplazable', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('quieta'))),
        ),
      );
      await tester.dragFrom(const Offset(200, 300), const Offset(120, 0));
      await tester.pump();
      final ev = taps().single.payload;
      expect(ev['gesture'], 'swipe');
      expect(ev['dir'], 'right');
      expect(ev['distance'], 120);
    });

    testWidgets('gesto de borde = edge_swipe (atrás de iOS)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('quieta'))),
        ),
      );
      await tester.dragFrom(const Offset(4, 300), const Offset(200, 0));
      await tester.pump();
      final ev = taps().single.payload;
      expect(ev['gesture'], 'edge_swipe');
      expect(ev['edge'], 'left');
      expect(ev['dir'], 'right');
    });

    testWidgets('edge_swipe sin pop no lleva popped; con pop a medio gesto sí',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('quieta'))),
        ),
      );
      await tester.dragFrom(const Offset(4, 300), const Offset(200, 0));
      await tester.pump();
      expect(taps().single.payload.containsKey('popped'), isFalse);

      final gesture = await tester.startGesture(const Offset(4, 300));
      await gesture.moveBy(const Offset(120, 0));
      // La pantalla retrocede mientras el dedo sigue abajo.
      ThorCore.instance!.recorder.record(ThorEventKind.navigation, {
        'action': 'pop',
        'to': 'A',
        'from': 'B',
      });
      await gesture.moveBy(const Offset(120, 0));
      await gesture.up();
      await tester.pump();
      expect(taps().last.payload['gesture'], 'edge_swipe');
      expect(taps().last.payload['popped'], true);
    });

    testWidgets('un toque en la barrera de un diálogo no es de la página de '
        'atrás; dentro del diálogo sí', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  ElevatedButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => AlertDialog(
                        content: const Text('Frutas'),
                        actions: [
                          TextButton(
                            onPressed: () {},
                            child: const Text('Cerrar'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('Abrir'),
                  ),
                  const Spacer(),
                  const Text('Frutas Cítricas'),
                  TextButton(
                    onPressed: () {},
                    child: const Text('Detrás'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      final before = taps().length;

      // Dentro del diálogo: el botón del diálogo.
      await tester.tap(find.text('Cerrar'), warnIfMissed: false);
      await tester.pump();
      expect(taps().last.payload['label'], 'Cerrar');

      // En la barrera, justo sobre un botón de la página de atrás.
      await tester.tapAt(tester.getCenter(find.text('Detrás')));
      await tester.pump();
      final last = taps().last.payload;
      expect(taps().length, greaterThan(before + 1));
      expect(last['widget'], 'ModalBarrier');
      expect(last['label'], 'barrier');
      expect(last['label'], isNot('Detrás'));
    });

    testWidgets('long press: tap sostenido, no tap', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CobroPage()));
      await tester.longPress(find.text('Cobrar'));
      await tester.pump();
      final ev = taps().single.payload;
      expect(ev['gesture'], 'long_press');
      expect(ev['label'], 'Cobrar');
      expect(ev['durationMs'], greaterThanOrEqualTo(500));
    });

    testWidgets('un arrastre que termina sobre un botón NO es un tap',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CobroPage()));
      await tester.dragFrom(
        tester.getTopLeft(find.text('Cobrar')) + const Offset(0, -120),
        const Offset(0, 100),
      );
      await tester.pump();
      expect(taps().where((e) => e.payload['gesture'] == 'tap'), isEmpty);
    });

    testWidgets('foco de campo: etiqueta sí, texto jamás', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CobroPage()));
      await tester.showKeyboard(find.byKey(const Key('campo-cliente')));
      await tester.pump();
      final focus =
          taps().lastWhere((e) => e.payload['gesture'] == 'text_focus');
      expect(focus.payload['widget'], 'TextField');
      expect(focus.payload['label'], 'Cliente');
      expect(focus.payload.toString(), isNot(contains('dato sensible')));
    });

    testWidgets('campo de contraseña marca obscure', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TextField(
              key: Key('pass'),
              obscureText: true,
              decoration: InputDecoration(labelText: 'Clave'),
            ),
          ),
        ),
      );
      await tester.showKeyboard(find.byKey(const Key('pass')));
      await tester.pump();
      final focus =
          taps().lastWhere((e) => e.payload['gesture'] == 'text_focus');
      expect(focus.payload['obscure'], true);
    });
  });

  group('etiquetas de toques sin texto', () {
    String? labelAt(WidgetTester tester, Finder f) =>
        InteractionCapture.describeHitForTest(tester.getCenter(f))?.label;

    testWidgets('botón de atrás por ícono: nombre, no código', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              key: const Key('atras'),
              onTap: () {},
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.arrow_back_ios),
              ),
            ),
          ),
        ),
      );
      expect(
        labelAt(tester, find.byKey(const Key('atras'))),
        'icono:arrow_back_ios',
      );
    });

    testWidgets('Semantics label gana a un ícono', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              key: const Key('chat'),
              onTap: () {},
              child: Semantics(
                label: 'Abrir chat',
                child: const Icon(Icons.chat),
              ),
            ),
          ),
        ),
      );
      expect(labelAt(tester, find.byKey(const Key('chat'))), 'Abrir chat');
    });

    testWidgets('carrito con insignia: el ícono, no el "1"', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              key: const Key('cart'),
              onTap: () {},
              child: const Stack(
                children: [
                  Icon(Icons.shopping_cart),
                  Text('1'),
                ],
              ),
            ),
          ),
        ),
      );
      expect(
        labelAt(tester, find.byKey(const Key('cart'))),
        'icono:shopping_cart',
      );
    });

    testWidgets('contador solo: queda como último recurso', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              key: const Key('solo'),
              onTap: () {},
              child: const Text('3'),
            ),
          ),
        ),
      );
      expect(labelAt(tester, find.byKey(const Key('solo'))), '3');
    });

    testWidgets('ícono desconocido sale con su código hex', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GestureDetector(
              key: const Key('raro'),
              onTap: () {},
              child: const Icon(IconData(0xf0000, fontFamily: 'MaterialIcons')),
            ),
          ),
        ),
      );
      expect(labelAt(tester, find.byKey(const Key('raro'))), 'icono:f0000');
    });

    testWidgets('GestureDetector vacío: tooltip de su envoltura',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Tooltip(
                message: 'Cerrar',
                child: GestureDetector(
                  key: const Key('vacio'),
                  onTap: () {},
                  child: const SizedBox(width: 24, height: 24),
                ),
              ),
            ),
          ),
        ),
      );
      expect(labelAt(tester, find.byKey(const Key('vacio'))), 'Cerrar');
    });

    testWidgets('GestureDetector vacío: el Text cercano, no el de la página',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Text('Texto lejano de la página'),
                const SizedBox(height: 300),
                Center(
                  child: SizedBox(
                    width: 120,
                    height: 40,
                    child: Stack(
                      children: [
                        const Text('Aplicar'),
                        GestureDetector(
                          key: const Key('vacio'),
                          onTap: () {},
                          child: const SizedBox(width: 120, height: 40),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(labelAt(tester, find.byKey(const Key('vacio'))), 'Aplicar');
    });
  });
}
