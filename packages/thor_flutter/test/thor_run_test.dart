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
    Thor.setUser('cli_1', traits: {'plan': 'pro'});
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
}
