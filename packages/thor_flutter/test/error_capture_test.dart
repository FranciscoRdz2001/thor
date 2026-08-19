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

    test('el handler previo de FlutterError SIGUE corriendo (delegación)',
        () {
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
  });
}
