import 'package:clock/clock.dart';
import 'package:test/test.dart';
import 'package:thor/log.dart' as thor_log;
import 'package:thor/thor.dart';

/// Reloj manual para los topes de ráfaga.
class _Time {
  DateTime now = DateTime.utc(2026, 10, 17, 12);
  void advance(int ms) => now = now.add(Duration(milliseconds: ms));
}

ThorEvent _e(int seq, Map<String, Object?> payload) => ThorEvent(
      seq: seq,
      kind: ThorEventKind.log,
      atUtc: DateTime.utc(2026, 10, 17, 12, 0, seq),
      utcOffset: Duration.zero,
      payload: payload,
    );

void main() {
  group('RedactionPolicy.scrubSecrets', () {
    test('valor de clave de secreto en query, JSON y header', () {
      const m = RedactionPolicy.redactedMarker;
      expect(
        RedactionPolicy.scrubSecrets('GET /api?token=abc123&page=2'),
        'GET /api?token=$m&page=2',
      );
      expect(
        RedactionPolicy.scrubSecrets('{"password": "hunter2", "user": "ana"}'),
        '{"password": "$m", "user": "ana"}',
      );
      expect(
        RedactionPolicy.scrubSecrets('Authorization: Bearer eyJhbGciOi.x.y'),
        'Authorization: Bearer $m',
      );
      expect(
        RedactionPolicy.scrubSecrets('authToken=XYZ client_secret: s3cr3t'),
        'authToken=$m client_secret: $m',
      );
      expect(RedactionPolicy.scrubSecrets('PIN=1234'), 'PIN=$m');
    });

    test('Bearer y Basic sueltos', () {
      const m = RedactionPolicy.redactedMarker;
      expect(
        RedactionPolicy.scrubSecrets('headers bearer abcdefgh12345 ok'),
        'headers bearer $m ok',
      );
      expect(
        RedactionPolicy.scrubSecrets('auth Basic dXNlcjpwYXNz=='),
        'auth Basic $m',
      );
    });

    test('no toca texto normal', () {
      const texts = [
        'Basic information about shipping=3',
        'Total: 300 pesos',
        'https://h.com/p?page=2',
        'shipping_pin=4',
      ];
      for (final t in texts) {
        expect(RedactionPolicy.scrubSecrets(t), t);
      }
    });

    test('scrubText también quita secretos (labels y logs)', () {
      expect(
        RedactionPolicy.scrubText('login ana@x.com password=abc 5512345678'),
        'login :email password=${RedactionPolicy.redactedMarker} :n',
      );
    });
  });

  group('ThorLogLevel', () {
    test('infer: error y warn por texto, lo demás fallback', () {
      expect(ThorLogLevel.infer('Error al cobrar'), ThorLogLevel.error);
      expect(ThorLogLevel.infer('[O2O] falló (ignorado)'), ThorLogLevel.error);
      expect(ThorLogLevel.infer('⚠ token por vencer'), ThorLogLevel.warn);
      expect(ThorLogLevel.infer('Warning: deprecated'), ThorLogLevel.warn);
      expect(ThorLogLevel.infer('onErrorX listo'), ThorLogLevel.debug);
      expect(
        ThorLogLevel.infer('cargando', fallback: ThorLogLevel.info),
        ThorLogLevel.info,
      );
    });

    test('fromNumeric sigue la escala de package:logging', () {
      expect(ThorLogLevel.fromNumeric(0), ThorLogLevel.info);
      expect(ThorLogLevel.fromNumeric(500), ThorLogLevel.debug);
      expect(ThorLogLevel.fromNumeric(800), ThorLogLevel.info);
      expect(ThorLogLevel.fromNumeric(900), ThorLogLevel.warn);
      expect(ThorLogLevel.fromNumeric(1000), ThorLogLevel.error);
    });
  });

  group('ThorCore.log', () {
    tearDown(ThorCore.debugReset);

    test(
        'por defecto (solo secretos): emails y teléfonos legibles, '
        'secretos fuera', () async {
      final core = await ThorCore.init();
      core.log(
        'usuario ana@x.com tel 55 1234 5678 Bearer abcdefghijk123',
        level: ThorLogLevel.warn,
        error: 'fallo token=xyz pedido 10293847',
      );
      final p = core.store.ofKind(ThorEventKind.log).single.payload;
      expect(
        p['message'],
        'usuario ana@x.com tel 55 1234 5678 Bearer '
        '${RedactionPolicy.redactedMarker}',
      );
      expect(
        p['error'],
        'fallo token=${RedactionPolicy.redactedMarker} pedido 10293847',
      );
      await core.dispose();
    });

    test('strict: graba level/source/message limpios de datos personales',
        () async {
      final core = await ThorCore.init(
        redaction: const RedactionPolicy.strict(),
      );
      core.log(
        'usuario ana@x.com tel 55 1234 5678 Bearer abcdefghijk123',
        level: ThorLogLevel.warn,
        source: 'print',
        name: 'auth',
        error: 'fallo token=xyz',
      );
      final p = core.store.ofKind(ThorEventKind.log).single.payload;
      expect(p['level'], 'warn');
      expect(p['source'], 'print');
      expect(p['name'], 'auth');
      expect(
        p['message'],
        'usuario :email tel :n Bearer ${RedactionPolicy.redactedMarker}',
      );
      expect(p['error'], 'fallo token=${RedactionPolicy.redactedMarker}');
      await core.dispose();
    });

    test('trunca al largo máximo de la política', () async {
      final core = await ThorCore.init(
        capture: const ThorCapturePolicy(maxLogLength: 10),
      );
      core.log('a' * 50);
      final msg = core.store
          .ofKind(ThorEventKind.log)
          .single
          .payload['message']! as String;
      expect(msg, '${'a' * 10}…(+40)');
      await core.dispose();
    });

    test('ráfaga: tope por origen con resumen y cupo aparte para warn/error',
        () async {
      final t = _Time();
      await withClock(Clock(() => t.now), () async {
        final core = await ThorCore.init(
          capture: const ThorCapturePolicy(logBurstLimit: 3),
        );
        for (var i = 0; i < 10; i++) {
          core.log('tick $i', level: ThorLogLevel.debug, source: 'print');
        }
        // El cupo de debug está agotado; el warning entra igual.
        core
          ..log('se cayó el socket', level: ThorLogLevel.warn, source: 'print')
          // Las marcas no se recortan.
          ..mark('paso');
        t.advance(1500);
        core.log('después', source: 'print');
        final logs = core.store.ofKind(ThorEventKind.log);
        final ticks = logs.where(
          (e) => '${e.payload['message']}'.startsWith('tick'),
        );
        expect(ticks, hasLength(3));
        expect(
          logs.any((e) => e.payload['message'] == 'se cayó el socket'),
          isTrue,
        );
        final summary = logs.singleWhere((e) => e.payload['burst'] == true);
        expect(summary.payload['dropped'], 7);
        expect(summary.payload['source'], 'print');
        expect(summary.payload['level'], 'debug');
        // El resumen sale ANTES del evento que lo destapó.
        expect(logs.last.payload['message'], 'después');
        await core.dispose();
      });
    });

    test('flushBursts declara la ráfaga abierta', () async {
      final core = await ThorCore.init(
        capture: const ThorCapturePolicy(logBurstLimit: 1),
      );
      core
        ..log('a', level: ThorLogLevel.error)
        ..log('b', level: ThorLogLevel.error);
      core.recorder.flushBursts();
      final summary = core.store
          .ofKind(ThorEventKind.log)
          .singleWhere((e) => e.payload['burst'] == true);
      expect(summary.payload['level'], 'error');
      expect(summary.payload['dropped'], 1);
      await core.dispose();
    });

    test('shim log(): onChange de bloc y error: null no son error', () async {
      final core = await ThorCore.init();
      thor_log.log('onChange(CartBloc, Change { currentState: S(error: null), '
          'nextState: S(status: failure) })');
      thor_log.log('onTransition(PayBloc, loading → failure)');
      thor_log.log('ERROR RESPONSE [400] /monedero/pagar');
      thor_log.log('ERROR RESPONSE [503] /x');
      thor_log.log('fino', level: 500);
      thor_log.log('onError(CartBloc, Boom, #0 main)');
      thor_log.log('detalle', level: 1000);
      thor_log.log('con error', error: StateError('x'));
      final levels = core.store
          .ofKind(ThorEventKind.log)
          .map((e) => e.payload['level'])
          .toList();
      expect(levels, [
        'info',
        'info',
        'warn',
        'error',
        'debug',
        'error',
        'error',
        'error',
      ]);
      await core.dispose();
    });

    test('infer: error: null no cuenta, error real sí', () {
      expect(ThorLogLevel.infer('S(error: null)'), ThorLogLevel.debug);
      expect(ThorLogLevel.infer('errorMessage: ""'), ThorLogLevel.debug);
      expect(ThorLogLevel.infer('error: timeout'), ThorLogLevel.error);
      expect(
        ThorLogLevel.infer('failed: false, error: null'),
        ThorLogLevel.debug,
      );
    });

    test('shim log(): mapea niveles y sin Thor no hace nada', () async {
      // Sin init: no lanza ni graba.
      thor_log.log('antes de Thor');
      final core = await ThorCore.init();
      thor_log.log('cargó catálogo', name: 'catalog');
      thor_log.log('lento', level: 900);
      thor_log.log('onError(Bloc)', error: StateError('x'));
      final logs = core.store.ofKind(ThorEventKind.log);
      expect(logs.map((e) => e.payload['level']), ['info', 'warn', 'error']);
      expect(logs.every((e) => e.payload['source'] == 'log'), isTrue);
      expect(logs.first.payload['name'], 'catalog');
      expect(logs.last.payload['errorType'], 'StateError');
      await core.dispose();
    });
  });

  group('narrador', () {
    test('muestra info/warn/error, omite debug, conserva marcas', () {
      final text = ThorNarrator.narrate([
        _e(0, {'label': 'inicio'}),
        _e(1, {'level': 'debug', 'source': 'print', 'message': 'ruido'}),
        _e(2, {'level': 'info', 'source': 'thor', 'message': 'catálogo ok'}),
        _e(3, {
          'level': 'error',
          'source': 'log',
          'message': 'no cobró',
          'error': 'StateError',
        }),
      ]);
      expect(text, contains('marca: inicio'));
      expect(text, isNot(contains('ruido')));
      expect(text, contains('· log thor: catálogo ok'));
      expect(text, contains('✗ log log: no cobró'));
      expect(text, contains('error: StateError'));
    });
  });
}
