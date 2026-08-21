import 'package:test/test.dart';
import 'package:thor/thor.dart';

ThorEvent _e(
  int seq,
  ThorEventKind kind,
  Map<String, Object?> payload, {
  String? origin,
  DateTime? at,
}) =>
    ThorEvent(
      seq: seq,
      kind: kind,
      atUtc: at ?? DateTime.utc(2026, 8, 21, 12, 0, seq),
      utcOffset: Duration.zero,
      origin: origin,
      payload: payload,
    );

void main() {
  group('ThorReproTestBuilder', () {
    test('convierte pasos reales en llamadas de flutter_test', () {
      final code = ThorReproTestBuilder.build(
        [
          _e(0, ThorEventKind.navigation, {
            'action': 'push',
            'to': 'LoginPage',
          }),
          _e(1, ThorEventKind.interaction, {
            'widget': 'TextField',
            'label': 'Correo',
            'isTextInput': true,
          }),
          _e(2, ThorEventKind.interaction, {
            'widget': 'ElevatedButton',
            'label': 'Iniciar sesión',
          }),
        ],
        testName: 'repro: login falla con 404',
      );

      expect(code, contains("testWidgets('repro: login falla con 404'"));
      expect(code, contains('// → pantalla: LoginPage'));
      expect(
        code,
        contains(
          "await tester.enterText(find.widgetWithText(TextField, 'Correo'), "
          "'TODO-valor');",
        ),
      );
      expect(
        code,
        contains("await tester.tap(find.text('Iniciar sesión'));"),
      );
      expect(code, contains('await tester.pumpAndSettle();'));
    });

    test('los fallos observados quedan como evidencia comentada', () {
      final code = ThorReproTestBuilder.build([
        _e(0, ThorEventKind.interaction, {'label': 'Cobrar'}),
        _e(1, ThorEventKind.network, {
          'method': 'POST',
          'url': 'https://api.x/orders',
          'statusCode': 500,
        }),
        _e(
          2,
          ThorEventKind.error,
          {'type': 'StateError'},
          origin: 'package:app/cobro.dart:88',
        ),
      ]);
      expect(code, contains('✗ POST /orders → 500'));
      expect(code, contains('✗ StateError en package:app/cobro.dart:88'));
      expect(code, contains('TODO(thor): afirmar aquí el resultado'));
    });

    test('las esperas largas se preservan (bugs de carrera)', () {
      final base = DateTime.utc(2026, 8, 21, 12);
      final code = ThorReproTestBuilder.build([
        _e(0, ThorEventKind.interaction, {'label': 'A'}, at: base),
        _e(
          1,
          ThorEventKind.interaction,
          {'label': 'B'},
          at: base.add(const Duration(seconds: 3)),
        ),
      ]);
      expect(
        code,
        contains('await tester.pump(const Duration(milliseconds: 3000));'),
      );
    });

    test('las esperas cortas NO ensucian el test', () {
      final base = DateTime.utc(2026, 8, 21, 12);
      final code = ThorReproTestBuilder.build([
        _e(0, ThorEventKind.interaction, {'label': 'A'}, at: base),
        _e(
          1,
          ThorEventKind.interaction,
          {'label': 'B'},
          at: base.add(const Duration(milliseconds: 200)),
        ),
      ]);
      expect(code, isNot(contains('milliseconds: 200')));
    });

    test('etiqueta con apóstrofo no rompe el código generado', () {
      final code = ThorReproTestBuilder.build([
        _e(0, ThorEventKind.interaction, {'label': "Añadir 'extra'"}),
      ]);
      expect(code, contains(r"find.text('Añadir \'extra\'')"));
    });

    test('sin pasos: esqueleto honesto, no test vacío engañoso', () {
      final code = ThorReproTestBuilder.build([]);
      expect(code, contains('no tiene pasos de usuario que reproducir'));
      expect(code, contains('(sin fallos registrados)'));
    });

    test('el contenido de los campos JAMÁS sale del reporte', () {
      // Aunque el payload trajera texto (no debería), el generador usa
      // placeholder: la PII no se filtra al test.
      final code = ThorReproTestBuilder.build([
        _e(0, ThorEventKind.interaction, {
          'widget': 'TextField',
          'label': 'Correo',
          'isTextInput': true,
          'value': 'ana@privado.com',
        }),
      ]);
      expect(code, contains('TODO-valor'));
      expect(code, isNot(contains('ana@privado.com')));
    });
  });
}
