import 'dart:io';

import 'package:test/test.dart';
import 'package:thor/thor.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    ThorCore.debugReset();
    tmp = await Directory.systemTemp.createTemp('thor_install_id');
  });

  tearDown(() async {
    ThorCore.debugReset();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('id de instalación', () {
    test('con directorio es el mismo en cada lanzamiento', () async {
      final first = await ThorCore.init(storageDirectory: tmp);
      final id = first.session.installId;
      final sid = first.session.sessionId;
      await first.dispose();

      final second = await ThorCore.init(storageDirectory: tmp);
      expect(second.session.installId, id);
      // La sesión sí es otra.
      expect(second.session.sessionId, isNot(sid));
      expect(
        File('${tmp.path}/${ThorCore.installIdFile}').readAsStringSync(),
        id,
      );
    });

    test('la renovación de sesión conserva la instalación', () async {
      final core = await ThorCore.init(storageDirectory: tmp);
      final id = core.session.installId;
      final renewed = await core.renewSession();
      expect(renewed.session.installId, id);
    });

    test('uno explícito de la app gana y no se escribe', () async {
      final core = await ThorCore.init(
        storageDirectory: tmp,
        installId: 'app-supplied-id',
      );
      expect(core.session.installId, 'app-supplied-id');
      expect(
        File('${tmp.path}/${ThorCore.installIdFile}').existsSync(),
        isFalse,
      );
    });

    test('sin directorio: en memoria, otro por lanzamiento', () async {
      final a = await ThorCore.init();
      final id = a.session.installId;
      await a.dispose();
      final b = await ThorCore.init();
      expect(b.session.installId, isNot(id));
    });

    test('un archivo corrupto se reemplaza por uno válido', () async {
      File('${tmp.path}/${ThorCore.installIdFile}').writeAsStringSync('??');
      final core = await ThorCore.init(storageDirectory: tmp);
      expect(core.session.installId, isNot('??'));
      expect(
        File('${tmp.path}/${ThorCore.installIdFile}').readAsStringSync(),
        core.session.installId,
      );
    });
  });

  group('contexto de pantalla', () {
    test('queda en la pantalla y en la línea de tiempo, y se limpia', () async {
      final core = await ThorCore.init()
        ..setScreen('SearchScreen')
        ..setScreenContext('Departamentos > Carnes > Res Selecta');
      expect(core.recorder.currentScreen?.display, 'SearchScreen');
      expect(
        core.recorder.currentScreen?.detail,
        'Departamentos > Carnes > Res Selecta',
      );

      core.recorder.record(ThorEventKind.log, {'label': 'x'});
      final last = core.store.timeline().last;
      expect(last.screen?.detail, 'Departamentos > Carnes > Res Selecta');
      expect(ScreenId.fromJson(last.screen!.toJson()), last.screen);

      final ctx = core.store
          .ofKind(ThorEventKind.environment)
          .where((e) => e.payload['signal'] == 'screen_context')
          .single;
      expect(ctx.payload['value'], 'Departamentos > Carnes > Res Selecta');

      // Mismo valor: nada nuevo. Otra pantalla: se pierde.
      core.setScreenContext('Departamentos > Carnes > Res Selecta');
      expect(
        core.store
            .ofKind(ThorEventKind.environment)
            .where((e) => e.payload['signal'] == 'screen_context'),
        hasLength(1),
      );
      core.setScreen('CartScreen');
      expect(core.recorder.currentScreen?.detail, isNull);
    });

    test('limpia secretos del texto', () async {
      final core = await ThorCore.init()
        ..setScreen('SearchScreen')
        ..setScreenContext('Buscar ?token=abc123secretvalue');
      expect(core.recorder.currentScreen?.detail, isNot(contains('abc123')));
    });
  });
}
