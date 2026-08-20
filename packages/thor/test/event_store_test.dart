import 'package:test/test.dart';
import 'package:thor/thor.dart';

ThorEvent _event(int seq, ThorEventKind kind, {String? screen}) => ThorEvent(
      seq: seq,
      kind: kind,
      atUtc: DateTime.utc(2026, 8, 19, 12, 0, seq),
      utcOffset: const Duration(hours: -7),
      screen: screen == null ? null : ScreenId(widgetClass: screen),
      payload: const {},
    );

void main() {
  group('EventStore — cuotas por familia', () {
    test('la familia charlatana NO expulsa a los errores', () {
      final store = EventStore(
        quotas: const BufferQuotas(
          defaultQuota: 3,
          perKind: {ThorEventKind.error: 5},
        ),
      );
      var seq = 0;
      store.add(_event(seq++, ThorEventKind.error));
      for (var i = 0; i < 50; i++) {
        // El receptor se repite porque el primer add vive fuera del loop.
        // ignore: cascade_invocations
        store.add(_event(seq++, ThorEventKind.state));
      }
      // El error de seq 0 sigue vivo; estado quedó capado a su cuota.
      expect(store.ofKind(ThorEventKind.error), hasLength(1));
      expect(store.ofKind(ThorEventKind.error).first.seq, 0);
      expect(store.ofKind(ThorEventKind.state), hasLength(3));
      expect(store.evictedCounts[ThorEventKind.state], 47);
      expect(store.evictedCounts[ThorEventKind.error], 0);
    });

    test('eviction saca el más viejo, no el más nuevo', () {
      final store = EventStore(quotas: const BufferQuotas(defaultQuota: 2))
        ..add(_event(0, ThorEventKind.log))
        ..add(_event(1, ThorEventKind.log))
        ..add(_event(2, ThorEventKind.log));
      expect(
        store.ofKind(ThorEventKind.log).map((e) => e.seq),
        [1, 2],
      );
    });
  });

  group('EventStore — timeline', () {
    test('orden total por seq aunque las familias se intercalen', () {
      final store = EventStore()
        ..add(_event(2, ThorEventKind.network))
        ..add(_event(0, ThorEventKind.navigation))
        ..add(_event(1, ThorEventKind.interaction));
      expect(store.timeline().map((e) => e.seq), [0, 1, 2]);
    });

    test('filtro por pantalla usa display', () {
      final store = EventStore()
        ..add(_event(0, ThorEventKind.network, screen: 'CheckoutPage'))
        ..add(_event(1, ThorEventKind.network, screen: 'HomePage'))
        ..add(_event(2, ThorEventKind.error, screen: 'CheckoutPage'));
      final checkout = store.timeline(screen: 'CheckoutPage');
      expect(checkout.map((e) => e.seq), [0, 2]);
    });

    test('sinceSeq y kinds componen', () {
      final store = EventStore()
        ..add(_event(0, ThorEventKind.log))
        ..add(_event(1, ThorEventKind.error))
        ..add(_event(2, ThorEventKind.error));
      final filtered = store.timeline(
        kinds: {ThorEventKind.error},
        sinceSeq: 2,
      );
      expect(filtered.map((e) => e.seq), [2]);
    });
  });

  group('ThorEvent — roundtrip y corrupción', () {
    test('toJson/fromJson conserva todo, incluido offset negativo', () {
      final original = ThorEvent(
        seq: 7,
        kind: ThorEventKind.network,
        atUtc: DateTime.utc(2026, 8, 19, 3, 14, 15),
        utcOffset: const Duration(hours: -7),
        screen: const ScreenId(
          routeName: '/checkout',
          widgetClass: 'CheckoutPage',
          routeType: 'MaterialPageRoute',
        ),
        origin: 'package:app/checkout.dart:142',
        payload: const {'status': 200},
      );
      final copy = ThorEvent.fromJson(original.toJson());
      expect(copy.seq, original.seq);
      expect(copy.kind, original.kind);
      expect(copy.atUtc, original.atUtc);
      expect(copy.utcOffset, original.utcOffset);
      expect(copy.screen, original.screen);
      expect(copy.origin, original.origin);
      expect(copy.payload, original.payload);
    });

    test('kind desconocido lanza FormatException (no evento zombi)', () {
      expect(
        () => ThorEvent.fromJson(const {
          'seq': 1,
          'kind': 'no-existe',
          'atUtc': '2026-08-19T00:00:00Z',
        }),
        throwsFormatException,
      );
    });

    test('atUtc ilegible lanza FormatException', () {
      expect(
        () => ThorEvent.fromJson(const {
          'seq': 1,
          'kind': 'log',
          'atUtc': 'ayer como a las 3',
        }),
        throwsFormatException,
      );
    });
  });

  group('ScreenId', () {
    test('display: clase > ruta > Desconocida', () {
      expect(
        const ScreenId(routeName: '/x', widgetClass: 'XPage').display,
        'XPage',
      );
      expect(const ScreenId(routeName: '/x').display, '/x');
      expect(const ScreenId().display, 'Desconocida');
    });
  });
}
