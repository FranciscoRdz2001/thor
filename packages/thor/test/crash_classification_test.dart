import 'dart:io';

import 'package:test/test.dart';
import 'package:thor/thor.dart';

ThorSession _session(String id) => ThorSession(
      sessionId: id,
      installId: 'install-1',
      startedAtUtc: DateTime.utc(2026, 8, 19),
      utcOffset: Duration.zero,
    );

ThorEvent _event(
  int seq,
  ThorEventKind kind,
  Map<String, Object?> payload,
) =>
    ThorEvent(
      seq: seq,
      kind: kind,
      atUtc: DateTime.utc(2026, 8, 19, 12, 0, seq),
      utcOffset: Duration.zero,
      payload: payload,
    );

ThorEvent _lifecycle(int seq, String state) => _event(
      seq,
      ThorEventKind.environment,
      {'signal': 'lifecycle', 'state': state},
    );

void main() {
  late Directory tmp;
  var n = 0;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('thor_crash_class');
  });

  tearDown(() async {
    ThorCore.debugReset();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// Deja una sesión previa en disco sin cierre y la recupera.
  Future<RecoveredSession> recover(
    List<ThorEvent> events, {
    bool close = false,
  }) async {
    final journal =
        SessionJournal(directory: tmp, session: _session('s${n++}'));
    await journal.start();
    for (final e in events) {
      journal.append(e);
    }
    if (close) {
      await journal.close();
    } else {
      await journal.flush();
    }
    return (await SessionJournal.recoverPrevious(tmp))!;
  }

  group('RecoveredSession.crashed', () {
    test('cierre limpio: no es crash (aunque tenga un error fatal)',
        () async {
      final r = await recover(
        [_event(0, ThorEventKind.error, {'fatal': true})],
        close: true,
      );
      expect(r.crashed, isFalse);
    });

    test('muerta en primer plano sin cierre: crash', () async {
      final r = await recover([_event(0, ThorEventKind.log, {'label': 'x'})]);
      expect(r.crashed, isTrue);
    });

    test('muerta tras volver a resumed: crash', () async {
      final r = await recover([
        _lifecycle(0, 'paused'),
        _lifecycle(1, 'resumed'),
      ]);
      expect(r.crashed, isTrue);
    });

    test('matada en segundo plano (paused / hidden / detached): no es crash',
        () async {
      for (final state in ['paused', 'hidden', 'detached']) {
        final r = await recover([_lifecycle(0, state)]);
        expect(r.crashed, isFalse, reason: state);
        tmp.listSync().forEach((f) => f.deleteSync());
      }
    });

    test('simctl terminate / kill desde el selector (último: inactive)',
        () async {
      final r = await recover([_lifecycle(0, 'inactive')]);
      expect(r.crashed, isFalse);
    });

    test('error fatal grabado: crash aunque el último ciclo sea paused',
        () async {
      final r = await recover([
        _event(0, ThorEventKind.error, {'fatal': true, 'source': 'zone'}),
        _lifecycle(1, 'paused'),
      ]);
      expect(r.crashed, isTrue);
    });

    test('error NO fatal + paused: no es crash', () async {
      final r = await recover([
        _event(0, ThorEventKind.error, {'fatal': false, 'source': 'flutter'}),
        _lifecycle(1, 'paused'),
      ]);
      expect(r.crashed, isFalse);
    });
  });

  group('ThorCore.renewSession', () {
    test('cierra la sesión (con marca de fin) y abre otra con el mismo '
        'usuario, instalación y contexto', () async {
      final core = await ThorCore.init(
        storageDirectory: tmp,
        installId: 'inst-9',
      );
      core
        ..addContext('turno', () => {'abierto': true})
        ..setUser('42', props: {'plan': 'pro'})
        ..setScreen('HomeScreen');
      final oldId = core.session.sessionId;

      final next = await core.renewSession(reason: 'background_timeout');

      expect(identical(ThorCore.instance, next), isTrue);
      expect(next.session.sessionId, isNot(oldId));
      expect(next.session.installId, 'inst-9');
      expect(next.userId, '42');
      expect(next.userProps, {'plan': 'pro'});
      expect(next.snapshotContext(), {
        'turno': {'abierto': true},
      });
      expect(next.recorder.currentScreen?.widgetClass, 'HomeScreen');
      expect(next.recoveredPrevious, isNull);

      final start = next.store.ofKind(ThorEventKind.environment).first;
      expect(start.payload['signal'], 'session_start');
      expect(start.payload['previous'], oldId);

      // La vieja quedó cerrada limpia en disco.
      final old = File('${tmp.path}/thor-$oldId.jsonl').readAsStringSync();
      expect(old, contains('"type":"end"'));
      expect(old, contains('session_end'));
      await next.dispose();
    });
  });
}
