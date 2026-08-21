import 'package:test/test.dart';
import 'package:thor/thor.dart';

ThorEvent _queue(int seq, String name, int depth, {DateTime? at}) => ThorEvent(
      seq: seq,
      kind: ThorEventKind.storage,
      atUtc: at ?? DateTime.utc(2026, 8, 21, 12, 0, seq),
      utcOffset: Duration.zero,
      payload: {'op': 'queue', 'queue': name, 'depth': depth},
    );

void main() {
  group('ThorStorage (registro)', () {
    setUp(() async {
      ThorCore.debugReset();
      await ThorCore.init(
        redaction: const RedactionPolicy(allowedKeys: {'ultimo_folio'}),
      );
    });

    tearDown(ThorCore.debugReset);

    List<ThorEvent> stored() =>
        ThorCore.instance!.store.ofKind(ThorEventKind.storage);

    test('una escritura registra el TIPO, no el valor', () {
      ThorStorage.wrote('prefs', 'sesion_cajero', value: 'ana@privado.com');

      final e = stored().single;
      expect(e.payload['op'], 'write');
      expect(e.payload['store'], 'prefs');
      expect(e.payload['key'], 'sesion_cajero');
      expect(e.payload['valueType'], 'String');
      expect(e.payload['value'], RedactionPolicy.redactedMarker);
      expect(e.payload.toString(), isNot(contains('ana@privado.com')));
    });

    test('una clave declarada segura sí pasa en claro', () {
      ThorStorage.wrote('prefs', 'ultimo_folio', value: 'A-1042');
      expect(stored().single.payload['value'], 'A-1042');
    });

    test('un blob se mide, no se copia', () {
      ThorStorage.wrote('prefs', 'pending_orders', sizeBytes: 48_231);
      final payload = stored().single.payload;
      expect(payload['sizeBytes'], 48231);
      expect(payload.containsKey('value'), isFalse);
    });

    test('un miss de lectura queda distinguible del hit', () {
      ThorStorage.read('prefs', 'token_impresora', hit: false);
      ThorStorage.read('prefs', 'caja_abierta', hit: true);
      final events = stored();
      expect(events.first.payload['hit'], isFalse);
      expect(events.last.payload['hit'], isTrue);
    });

    test('el borrado se registra', () {
      ThorStorage.removed('sqlite', 'orden_borrador');
      expect(stored().single.payload['op'], 'remove');
    });

    test('la profundidad de cola lleva su acción', () {
      ThorStorage.queueDepth('sync_ordenes', 3, op: 'encolar');
      final payload = stored().single.payload;
      expect(payload['op'], 'queue');
      expect(payload['depth'], 3);
      expect(payload['action'], 'encolar');
    });

    test('sin Thor activo no revienta ni graba', () {
      ThorCore.debugReset();
      expect(
        () => ThorStorage.queueDepth('sync_ordenes', 1),
        returnsNormally,
      );
      expect(ThorCore.instance, isNull);
    });

    test('el ruido de storage NO desaloja errores', () {
      final core = ThorCore.instance!;
      core.recorder.record(ThorEventKind.error, {'type': 'StateError'});
      for (var i = 0; i < 500; i++) {
        ThorStorage.wrote('prefs', 'k$i', sizeBytes: i);
      }
      expect(core.store.ofKind(ThorEventKind.error), hasLength(1));
    });
  });

  group('stuckQueues', () {
    test('una cola que drenó no se reporta', () {
      expect(
        ThorAggregates.stuckQueues([
          _queue(0, 'sync_ordenes', 2),
          _queue(1, 'sync_ordenes', 1),
          _queue(2, 'sync_ordenes', 0),
        ]),
        isEmpty,
      );
    });

    test('una cola que quedó cargada se reporta con pico y final', () {
      final stuck = ThorAggregates.stuckQueues([
        _queue(0, 'sync_ordenes', 1),
        _queue(1, 'sync_ordenes', 4),
        _queue(2, 'sync_ordenes', 3),
      ]).single;
      expect(stuck['queue'], 'sync_ordenes');
      expect(stuck['finalDepth'], 3);
      expect(stuck['maxDepth'], 4);
      expect(stuck['everDrained'], isFalse);
    });

    test('distingue la que nunca drenó de la que se volvió a llenar', () {
      final stuck = ThorAggregates.stuckQueues([
        _queue(0, 'sync_ordenes', 2),
        _queue(1, 'sync_ordenes', 0),
        _queue(2, 'sync_ordenes', 5),
      ]).single;
      expect(stuck['everDrained'], isTrue, reason: 'sí llegó a cero antes');
      expect(stuck['finalDepth'], 5);
    });

    test('mide desde el último cero, no desde el arranque', () {
      final base = DateTime.utc(2026, 8, 21, 12);
      final stuck = ThorAggregates.stuckQueues([
        _queue(0, 'q', 9, at: base),
        _queue(1, 'q', 0, at: base.add(const Duration(minutes: 10))),
        _queue(2, 'q', 1, at: base.add(const Duration(minutes: 11))),
        _queue(3, 'q', 1, at: base.add(const Duration(minutes: 12))),
      ]).single;
      expect(stuck['stuckForMs'], const Duration(minutes: 1).inMilliseconds);
    });

    test('colas distintas no se mezclan', () {
      final stuck = ThorAggregates.stuckQueues([
        _queue(0, 'sync_ordenes', 4),
        _queue(1, 'sync_cortes', 0),
      ]);
      expect(stuck, hasLength(1));
      expect(stuck.single['queue'], 'sync_ordenes');
    });

    test('una cola atorada rompe el "sin errores" del veredicto', () {
      final verdict = ThorAggregates.verdict([
        _queue(0, 'sync_ordenes', 1),
        _queue(1, 'sync_ordenes', 3),
      ]);
      expect(verdict, contains('3 sin sincronizar'));
      expect(
        verdict,
        isNot(contains('sin errores')),
        reason: 'nada falló, pero el trabajo no salió del dispositivo',
      );
    });

    test('escrituras sueltas no se confunden con colas', () {
      expect(
        ThorAggregates.stuckQueues([
          ThorEvent(
            seq: 0,
            kind: ThorEventKind.storage,
            atUtc: DateTime.utc(2026, 8, 21),
            utcOffset: Duration.zero,
            payload: const {'op': 'write', 'store': 'prefs', 'key': 'x'},
          ),
        ]),
        isEmpty,
      );
    });

    test('el reporte nombra la cola atorada', () async {
      ThorCore.debugReset();
      await ThorCore.init();
      ThorStorage.queueDepth('sync_ordenes', 1, op: 'encolar');
      ThorStorage.queueDepth('sync_ordenes', 2, op: 'encolar');
      final md = ThorReport.fromCore(ThorCore.instance!).toMarkdown();
      expect(md, contains('Colas sin vaciar'));
      expect(md, contains('sync_ordenes'));
      expect(md, contains('nunca drenó'));
      ThorCore.debugReset();
    });
  });
}
