import 'package:thor/src/model/event.dart';
import 'package:thor/src/model/gesture.dart';

/// Genera el ESQUELETO de un `integration_test` que reproduce la sesión.
///
/// Por qué existe: la regla de la casa es que un bug entra con el test que
/// lo reproduce, y hoy ese test lo escribe alguien a mano leyendo los
/// pasos del reporte. Thor ya tiene la secuencia exacta — puede escribir
/// el 80%.
///
/// **Es un esqueleto, no un test listo.** Deliberadamente:
/// - Los `find.text(...)` salen de la etiqueta capturada; si la pantalla
///   tiene textos repetidos hay que afinarlos.
/// - Los campos de texto se llenan con un placeholder: Thor NUNCA capturó
///   el contenido real (PII), así que el valor lo pone quien completa.
/// - La aserción final la escribe el dev: Thor sabe qué PASÓ, no qué
///   DEBERÍA pasar.
/// Cada punto queda marcado con `TODO` en el código generado.
class ThorReproTestBuilder {
  const ThorReproTestBuilder._();

  /// Construye el código Dart del test desde [timeline].
  ///
  /// [testName] es el nombre del `testWidgets`; [appWidget] el widget raíz
  /// que se monta (por defecto `App()`).
  static String build(
    List<ThorEvent> timeline, {
    String testName = 'repro',
    String appWidget = 'App()',
  }) {
    final body = <String>[];
    final steps = timeline.where(_isStep).toList();

    if (steps.isEmpty) {
      body.add('    // La sesión no tiene pasos de usuario que reproducir.');
    }

    ThorEvent? previous;
    for (final event in steps) {
      // Espera real entre pasos: un bug de carrera necesita ese ritmo.
      if (previous != null) {
        final gap = event.atUtc.difference(previous.atUtc);
        if (gap > const Duration(milliseconds: 800)) {
          final ms = gap.inMilliseconds;
          body.add(
            '    await tester.pump(const Duration(milliseconds: $ms));',
          );
        }
      }
      body.addAll(_stepLines(event));
      previous = event;
    }

    // Lo que ocurrió al final es lo que hay que afirmar.
    body
      ..add('')
      ..addAll(_outcomeComments(timeline))
      ..add('    // TODO(thor): afirmar aquí el resultado ESPERADO.')
      ..add("    // expect(find.text('...'), findsOneWidget);");

    return '''
// GENERADO POR THOR desde la línea de tiempo de una sesión real.
// Es un ESQUELETO: revisa los finders, pon los valores de los campos
// (Thor no captura contenido de texto por PII) y escribe la aserción.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('$testName', (tester) async {
    await tester.pumpWidget(const $appWidget);
    await tester.pumpAndSettle();

${body.join('\n')}
  });
}
''';
  }

  static bool _isStep(ThorEvent e) =>
      (e.kind == ThorEventKind.interaction &&
          ThorGesture.isPress(e.payload['gesture'])) ||
      (e.kind == ThorEventKind.navigation &&
          e.payload['action'] == 'push');

  static List<String> _stepLines(ThorEvent event) {
    if (event.kind == ThorEventKind.navigation) {
      final to = event.payload['to'] ?? event.screen?.display ?? '?';
      return ['    // → pantalla: $to'];
    }
    final label = event.payload['label'] as String?;
    final widget = event.payload['widget'] as String? ?? 'Widget';
    final isInput = event.payload['isTextInput'] == true;

    if (isInput) {
      final finder = label == null
          ? 'find.byType($widget)'
          : "find.widgetWithText($widget, '${_escape(label)}')";
      return [
        "    await tester.enterText($finder, 'TODO-valor');",
        '    await tester.pumpAndSettle();',
      ];
    }
    final action =
        event.payload['gesture'] == ThorGesture.longPress ? 'longPress' : 'tap';
    final tap = label == null
        ? '    await tester.$action(find.byType($widget)); '
            '// TODO(thor): finder sin etiqueta'
        : "    await tester.$action(find.text('${_escape(label)}'));";
    return [tap, '    await tester.pumpAndSettle();'];
  }

  /// Deja como comentarios lo que Thor observó al final — la evidencia de
  /// qué salió mal, para que la aserción se escriba con contexto.
  static List<String> _outcomeComments(List<ThorEvent> timeline) {
    final lines = <String>['    // Lo que Thor observó en la sesión real:'];
    for (final e in timeline) {
      switch (e.kind) {
        case ThorEventKind.network:
          final status = e.payload['statusCode'];
          final failed = e.payload['error'] != null ||
              (status is int && status >= 400);
          if (!failed) continue;
          lines.add(
            '    //   ✗ ${e.payload['method']} '
            '${Uri.tryParse(e.payload['url'] as String? ?? '')?.path ?? '?'} '
            '→ ${status ?? e.payload['error']}',
          );
        case ThorEventKind.error:
          lines.add(
            '    //   ✗ ${e.payload['type']}'
            '${e.origin == null ? '' : ' en ${e.origin}'}',
          );
        // Los demás tipos ya están en los pasos.
        // ignore: no_default_cases
        default:
          break;
      }
    }
    if (lines.length == 1) lines.add('    //   (sin fallos registrados)');
    return lines;
  }

  static String _escape(String value) => value.replaceAll("'", r"\'");
}
