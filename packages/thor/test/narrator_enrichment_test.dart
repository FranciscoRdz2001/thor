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
      atUtc: at ?? DateTime.utc(2026, 8, 19, 12, 0, seq),
      utcOffset: Duration.zero,
      origin: origin,
      payload: payload,
    );

void main() {
  group('Narrador enriquecido', () {
    test('pasos numerados llevan tiempo relativo al inicio', () {
      final base = DateTime.utc(2026, 8, 19, 12);
      final steps = ThorNarrator.narrate([
        _e(
          0,
          ThorEventKind.navigation,
          {'action': 'push', 'to': 'A'},
          at: base,
        ),
        _e(
          1,
          ThorEventKind.interaction,
          {'widget': 'X', 'label': 'Ir'},
          at: base.add(const Duration(milliseconds: 3200)),
        ),
      ]);
      expect(steps, contains('1. [+0.0s] Abrió A'));
      expect(steps, contains('2. [+3.2s] Tocó «Ir» (X)'));
    });

    test('petición FALLIDA muestra body redactado y origin', () {
      final steps = ThorNarrator.narrate([
        _e(
          0,
          ThorEventKind.network,
          {
            'method': 'POST',
            'url': 'https://api.x/orders',
            'statusCode': 422,
            'durationMs': 300,
            'responseBody': {'message': 'turno cerrado'},
          },
          origin: 'package:app/caja.dart:55',
        ),
      ]);
      expect(steps, contains('body: {"message":"turno cerrado"}'));
      expect(steps, contains('desde package:app/caja.dart:55'));
    });

    test('petición EXITOSA no arrastra body ni origin (ruido)', () {
      final steps = ThorNarrator.narrate([
        _e(
          0,
          ThorEventKind.network,
          {
            'method': 'GET',
            'url': 'https://api.x/products',
            'statusCode': 200,
            'durationMs': 80,
            'responseBody': {'items': <Object?>[]},
          },
          origin: 'package:app/catalogo.dart:10',
        ),
      ]);
      expect(steps, isNot(contains('body:')));
      expect(steps, isNot(contains('desde ')));
    });

    test('error con lastAction la muestra como detalle', () {
      final steps = ThorNarrator.narrate([
        _e(0, ThorEventKind.navigation, {'action': 'push', 'to': 'A'}),
        _e(1, ThorEventKind.error, {
          'type': 'StateError',
          'lastAction': 'tocó «Cobrar» (#7)',
        }),
      ]);
      expect(steps, contains('última acción: tocó «Cobrar» (#7)'));
    });

    test('señales de entorno: memoria, brightness y escala de texto', () {
      final steps = ThorNarrator.narrate([
        _e(0, ThorEventKind.navigation, {'action': 'push', 'to': 'A'}),
        _e(1, ThorEventKind.environment, {'signal': 'memoryPressure'}),
        _e(
          2,
          ThorEventKind.environment,
          {'signal': 'brightness', 'value': 'dark'},
        ),
        _e(
          3,
          ThorEventKind.environment,
          {'signal': 'textScale', 'value': '1.30'},
        ),
      ]);
      expect(steps, contains('Presión de memoria'));
      expect(steps, contains('Tema del sistema: dark'));
      expect(steps, contains('Escala de texto: 1.30'));
    });

    test('evento de jank narrado con conteo y peor frame', () {
      final steps = ThorNarrator.narrate([
        _e(0, ThorEventKind.navigation, {'action': 'push', 'to': 'A'}),
        _e(1, ThorEventKind.performance, {'slowFrames': 7, 'worstMs': 340}),
      ]);
      expect(steps, contains('Jank: 7 frames lentos (peor 340ms)'));
    });
  });

  group('Agregado slowFramesByScreen', () {
    test('acumula por pantalla y conserva el peor frame', () {
      ThorEvent perf(int seq, String screen, int slow, int worst) => ThorEvent(
            seq: seq,
            kind: ThorEventKind.performance,
            atUtc: DateTime.utc(2026),
            utcOffset: Duration.zero,
            screen: ScreenId(widgetClass: screen),
            payload: {'slowFrames': slow, 'worstMs': worst},
          );
      final stats = ThorAggregates.slowFramesByScreen([
        perf(0, 'CatalogoPage', 5, 120),
        perf(1, 'CatalogoPage', 3, 340),
        perf(2, 'CobroPage', 4, 90),
      ]);
      expect(
        stats['CatalogoPage'],
        {'slowFrames': 8, 'worstMs': 340},
      );
      expect(stats['CobroPage'], {'slowFrames': 4, 'worstMs': 90});
    });
  });

  group('EventStore.lastOfKind', () {
    test('devuelve el último de la familia o null', () {
      final store = EventStore()
        ..add(_e(0, ThorEventKind.interaction, {'label': 'a'}))
        ..add(_e(1, ThorEventKind.interaction, {'label': 'b'}));
      expect(
        store.lastOfKind(ThorEventKind.interaction)!.payload['label'],
        'b',
      );
      expect(store.lastOfKind(ThorEventKind.error), isNull);
    });
  });
}
