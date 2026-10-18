import 'package:test/test.dart';
import 'package:thor/thor.dart';

ThorEvent _e(int seq, ThorEventKind kind, Map<String, Object?> payload) =>
    ThorEvent(
      seq: seq,
      kind: kind,
      atUtc: DateTime.utc(2026, 10, 18, 12, 0, 0, seq * 100),
      utcOffset: Duration.zero,
      payload: payload,
    );

void main() {
  group('gestos en el reporte', () {
    test('el narrador describe scroll, swipe, borde, long press y foco', () {
      final text = ThorNarrator.narrate([
        _e(1, ThorEventKind.interaction, {
          'gesture': 'scroll',
          'dir': 'up',
          'distance': 320,
        }),
        _e(2, ThorEventKind.interaction, {'gesture': 'swipe', 'dir': 'left'}),
        _e(3, ThorEventKind.interaction, {'gesture': 'edge_swipe'}),
        _e(4, ThorEventKind.interaction, {
          'gesture': 'long_press',
          'widget': 'ListTile',
          'label': 'Pedido',
        }),
        _e(5, ThorEventKind.interaction, {
          'gesture': 'text_focus',
          'widget': 'TextField',
          'label': 'Cliente',
        }),
      ]);
      expect(text, contains('Desplazó la pantalla hacia arriba 320 px'));
      expect(text, contains('Deslizó hacia la izquierda'));
      expect(text, contains('gesto de atrás'));
      expect(text, contains('Mantuvo presionado «Pedido» (ListTile)'));
      expect(text, contains('Teclado abierto en «Cliente»'));
    });

    test('tres scrolls seguidos NO son toques repetidos (rage)', () {
      final scrolls = [
        for (var i = 1; i <= 4; i++)
          _e(i, ThorEventKind.interaction, {
            'gesture': 'scroll',
            'widget': 'Scrollable',
          }),
      ];
      expect(ThorAggregates.rageTaps(scrolls), isEmpty);
      final taps = [
        for (var i = 1; i <= 4; i++)
          _e(i, ThorEventKind.interaction, {
            'gesture': 'tap',
            'widget': 'Button',
            'label': 'Pagar',
          }),
      ];
      expect(ThorAggregates.rageTaps(taps), hasLength(1));
    });

    test('isPress: tap, long_press y los semánticos equivalentes', () {
      expect(ThorGesture.isPress(null), isTrue);
      expect(ThorGesture.isPress('tap'), isTrue);
      expect(ThorGesture.isPress('long_press'), isTrue);
      expect(ThorGesture.isPress('longPress'), isTrue);
      expect(ThorGesture.isPress('scroll'), isFalse);
      expect(ThorGesture.isPress('text_focus'), isFalse);
    });
  });

  group('ErrorText', () {
    test('hash de instancia fuera; # de issue y de frames intactos', () {
      expect(
        ErrorText.stripInstanceHashes(
          '_AddToCartWidgetState#cb997 y Row#0a1b2 ven Issue #12345 / #0 f',
        ),
        '_AddToCartWidgetState y Row ven Issue #12345 / #0 f',
      );
    });

    test('clip y clipStack', () {
      expect(ErrorText.clip('abcdef', 3), 'abc…(+3)');
      final stack = StackTrace.fromString(
        [for (var i = 0; i < 90; i++) '#$i f (package:a/a.dart:$i:1)']
            .join('\n'),
      );
      final out = ErrorText.clipStack(stack);
      expect(out.split('\n'), hasLength(61));
      expect(out, endsWith('…(+30 frames)'));
    });

    test('widget y archivo del causante de un overflow', () {
      final found = ErrorText.errorCausingWidget(
        'x\nThe relevant error-causing widget was:\n'
        '  Row Row:file:///a/lib/r.dart:8:3\nmás',
      );
      expect(found?.widget, 'Row');
      expect(found?.file, 'file:///a/lib/r.dart:8:3');
      expect(ErrorText.errorCausingWidget('sin pista'), isNull);
    });
  });
}
