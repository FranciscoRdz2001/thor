import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/src/replay/wireframe.dart';

/// PNG 1×1 transparente: una imagen real sin red ni assets.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

const _red = Color(0xFFFF0000);
const _blue = Color(0xFF0000FF);

void main() {
  List<List<Object?>> ops({bool imageUrls = false}) =>
      WireframeBuilder(maskText: true, imageUrls: imageUrls).build()!.ops;

  List<List<Object?>> kind(String k, {bool imageUrls = false}) => [
        for (final op in ops(imageUrls: imageUrls))
          if (op[0] == k) op,
      ];

  /// Rects con el color [c] (el fondo del Scaffold también es un rect).
  List<List<Object?>> rectsOf(Color c) => [
        for (final op in kind('r'))
          if (op[6] == c.toARGB32()) op,
      ];

  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Center(child: child))),
      );

  group('serialización de siempre (hash de bloque estable)', () {
    testWidgets('rect, imagen y campo sin nada nuevo no cambian',
        (tester) async {
      await pump(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 40, height: 20, color: _red),
            Container(
              width: 40,
              height: 20,
              decoration: BoxDecoration(
                color: _blue,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(width: 2),
              ),
            ),
            const RawImage(width: 20, height: 20),
            SizedBox(
              width: 100,
              child: TextField(controller: TextEditingController(text: 'ab')),
            ),
          ],
        ),
      );
      expect(rectsOf(_red).single, hasLength(10));
      expect(
        rectsOf(_red).single.sublist(6),
        [_red.toARGB32(), null, null, null],
      );
      expect(
        rectsOf(_blue).single.sublist(6),
        [_blue.toARGB32(), 6.0, 0xFF000000, 2.0],
      );
      expect(kind('m').single, hasLength(6));
      expect(kind('f').single, hasLength(7));
      expect(kind('f').single.last, 2);
      // El borde del TextField no es un gráfico: el campo ya lo dibuja.
      expect(kind('g'), isEmpty);
    });
  });

  group('degradados y sombras', () {
    testWidgets('el degradado viaja compacto; el color sigue siendo el 1º',
        (tester) async {
      await pump(
        tester,
        Container(
          width: 40,
          height: 20,
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [_red, _blue]),
          ),
        ),
      );
      final op = rectsOf(_red).single;
      expect(op, hasLength(12));
      expect(op[10], isNull); // sin sombra
      expect(op[11], [
        0,
        [_red.toARGB32(), _blue.toARGB32()],
        null,
        -1,
        0,
        1,
        0,
      ]);
    });

    testWidgets('radial con stops', (tester) async {
      await pump(
        tester,
        Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              colors: [_red, _blue],
              stops: [0.25, 1],
              radius: 0.7,
            ),
          ),
        ),
      );
      expect(rectsOf(_red).single[11], [
        1,
        [_red.toARGB32(), _blue.toARGB32()],
        [0.25, 1],
        0,
        0,
        0.7,
      ]);
    });

    testWidgets('boxShadow → elevación; sin degradado no hay posición 11',
        (tester) async {
      await pump(
        tester,
        Container(
          width: 40,
          height: 20,
          decoration: const BoxDecoration(
            color: _red,
            boxShadow: [BoxShadow(blurRadius: 8), BoxShadow(blurRadius: 2)],
          ),
        ),
      );
      final op = rectsOf(_red).single;
      expect(op, hasLength(11));
      expect(op[10], 4);
    });

    testWidgets('Card: radio de su forma y elevación', (tester) async {
      await pump(
        tester,
        const Card(
          color: _red,
          elevation: 3,
          child: SizedBox(width: 100, height: 50),
        ),
      );
      final op = rectsOf(_red).single;
      expect(op[7], 12); // RoundedRectangleBorder de Material 3
      expect(op[10], 3);
    });

    testWidgets('Scaffold (Material recta, sin elevación) no cambia',
        (tester) async {
      await pump(tester, const SizedBox());
      final material = kind('r').firstWhere((op) => op[7] == null);
      expect(material, hasLength(10));
    });

    testWidgets('PhysicalModel: elevación y círculo', (tester) async {
      await pump(
        tester,
        const PhysicalModel(
          color: _red,
          elevation: 6,
          shape: BoxShape.circle,
          child: SizedBox(width: 60, height: 40),
        ),
      );
      final op = rectsOf(_red).single;
      // El círculo se pinta inscrito: cuadrado del lado corto, centrado.
      expect(op.sublist(1, 5), [380, 280, 40, 40]);
      expect(op[7], 20);
      expect(op[10], 6);
    });
  });

  group('recortes', () {
    testWidgets('ClipRRect redondea el rect que lo cubre', (tester) async {
      await pump(
        tester,
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(width: 80, height: 40, color: _red),
        ),
      );
      expect(rectsOf(_red).single[7], 12);
    });

    testWidgets('ClipRRect no redondea a un hijo más chico', (tester) async {
      await pump(
        tester,
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 80,
            height: 40,
            child: Align(
              child: Container(width: 20, height: 20, color: _red),
            ),
          ),
        ),
      );
      expect(rectsOf(_red).single[7], isNull);
    });

    testWidgets('ClipOval: imagen de avatar con radio, sin URL',
        (tester) async {
      await pump(
        tester,
        const ClipOval(child: RawImage(width: 40, height: 40)),
      );
      expect(kind('m').single.sublist(5), [0, null, 20]);
    });

    testWidgets('ClipOval con imageUrls: url y radio', (tester) async {
      await pump(
        tester,
        ClipOval(child: Image.memory(_png, width: 40, height: 40)),
      );
      final op = kind('m', imageUrls: true).single;
      expect(op, hasLength(8));
      expect(op[7], 20);
    });

    testWidgets('CircleAvatar: círculo + imagen de fondo sin URL',
        (tester) async {
      await pump(
        tester,
        CircleAvatar(
          radius: 20,
          backgroundColor: _red,
          backgroundImage: MemoryImage(_png),
        ),
      );
      final circle = rectsOf(_red).single;
      expect(circle.sublist(1, 5), [380, 280, 40, 40]);
      expect(circle[7], 20);
      expect(kind('m').single.sublist(1), [380, 280, 40, 40, 0, null, 20]);
    });
  });

  group('transforms', () {
    Widget rotated(double angle) => Transform.rotate(
          angle: angle,
          child: Container(width: 40, height: 20, color: _red),
        );

    testWidgets('rotado: caja real centrada, no la envolvente', (tester) async {
      await pump(tester, rotated(math.pi / 4));
      expect(rectsOf(_red).single.sublist(1, 5), [380, 290, 40, 20]);
    });

    testWidgets('una rotación animada da el mismo op en cada cuadro',
        (tester) async {
      await pump(tester, rotated(0.3));
      final a = jsonEncode(rectsOf(_red));
      await pump(tester, rotated(1.1));
      expect(jsonEncode(rectsOf(_red)), a);
    });

    testWidgets('90° y escala usan la envolvente exacta', (tester) async {
      await pump(tester, rotated(math.pi / 2));
      expect(rectsOf(_red).single.sublist(1, 5), [390, 280, 20, 40]);
      await pump(
        tester,
        Transform.scale(
          scale: 2,
          child: Container(width: 40, height: 20, color: _red),
        ),
      );
      expect(rectsOf(_red).single.sublist(1, 5), [360, 280, 80, 40]);
    });
  });

  group('gráficos', () {
    testWidgets('CustomPaint y progreso → caja g tipo 0', (tester) async {
      await pump(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(size: const Size(50, 30), painter: _Painter()),
            const SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(value: 0.5),
            ),
            const Checkbox(value: true, onChanged: null),
          ],
        ),
      );
      final g = kind('g');
      expect(g, hasLength(3));
      expect(g.first.sublist(3), [50, 30, 0, 0]);
      expect(g.every((op) => op.length == 7 && op[6] == 0), isTrue);
    });

    testWidgets('scrollbar, tabs y overscroll no son gráficos', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DefaultTabController(
            length: 2,
            child: Scaffold(
              appBar: AppBar(
                bottom: const TabBar(tabs: [Tab(text: 'A'), Tab(text: 'B')]),
              ),
              body: Scrollbar(
                thumbVisibility: true,
                child: ListView(
                  children: [
                    for (var i = 0; i < 30; i++) Text('fila $i'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(kind('g'), isEmpty);
    });

    testWidgets('render de SVG (vector_graphics) → g tipo 1', (tester) async {
      await pump(tester, const SizedBox(width: 24, height: 24, child: _Svg()));
      expect(kind('g').single.sublist(3), [24, 24, 0, 1]);
    });

    testWidgets('vista nativa (mapa, webview) → g tipo 2', (tester) async {
      await pump(
        tester,
        const SizedBox(width: 120, height: 80, child: _NativeView()),
      );
      expect(kind('g').single.sublist(3), [120, 80, 0, 2]);
    });

    testWidgets('g dentro de un recorte lleva radio', (tester) async {
      await pump(
        tester,
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CustomPaint(size: const Size(50, 30), painter: _Painter()),
        ),
      );
      expect(kind('g').single.sublist(6), [0, 8]);
    });
  });

  group('campos de texto', () {
    testWidgets('vacío con hint: largo del hint, nunca contenido',
        (tester) async {
      await pump(
        tester,
        const SizedBox(
          width: 200,
          child: TextField(
            decoration: InputDecoration(hintText: 'Busca productos'),
          ),
        ),
      );
      expect(kind('f').single.sublist(6), [0, 15]);
    });

    testWidgets('con texto: largo del texto, sin hint ni contenido',
        (tester) async {
      await pump(
        tester,
        const SizedBox(
          width: 200,
          child: TextField(
            decoration: InputDecoration(hintText: 'Busca productos'),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'secreto');
      await tester.pump();
      final field = kind('f').single;
      expect(field, hasLength(7));
      expect(field[6], 7);
      expect(jsonEncode(ops()), isNot(contains('secreto')));
    });

    testWidgets('contraseña: el largo real jamás viaja', (tester) async {
      await pump(
        tester,
        const SizedBox(width: 200, child: TextField(obscureText: true)),
      );
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pump();
      expect(kind('f').single[6], 8);
      await tester.enterText(find.byType(TextField), 'una-clave-muy-larga');
      await tester.pump();
      expect(kind('f').single[6], 8);
    });

    // Texto visible (el default del replay): como un video, lo escrito se
    // ve — salvo en un campo sensible, en NINGÚN modo.
    List<List<Object?>> visibleFields() => [
          for (final op in WireframeBuilder(maskText: false).build()!.ops)
            if (op[0] == 'f') op,
        ];

    testWidgets('visible: un campo normal manda lo escrito', (tester) async {
      await pump(tester, const SizedBox(width: 200, child: TextField()));
      await tester.enterText(find.byType(TextField), 'leche deslactosada');
      await tester.pump();
      expect(visibleFields().single.sublist(6), [18, 'leche deslactosada']);
    });

    testWidgets('visible: un campo vacío no cambia de forma', (tester) async {
      await pump(
        tester,
        const SizedBox(
          width: 200,
          child: TextField(
            decoration: InputDecoration(hintText: 'Busca productos'),
          ),
        ),
      );
      expect(visibleFields().single.sublist(6), [0, 15]);
    });

    for (final (name, field) in [
      ('obscureText', const TextField(obscureText: true)),
      (
        'teclado de contraseña visible',
        const TextField(keyboardType: TextInputType.visiblePassword),
      ),
      (
        'autofill de contraseña',
        const TextField(autofillHints: [AutofillHints.password]),
      ),
      (
        'autofill de tarjeta',
        const TextField(autofillHints: [AutofillHints.creditCardNumber]),
      ),
    ]) {
      testWidgets('visible: campo sensible ($name) jamás manda contenido',
          (tester) async {
        await pump(tester, SizedBox(width: 200, child: field));
        await tester.enterText(find.byType(TextField), 'hunter2-4111');
        await tester.pump();
        final f = visibleFields().single;
        expect(f.sublist(6), [8], reason: 'solo "lleno", largo fijo');
        final all = jsonEncode(WireframeBuilder(maskText: false).build()!.ops);
        expect(all, isNot(contains('hunter2')));
      });
    }
  });
}

class _Painter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(_Painter oldDelegate) => false;
}

/// Imita a `vector_graphics` (lo que usa flutter_svg 2): el SDK reconoce
/// el render por nombre, sin depender del paquete.
class _Svg extends LeafRenderObjectWidget {
  const _Svg();

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderVectorGraphic();
}

// El nombre ES la prueba: así se llama el render de vector_graphics.
// ignore: public_member_api_docs
class RenderVectorGraphic extends RenderBox {
  @override
  void performLayout() => size = constraints.biggest;
}

class _NativeView extends LeafRenderObjectWidget {
  const _NativeView();

  @override
  RenderObject createRenderObject(BuildContext context) =>
      PlatformViewRenderBox(
        controller: _FakeController(),
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        gestureRecognizers: const {},
      );
}

class _FakeController extends PlatformViewController {
  @override
  int get viewId => 7;

  @override
  Future<void> clearFocus() async {}

  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async {}

  @override
  Future<void> dispose() async {}
}
