import 'package:test/test.dart';
import 'package:thor/thor.dart';

void main() {
  group('RedactionPolicy — fail-closed', () {
    const strict = RedactionPolicy.strict();

    test('valor sin clave amparada se redacta (default cerrado)', () {
      expect(
        strict.redactValue({'telefono': '6641234567'}),
        {'telefono': RedactionPolicy.redactedMarker},
      );
    });

    test('hard-deny gana aunque la clave esté en la allowlist', () {
      const generosa = RedactionPolicy(allowedKeys: {'authorization', 'token'});
      expect(generosa.isKeyAllowed('Authorization'), isFalse);
      expect(generosa.isKeyAllowed('token'), isFalse);
      expect(
        generosa.redactFlatMap({'Authorization': 'Bearer abc'}),
        {'Authorization': RedactionPolicy.redactedMarker},
      );
    });

    test('hard-deny es case/separator-insensitive (X-Api-Key, access-token)',
        () {
      const p = RedactionPolicy(allowedKeys: {'x_api_key', 'access-token'});
      expect(p.isKeyAllowed('X-Api-Key'), isFalse);
      expect(p.isKeyAllowed('ACCESS_TOKEN'), isFalse);
    });

    test('anidado: conserva la forma, redacta los valores no amparados', () {
      const p = RedactionPolicy(allowedKeys: {'status'});
      final out = p.redactValue({
        'status': 'ok',
        'cliente': {'nombre': 'Ana', 'status': 'activo'},
        'items': [
          {'precio': 100},
        ],
      });
      expect(out, {
        'status': 'ok',
        'cliente': {
          'nombre': RedactionPolicy.redactedMarker,
          'status': 'activo',
        },
        'items': [
          {'precio': RedactionPolicy.redactedMarker},
        ],
      });
    });

    test('lista de escalares sin amparo se redacta elemento a elemento', () {
      expect(
        strict.redactValue(['6641234567', 'ana@mail.com']),
        [RedactionPolicy.redactedMarker, RedactionPolicy.redactedMarker],
      );
    });

    test('null pasa como null (no hay nada que fugar)', () {
      expect(strict.redactValue(null), isNull);
      expect(strict.redactValue({'status': null}), {'status': null});
    });

    test('valores permitidos largos se truncan con sufijo contable', () {
      const p = RedactionPolicy(allowedKeys: {'message'}, maxValueLength: 5);
      final out = p.redactValue({'message': 'abcdefghij'})! as Map;
      expect(out['message'], 'abcde…(+5)');
    });

    test('claves no-String en mapas dinámicos no revientan', () {
      final out = strict.redactValue({1: 'x', true: 'y'})! as Map;
      expect(out.keys, containsAll(<String>['1', 'true']));
    });
  });
}
