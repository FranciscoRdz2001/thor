import 'package:test/test.dart';
import 'package:thor/thor.dart';

void main() {
  group('Eventos de rendimiento (núcleo)', () {
    setUp(() async {
      ThorCore.debugReset();
      await ThorCore.init();
    });
    tearDown(ThorCore.debugReset);

    test('measure: custom con ms redondeado y data sin secretos', () {
      ThorCore.instance!.measure(
        'checkout',
        840.6,
        data: {'items': 3, 'password': 'pw'},
      );
      final p = ThorCore.instance!.store
          .ofKind(ThorEventKind.performance)
          .single
          .payload;
      expect(p['kind'], 'custom');
      expect(p['name'], 'checkout');
      expect(p['ms'], 841);
      expect(p['data'], {
        'items': 3,
        'password': RedactionPolicy.redactedMarker,
      });
    });

    test('measure ignora ms negativo o no finito', () {
      ThorCore.instance!.measure('a', -1);
      ThorCore.instance!.measure('b', double.infinity);
      final events = ThorCore.instance!.store.ofKind(ThorEventKind.performance);
      expect(events, isEmpty);
    });

    test('el narrador cuenta startup, screen_load, anr y custom', () {
      final core = ThorCore.instance!;
      core.recorder.record(ThorEventKind.navigation, {
        'action': 'push',
        'to': 'HomePage',
      });
      core.recorder.record(ThorEventKind.performance, {
        'kind': 'startup',
        'ms': 900,
        'until': 'first_frame',
      });
      core.recorder.record(ThorEventKind.performance, {
        'kind': 'screen_load',
        'screen': 'HomePage',
        'ms': 320,
      });
      core.recorder.record(ThorEventKind.performance, {
        'kind': 'anr',
        'ms': 2500,
        'screen': 'HomePage',
      });
      core.measure('checkout', 700);
      final steps = ThorNarrator.narrate(core.store.timeline());
      expect(steps, contains('Arranque: 900ms hasta first_frame'));
      expect(steps, contains('Carga de HomePage: 320ms'));
      expect(steps, contains('ANR: la app no respondió 2500ms en HomePage'));
      expect(steps, contains('checkout: 700ms'));
    });
  });
}
