import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

/// `Thor.run` no tenía tests, y por ahí se coló un *zone mismatch*: la app
/// inicializaba el binding antes de `run`, así que la zona del binding no
/// era la del `runApp` de adentro. Flutter lo avisa con una aserción de
/// debug fácil de ignorar, pero rompe la configuración de zona de la que
/// depende `Chain.capture` para el `archivo:línea` de origen — el síntoma
/// no es un crash, es que el dato se degrada en silencio.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(ThorCore.debugReset);

  test('el body corre en la MISMA zona que resuelve el almacenamiento',
      () async {
    Zone? resolverZone;
    Zone? bodyZone;

    await Thor.run(
      () async => bodyZone = Zone.current,
      storageDirectory: () {
        resolverZone = Zone.current;
        return null;
      },
    );

    expect(resolverZone, isNotNull);
    expect(
      bodyZone,
      same(resolverZone),
      reason: 'si divergen, Chain.capture no aplica al body y el origen '
          'se pierde a través de gaps async',
    );
    expect(bodyZone, isNot(same(Zone.root)));
  });

  test('un resolver que falla degrada a memoria, no tumba el arranque',
      () async {
    var bodyRan = false;

    await Thor.run(
      () async => bodyRan = true,
      storageDirectory: () => throw const FileSystemException('sin FS'),
    );

    expect(bodyRan, isTrue, reason: 'un journal ausente nunca bloquea la app');
    expect(ThorCore.instance, isNotNull);
    expect(ThorCore.instance!.journal, isNull);
  });

  test('sin resolver, Thor corre solo en memoria', () async {
    await Thor.run(() async {});
    expect(ThorCore.instance, isNotNull);
    expect(ThorCore.instance!.journal, isNull);
  });

  test('apagado: el body corre tal cual y Thor no se inicializa', () async {
    var resolverCalled = false;
    var bodyRan = false;

    await Thor.run(
      () async => bodyRan = true,
      enabled: false,
      storageDirectory: () {
        resolverCalled = true;
        return null;
      },
    );

    expect(bodyRan, isTrue);
    expect(resolverCalled, isFalse, reason: 'apagado = cero costo');
    expect(ThorCore.instance, isNull);
    // La fachada apagada es no-op, nunca error.
    Thor.setUser('cli_1', props: {'plan': 'pro'});
    expect(ThorCore.instance, isNull);
  });

  test('setUser con Thor encendido llega al núcleo', () async {
    await Thor.run(() async {});
    Thor.setUser('cli_9');
    expect(ThorCore.instance!.userId, 'cli_9');
  });

  test('el resolver corre antes que el body (el journal captura el arranque)',
      () async {
    final order = <String>[];

    await Thor.run(
      () async => order.add('body'),
      storageDirectory: () {
        order.add('resolver');
        return null;
      },
    );

    expect(order, ['resolver', 'body']);
  });

  test('un runZonedGuarded de la app no le esconde a Thor los errores async',
      () async {
    // Caso real: la app envuelve su arranque en su propio
    // runZonedGuarded con un onError vacío. Sin el fork de Thor, el throw
    // de un Timer moría ahí sin dejar rastro.
    final appSaw = <Object>[];
    final done = Completer<void>();
    await Thor.run(() {
      runZonedGuarded(
        () => Timer.run(() => throw StateError('timer de la app')),
        (error, _) {
          appSaw.add(error);
          done.complete();
        },
      );
    });
    await done.future;

    final errors = ThorCore.instance!.store.ofKind(ThorEventKind.error);
    expect(errors, hasLength(1), reason: 'una vez, sin duplicar');
    expect(errors.single.payload['source'], 'zone');
    expect(errors.single.payload['message'], contains('timer de la app'));
    expect(appSaw, hasLength(1), reason: 'el handler de la app sigue igual');
  });

  test('un error async sin zona de la app se graba una sola vez', () async {
    final done = Completer<void>();
    await Thor.run(() {
      Timer.run(() {
        // Tras el throw, la siguiente microtarea ve el error ya grabado.
        scheduleMicrotask(done.complete);
        throw StateError('timer suelto');
      });
    });
    await done.future;

    final errors = ThorCore.instance!.store.ofKind(ThorEventKind.error);
    expect(errors, hasLength(1));
    expect(errors.single.payload['message'], contains('timer suelto'));
  });

  group('enlace de sesión', sessionLinkTests);
}

void sessionLinkTests() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    ThorCore.debugReset();
    Thor.dashboardBaseUrl = null;
  });

  test('apagado: sin id, sin link y los listeners nunca se llaman', () async {
    var calls = 0;
    Thor.dashboardBaseUrl = 'https://thor.example.com';
    final cancel = Thor.addSessionListener((_) => calls++);
    await Thor.run(() async {}, enabled: false);
    Thor.setUser('x');
    expect(Thor.sessionId, isNull);
    expect(Thor.sessionUrl, isNull);
    expect(Thor.sessionInfo, isNull);
    expect(calls, 0);
    cancel();
  });

  test('sessionId y sessionUrl con Thor encendido', () async {
    await Thor.run(() async {});
    expect(Thor.sessionId, ThorCore.instance!.session.sessionId);
    expect(Thor.sessionUrl, isNull, reason: 'sin base no hay link');
    Thor.dashboardBaseUrl = 'https://thor.example.com/';
    expect(
      Thor.sessionUrl,
      'https://thor.example.com/sessions/${Thor.sessionId}',
    );
  });

  test('listener registrado ANTES de run se llama al arrancar', () async {
    final seen = <ThorSessionInfo>[];
    final cancel = Thor.addSessionListener(seen.add);
    expect(seen, isEmpty);
    await Thor.run(() async {});
    expect(seen, hasLength(1));
    expect(seen.single.sessionId, Thor.sessionId);
    expect(seen.single.userId, isNull);
    cancel();
  });

  test('listener registrado DESPUÉS de run recibe el estado actual', () async {
    await Thor.run(() async {});
    Thor.setUser('u1');
    final seen = <ThorSessionInfo>[];
    final cancel = Thor.addSessionListener(seen.add);
    expect(seen.single.userId, 'u1');
    cancel();
  });

  test('setUser notifica solo si cambia el usuario; cancel deja de avisar',
      () async {
    await Thor.run(() async {});
    final seen = <String?>[];
    final cancel = Thor.addSessionListener((i) => seen.add(i.userId));
    Thor.setUser('a');
    Thor.setUser('a', props: {'plan': 'pro'}); // mismo id: nada
    Thor.setUser(null);
    expect(seen, [null, 'a', null]);
    cancel();
    Thor.setUser('b');
    expect(seen, hasLength(3));
  });

  test('un listener que lanza no tumba a Thor ni a los demás', () async {
    var ok = 0;
    final c1 = Thor.addSessionListener((_) => throw StateError('roto'));
    final c2 = Thor.addSessionListener((_) => ok++);
    await Thor.run(() async {});
    expect(ok, 1);
    c1();
    c2();
  });

  test('appVersion/appBuild llegan a session.appInfo y ganan sobre appInfo',
      () async {
    await Thor.run(
      () async {},
      appInfo: {'flavor': 'qa', 'version': 'viejo'},
      appVersion: '1.4.2',
      appBuild: '87',
    );
    final session = ThorCore.instance!.session;
    expect(
      session.appInfo,
      {'flavor': 'qa', 'version': '1.4.2', 'build': '87'},
    );
    expect(session.appVersion, '1.4.2');
    expect(session.appBuild, '87');
  });

  test('sin appVersion/appBuild: appInfo intacto', () async {
    await Thor.run(() async {}, appInfo: {'flavor': 'qa'});
    final session = ThorCore.instance!.session;
    expect(session.appInfo, {'flavor': 'qa'});
    expect(session.appVersion, isNull);
  });
}
