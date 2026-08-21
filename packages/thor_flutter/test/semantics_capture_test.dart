import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

/// Una sesión manejada por lector de pantalla (o por un arnés de QA que
/// habla semántica) salía SIN un solo paso: el `PointerRouter` no ve esas
/// acciones. El reporte concluía "el usuario no tocó nada".
void main() {
  setUp(() async {
    ThorCore.debugReset();
    await ThorCore.init();
    SemanticsInteractionCapture.install();
  });

  tearDown(() {
    SemanticsInteractionCapture.uninstall();
    ThorCore.debugReset();
  });

  List<ThorEvent> interactions() =>
      ThorCore.instance!.store.ofKind(ThorEventKind.interaction);

  testWidgets('un tap por semántica queda registrado con su etiqueta',
      (tester) async {
    final handle = tester.ensureSemantics();
    var pressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ElevatedButton(
            onPressed: () => pressed = true,
            child: const Text('Cobrar'),
          ),
        ),
      ),
    );

    final node = tester.getSemantics(find.text('Cobrar'));
    _dispatch(tester, node.id, SemanticsAction.tap);
    await tester.pump();

    expect(pressed, isTrue, reason: 'el observador NO debe estorbar');
    final event = interactions().single;
    expect(event.payload['gesture'], 'tap');
    expect(event.payload['label'], 'Cobrar');
    expect(event.payload['widget'], 'Button');
    expect(
      event.payload['via'],
      'semantics',
      reason: 'distinguir la vía cambia cómo se lee el reporte',
    );
    handle.dispose();
  });

  testWidgets('el foco del lector de pantalla NO ensucia la línea de tiempo',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Total'))),
    );

    final node = tester.getSemantics(find.text('Total'));
    _dispatch(tester, node.id, SemanticsAction.didGainAccessibilityFocus);
    await tester.pump();

    expect(
      interactions(),
      isEmpty,
      reason: 'mover el foco no es una decisión del usuario',
    );
    handle.dispose();
  });

  testWidgets('un campo de texto se distingue de un botón', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TextField(
            decoration: InputDecoration(labelText: 'Correo'),
          ),
        ),
      ),
    );

    // El nodo con la bandera isTextField es el del EditableText;
    // find.byType(TextField) sube al envolvente, que no la lleva. El
    // árbol que ve el lector de pantalla expone este.
    final node = tester.getSemantics(find.byType(EditableText));
    _dispatch(tester, node.id, SemanticsAction.tap);
    await tester.pump();

    expect(interactions().single.payload['widget'], 'TextField');
    handle.dispose();
  });

  testWidgets('sin Thor activo no graba ni revienta', (tester) async {
    SemanticsInteractionCapture.uninstall();
    ThorCore.debugReset();
    SemanticsInteractionCapture.install();

    final handle = tester.ensureSemantics();
    var pressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ElevatedButton(
            onPressed: () => pressed = true,
            child: const Text('x'),
          ),
        ),
      ),
    );
    final node = tester.getSemantics(find.text('x'));
    _dispatch(tester, node.id, SemanticsAction.tap);
    await tester.pump();

    expect(pressed, isTrue);
    expect(ThorCore.instance, isNull);
    handle.dispose();
  });

  testWidgets('install es idempotente (no duplica eventos)', (tester) async {
    SemanticsInteractionCapture.install();
    SemanticsInteractionCapture.install();

    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ElevatedButton(onPressed: () {}, child: const Text('y')),
        ),
      ),
    );
    final node = tester.getSemantics(find.text('y'));
    _dispatch(tester, node.id, SemanticsAction.tap);
    await tester.pump();

    expect(interactions(), hasLength(1));
    handle.dispose();
  });
}

/// Entra por donde entra el engine: `onSemanticsActionEvent` es el handler
/// del binding que notifica a los listeners Y LUEGO ejecuta la acción.
/// Llamar a `semanticsOwner.performAction` directo salta ese paso — es el
/// tramo de abajo, no el evento.
void _dispatch(WidgetTester tester, int nodeId, SemanticsAction action) {
  ui.PlatformDispatcher.instance.onSemanticsActionEvent!(
    ui.SemanticsActionEvent(
      type: action,
      nodeId: nodeId,
      viewId: tester.view.viewId,
    ),
  );
}
