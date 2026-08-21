import 'dart:async';

import 'package:stack_trace/stack_trace.dart';
import 'package:test/test.dart';
import 'package:thor/thor.dart';

// Simula la cadena real de una app: el handler de la app llama al bloc,
// el bloc llama al cliente HTTP, y ahí se resuelve el origen. Cada capa
// mete un gap asíncrono — que es exactamente lo que rompe
// StackTrace.current.

String? _resuelveOrigenEnLaCapaDeTransporte() => currentOrigin();

Future<String?> _capaDeTransporte() async {
  await Future<void>.delayed(Duration.zero);
  return _resuelveOrigenEnLaCapaDeTransporte();
}

Future<String?> _capaDeBloc() async {
  await Future<void>.delayed(Duration.zero);
  return _capaDeTransporte();
}

Future<String?> handlerDeLaApp() async {
  await Future<void>.delayed(Duration.zero);
  return _capaDeBloc();
}

void main() {
  group('currentOrigin a través de gaps asíncronos', () {
    test('DENTRO de Chain.capture recupera el frame tras varios awaits',
        () async {
      final origin = await Chain.capture(handlerDeLaApp);

      expect(
        origin,
        isNotNull,
        reason: 'con la cadena capturada el origen no debe perderse',
      );
      // El archivo de este test ES el "código de la app" aquí.
      expect(origin, contains('origin_chain_test.dart'));
    });

    test('FUERA de la zona degrada limpio: nunca inventa un origen', () async {
      // Sin Chain.capture la cadena no existe; el resultado puede ser el
      // frame simple o null, pero jamás un frame de infraestructura.
      final origin = await handlerDeLaApp();
      if (origin != null) {
        expect(origin, isNot(contains('package:dio/')));
        expect(origin, isNot(contains('package:thor/')));
      }
    });

    test('originFromStack sigue saltando infraestructura', () {
      final stack = StackTrace.fromString('''
#0      _SpyHttpClient.openUrl (package:thor/src/network/network_capture.dart:82)
#1      DioMixin.fetch (package:dio/src/dio_mixin.dart:487)
#2      CobroBloc._pagar (package:mi_app/cobro/cobro_bloc.dart:142:5)
''');
      expect(
        originFromStack(stack),
        'package:mi_app/cobro/cobro_bloc.dart:142:5',
      );
    });

    test('stack sin código de app devuelve null (no se inventa)', () {
      final stack = StackTrace.fromString('''
#0      DioMixin.fetch (package:dio/src/dio_mixin.dart:487)
#1      _rootRun (dart:async/zone.dart:1391)
''');
      expect(originFromStack(stack), isNull);
    });
  });
}
