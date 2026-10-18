import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

void main() {
  group('ErrorCapture.originFromStack', () {
    test('salta frames de framework y encuentra el de la app', () {
      final stack = StackTrace.fromString('''
#0      State.setState (package:flutter/src/widgets/framework.dart:1219:9)
#1      _CheckoutState._pay (package:mi_app/checkout/checkout_page.dart:142:5)
#2      GestureRecognizer.invokeCallback (package:flutter/src/gestures/recognizer.dart:351:24)
''');
      expect(
        ErrorCapture.originFromStack(stack),
        'package:mi_app/checkout/checkout_page.dart:142:5',
      );
    });

    test('stack solo-framework devuelve null (no inventa origen)', () {
      final stack = StackTrace.fromString('''
#0      State.setState (package:flutter/src/widgets/framework.dart:1219:9)
#1      GestureRecognizer.invokeCallback (package:flutter/src/gestures/recognizer.dart:351:24)
''');
      expect(ErrorCapture.originFromStack(stack), isNull);
    });
  });

  group('ErrorCapture — encadenamiento', () {
    setUp(() async {
      ThorCore.debugReset();
      await ThorCore.init();
    });

    tearDown(ThorCore.debugReset);

    test('el handler previo de FlutterError SIGUE corriendo (delegación)', () {
      var previousRan = false;
      final original = FlutterError.onError;
      FlutterError.onError = (_) => previousRan = true;

      ErrorCapture.install();
      FlutterError.onError!(
        FlutterErrorDetails(exception: Exception('boom')),
      );

      expect(previousRan, isTrue, reason: 'Crashlytics de la app no se pierde');
      final errors = ThorCore.instance!.store.ofKind(ThorEventKind.error);
      expect(errors, isNotEmpty);
      expect(errors.last.payload['source'], 'flutter');

      FlutterError.onError = original;
    });

    test('el mensaje llega al journal sin secretos, el resto legible', () {
      // `install` es idempotente y el test anterior restauró
      // FlutterError.onError: se entra por el handler de plataforma, que
      // sigue siendo el de Thor.
      ErrorCapture.install();
      PlatformDispatcher.instance.onError!(
        Exception(
          'GET https://api.x.io/u/ana@mail.com?token=tk-9 falló, '
          'headers: {Authorization: Bearer abcdefgh123}',
        ),
        StackTrace.current,
      );
      final msg = ThorCore.instance!.store
          .ofKind(ThorEventKind.error)
          .last
          .payload['message']! as String;
      expect(msg, isNot(contains('tk-9')));
      expect(msg, isNot(contains('abcdefgh123')));
      expect(msg, contains('ana@mail.com'));
    });

    group('contexto completo', () {
      Map<String, Object?> last() =>
          ThorCore.instance!.store.ofKind(ThorEventKind.error).last.payload;

      test('stack de 100 frames se conserva hasta 60 y avisa lo cortado', () {
        final frames = [
          for (var i = 0; i < 100; i++)
            '#$i      f$i (package:mi_app/a$i.dart:$i:1)',
        ].join('\n');
        ErrorCapture.recordFlutterError(
          FlutterErrorDetails(
            exception: Exception('x'),
            stack: StackTrace.fromString(frames),
          ),
        );
        final stack = last()['stack']! as String;
        expect(stack.split('\n').length, 61);
        expect(stack, contains('#59 '));
        expect(stack, isNot(contains('#60 ')));
        expect(stack, endsWith('…(+40 frames)'));
      });

      test('stack enorme respeta los 8 KB', () {
        final frames = [
          for (var i = 0; i < 40; i++) '#$i  ${'x' * 400} (package:a/b.dart:1:1)',
        ].join('\n');
        ErrorCapture.recordFlutterError(
          FlutterErrorDetails(
            exception: Exception('x'),
            stack: StackTrace.fromString(frames),
          ),
        );
        expect((last()['stack']! as String).length, lessThan(8300));
      });

      test('mensaje de hasta 2 KB; hash de instancia fuera, original aparte',
          () {
        ErrorCapture.recordFlutterError(
          FlutterErrorDetails(
            exception: Exception(
              'Fallo en _AddToCartWidgetState#cb997 ${'y' * 3000} Issue #12345',
            ),
          ),
        );
        final p = last();
        final msg = p['message']! as String;
        expect(msg, isNot(contains('#cb997')));
        expect(msg, contains('_AddToCartWidgetState '));
        expect(msg.length, lessThan(2100));
        expect(p['messageRaw'], contains('#cb997'));
      });

      test('context e informationCollector llegan al evento', () {
        ErrorCapture.recordFlutterError(
          FlutterErrorDetails(
            exception: StateError('boom'),
            library: 'widgets library',
            context: ErrorDescription('while building ListView'),
            informationCollector: () => [
              ErrorDescription('The widget _CartState#a1b2c was building'),
            ],
          ),
        );
        final p = last();
        expect(p['context'], 'while building ListView');
        expect(p['info'], 'The widget _CartState was building');
      });

      test('overflow: widget y archivo del causante', () {
        ErrorCapture.recordFlutterError(
          FlutterErrorDetails(
            exception: FlutterError(
              'A RenderFlex overflowed by 22 pixels on the right.\n'
              'The relevant error-causing widget was:\n'
              '  Row Row:file:///app/lib/cart/cart_row.dart:84:15\n'
              'To fix it, wrap in Expanded.',
            ),
          ),
        );
        final p = last();
        expect(p['source'], 'layout_overflow');
        expect(p['widget'], 'Row');
        expect(p['file'], 'file:///app/lib/cart/cart_row.dart:84:15');
      });

      test('un colector que lanza no rompe la captura', () {
        ErrorCapture.recordFlutterError(
          FlutterErrorDetails(
            exception: StateError('boom'),
            informationCollector: () => throw StateError('colector roto'),
          ),
        );
        expect(last()['type'], 'StateError');
      });
    });
  });
}
