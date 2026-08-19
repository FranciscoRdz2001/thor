import 'dart:io';

import 'package:test/test.dart';
import 'package:thor/thor.dart';

ThorSession _session(String id) => ThorSession(
      sessionId: id,
      installId: 'install-1',
      startedAtUtc: DateTime.utc(2026, 8, 19),
      utcOffset: const Duration(hours: -7),
      appInfo: const {'version': '1.0.0', 'flavor': 'qa'},
      deviceInfo: const {'model': 'test'},
    );

ThorEvent _event(int seq, [ThorEventKind kind = ThorEventKind.log]) =>
    ThorEvent(
      seq: seq,
      kind: kind,
      atUtc: DateTime.utc(2026, 8, 19, 12, 0, seq),
      utcOffset: Duration.zero,
      payload: {'label': 'e$seq'},
    );

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('thor_journal_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('SessionJournal — crash vs cierre limpio', () {
    test('sesión SIN close() se recupera como crash (endedCleanly=false)',
        () async {
      final journal = SessionJournal(directory: tmp, session: _session('s1'));
      await journal.start();
      journal
        ..append(_event(0))
        ..append(_event(1), urgent: true); // urgent fuerza flush
      // NO se llama close(): esto ES el crash.

      final recovered = await SessionJournal.recoverPrevious(tmp);
      expect(recovered, isNotNull);
      expect(recovered!.endedCleanly, isFalse);
      expect(recovered.events, hasLength(2));
      expect(recovered.session.sessionId, 's1');
      expect(recovered.session.appInfo['flavor'], 'qa');
    });

    test('sesión con close() se recupera como limpia', () async {
      final journal = SessionJournal(directory: tmp, session: _session('s2'));
      await journal.start();
      journal.append(_event(0));
      await journal.close();

      final recovered = await SessionJournal.recoverPrevious(tmp);
      expect(recovered!.endedCleanly, isTrue);
      expect(recovered.events, hasLength(1));
    });

    test('línea corrupta (crash a media escritura) no pierde la sesión',
        () async {
      final journal = SessionJournal(directory: tmp, session: _session('s3'));
      await journal.start();
      journal.append(_event(0), urgent: true);
      await journal.flush();
      // Simula el flush interrumpido: media línea JSON al final.
      await journal.file.writeAsString(
        '{"type":"event","seq":99,"ki',
        mode: FileMode.append,
      );

      final recovered = await SessionJournal.recoverPrevious(tmp);
      expect(recovered!.events, hasLength(1));
      expect(recovered.corruptLines, 1);
      expect(recovered.endedCleanly, isFalse);
    });

    test('append tras close es no-op, no excepción', () async {
      final journal = SessionJournal(directory: tmp, session: _session('s4'));
      await journal.start();
      await journal.close();
      expect(() => journal.append(_event(0)), returnsNormally);
    });

    test('excludeSessionId salta el journal propio y encuentra el previo',
        () async {
      final previa =
          SessionJournal(directory: tmp, session: _session('a-vieja'));
      await previa.start();
      previa.append(_event(0), urgent: true);
      // crash de la previa (sin close)

      final actual =
          SessionJournal(directory: tmp, session: _session('z-actual'));
      await actual.start();

      final recovered = await SessionJournal.recoverPrevious(
        tmp,
        excludeSessionId: 'z-actual',
      );
      expect(recovered!.session.sessionId, 'a-vieja');
    });

    test('directorio vacío devuelve null, no explota', () async {
      expect(await SessionJournal.recoverPrevious(tmp), isNull);
    });
  });

  group('SessionJournal — purga', () {
    test('conserva a lo más maxSessions journals', () async {
      for (var i = 0; i < 5; i++) {
        final j = SessionJournal(
          directory: tmp,
          session: _session('s$i'),
          maxSessions: 3,
        );
        await j.start();
        await j.close();
      }
      final remaining = tmp
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jsonl'))
          .toList();
      expect(remaining, hasLength(3));
    });
  });

  group('ThorCore — integración', () {
    tearDown(ThorCore.debugReset);

    test('init detecta crash previo y expone recoveredPrevious', () async {
      // 1ª vida: graba y "muere".
      final first = await ThorCore.init(storageDirectory: tmp);
      first.mark('antes_del_crash');
      await first.journal!.flush();
      ThorCore.debugReset(); // simula muerte del proceso (sin dispose)

      // 2ª vida: arranca y encuentra el cadáver.
      final second = await ThorCore.init(storageDirectory: tmp);
      expect(second.recoveredPrevious, isNotNull);
      expect(second.recoveredPrevious!.endedCleanly, isFalse);
      expect(
        second.recoveredPrevious!.events
            .map((e) => e.payload['label'])
            .toList(),
        contains('antes_del_crash'),
      );
      await second.dispose();
    });

    test('un error se persiste de inmediato (urgent), sin esperar lote',
        () async {
      final core = await ThorCore.init(storageDirectory: tmp);
      core.recorder.record(ThorEventKind.error, {'message': 'boom'});
      // Sin flush manual: el listener urgent ya debió escribir.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final content = await core.journal!.file.readAsString();
      expect(content, contains('boom'));
      await core.dispose();
    });

    test('proveedor de contexto que lanza no tumba el snapshot', () async {
      final core = await ThorCore.init();
      core
        ..addContext('sano', () => {'status': 'ok'})
        ..addContext('roto', () => throw StateError('x'));
      final snapshot = core.snapshotContext();
      expect((snapshot['sano']! as Map)['status'], 'ok');
      expect((snapshot['roto']! as Map)['error'], contains('lanzó'));
      await core.dispose();
    });

    test('setScreen estampa los eventos siguientes', () async {
      final core = await ThorCore.init();
      core
        ..setScreen('Wizard/Paso2')
        ..mark('algo');
      final marks = core.store.ofKind(ThorEventKind.log);
      expect(marks.single.screen?.display, 'Wizard/Paso2');
      await core.dispose();
    });
  });
}
