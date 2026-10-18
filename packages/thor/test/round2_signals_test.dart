import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:test/test.dart';
import 'package:thor/thor.dart';

ThorSession _session(String id) => ThorSession(
      sessionId: id,
      installId: 'install-1',
      startedAtUtc: DateTime.utc(2026, 8, 19),
      utcOffset: Duration.zero,
    );

ThorEvent _event(int seq) => ThorEvent(
      seq: seq,
      kind: ThorEventKind.log,
      atUtc: DateTime.utc(2026, 8, 19, 12, 0, seq),
      utcOffset: Duration.zero,
      payload: {'label': 'e$seq'},
    );

List<ThorEvent> _env(String signal) => [
      for (final e
          in ThorCore.instance!.store.ofKind(ThorEventKind.environment))
        if (e.payload['signal'] == signal) e,
    ];

void main() {
  late Directory tmp;

  setUp(() async {
    ThorCore.debugReset();
    tmp = await Directory.systemTemp.createTemp('thor_round2');
  });

  tearDown(() async {
    ThorCore.debugReset();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('T-N01 journal: un disco roto no inunda ni lanza', () {
    test('directorio borrado a media sesión: se recrea y sigue escribiendo',
        () async {
      final dir = Directory('${tmp.path}/thor');
      final journal = SessionJournal(directory: dir, session: _session('s1'));
      await journal.start();
      journal.append(_event(0), urgent: true);
      await journal.flush();

      await dir.delete(recursive: true); // reinstalación del build
      journal.append(_event(1), urgent: true);
      await journal.flush();

      expect(journal.disabled, isFalse);
      final recovered = await SessionJournal.recoverPrevious(dir);
      expect(recovered, isNotNull, reason: 'cabecera reescrita');
      expect(recovered!.session.sessionId, 's1');
      expect(recovered.events.map((e) => e.seq), contains(1));
    });

    test('fallo persistente: se rinde, avisa UNA vez y no lanza', () async {
      final failures = <Object>[];
      // El "directorio" es un archivo: no se puede crear ni escribir.
      final blocker = File('${tmp.path}/thor')..writeAsStringSync('x');
      final errors = <Object>[];
      await runZonedGuarded(
        () async {
          final journal = SessionJournal(
            directory: Directory(blocker.path),
            session: _session('s2'),
            onFailure: failures.add,
          );
          await journal.start();
          for (var i = 0; i < 20; i++) {
            journal.append(_event(i), urgent: true);
            await journal.flush();
          }
          expect(journal.disabled, isTrue);
          await journal.close();
        },
        (e, _) => errors.add(e),
      );
      expect(errors, isEmpty, reason: 'ningún error sin manejar');
      expect(failures, hasLength(1));
    });

    test('ThorCore: el fallo es UN error source thor, con tope', () async {
      final core = await ThorCore.init(
        storageDirectory: Directory('${tmp.path}/thor'),
      );
      for (var i = 0; i < 10; i++) {
        core.recordInternalError('journal', const FileSystemException('x'));
      }
      final errors = core.store.ofKind(ThorEventKind.error);
      expect(errors, hasLength(ThorCore.maxInternalErrors));
      expect(errors.first.payload['source'], 'thor');
      expect(errors.first.payload['internal'], isTrue);
      expect(core.internalErrorsDropped, 10 - ThorCore.maxInternalErrors);
    });

    test('isInternalFileError reconoce los archivos del SDK', () {
      bool internal(String path) => ThorCore.isInternalFileError(
            PathNotFoundException(path, const OSError('no', 2)),
          );
      expect(internal('/a/Application Support/thor/replay-abc.jsonl'), isTrue);
      expect(internal('/a/thor/thor-abc.jsonl'), isTrue);
      expect(internal('/a/thor/replay-abc.on'), isTrue);
      expect(internal('/a/thor/mi_app.db'), isFalse);
      expect(ThorCore.isInternalFileError(StateError('x')), isFalse);
    });
  });

  group('T-N12 fin de sesión', () {
    test('cierre limpio declara motivo y segundos en background', () async {
      final journal = SessionJournal(directory: tmp, session: _session('s3'));
      await journal.start();
      await journal.close(reason: 'renewed', backgroundMs: 42000);
      final r = await SessionJournal.recoverPrevious(tmp);
      expect(r!.endReason, 'renewed');
      expect(r.backgroundMs, 42000);
    });

    test('muerta en background = killed; en primer plano = crash', () async {
      ThorEvent life(int seq, String state, {int? away}) => ThorEvent(
            seq: seq,
            kind: ThorEventKind.environment,
            atUtc: DateTime.utc(2026, 8, 19, 12, 0, seq),
            utcOffset: Duration.zero,
            payload: {
              'signal': 'lifecycle',
              'state': state,
              if (away != null) 'backgroundMs': away,
            },
          );
      final a = SessionJournal(directory: tmp, session: _session('a1'));
      await a.start();
      a
        ..append(life(0, 'paused'), urgent: true)
        ..append(life(1, 'resumed', away: 3000), urgent: true)
        ..append(life(2, 'paused'), urgent: true);
      await a.flush();
      var r = await SessionJournal.recoverPrevious(tmp);
      expect(r!.endReason, 'killed');
      expect(r.backgroundMs, 3000);

      final b = SessionJournal(directory: tmp, session: _session('b1'));
      await b.start();
      b.append(_event(0), urgent: true);
      await b.flush();
      r = await SessionJournal.recoverPrevious(tmp);
      expect(r!.session.sessionId, 'b1');
      expect(r.endReason, 'crash');
    });

    test('la siguiente ejecución deja previous_session en su línea de tiempo',
        () async {
      final first = await ThorCore.init(storageDirectory: tmp);
      final firstId = first.session.sessionId;
      await first.journal!.flush();
      ThorCore.debugReset(); // simula la muerte sin cierre

      final second = await ThorCore.init(storageDirectory: tmp);
      final marker = _env('previous_session').single.payload;
      expect(marker['session'], firstId);
      expect(marker['reason'], 'crash');
      expect(second.recoveredPrevious, isNotNull);
    });

    test('renovar la sesión no duplica el marcador previous_session', () async {
      final core = await ThorCore.init(storageDirectory: tmp);
      final next = await core.renewSession(reason: 'timeout');
      expect(_env('previous_session'), isEmpty);
      expect(_env('session_start').single.payload['reason'], 'timeout');
      final prev = await SessionJournal.recoverPrevious(
        tmp,
        excludeSessionId: next.session.sessionId,
      );
      expect(prev!.endReason, 'timeout');
    });
  });

  group('T-N07 permisos y superficies externas', () {
    test('permission: campos y sin repetir el mismo estado', () async {
      final core = await ThorCore.init();
      core
        ..permission(
          'camera',
          before: 'undetermined',
          after: 'denied',
          prompt: true,
        )
        ..permission('camera', after: 'denied')
        ..permission('camera', after: 'denied');
      final events = _env('permission');
      expect(events, hasLength(2), reason: 'el prompt + una lectura; no más');
      expect(events.first.payload, {
        'signal': 'permission',
        'kind': 'camera',
        'before': 'undetermined',
        'after': 'denied',
        'prompt': true,
        'source': 'app',
      });
    });

    test('permissionKindFromText: exige permiso Y recurso', () {
      expect(
        ThorCore.permissionKindFromText('CameraAccessDenied'),
        'camera',
      );
      expect(
        ThorCore.permissionKindFromText('Permission denied: microphone'),
        'microphone',
      );
      expect(
        ThorCore.permissionKindFromText('speech recognition not authorized'),
        'speech',
      );
      expect(ThorCore.permissionKindFromText('camera ready'), isNull);
      expect(ThorCore.permissionKindFromText('permission denied'), isNull);
    });

    test('externalSurface guarda solo el host, nunca ruta ni query', () async {
      final core = await ThorCore.init();
      core
        ..externalSurface(
          'https://www.shop.example.com/terminos?token=abc',
          mode: 'in_app_browser',
        )
        ..externalSurface('www.shop.example.com', open: false, ms: 38000);
      final events = _env('external_surface');
      expect(events.first.payload['host'], 'www.shop.example.com');
      expect(events.first.payload['mode'], 'in_app_browser');
      expect(events.first.payload['state'], 'open');
      expect(events.last.payload['state'], 'close');
      expect(events.last.payload['ms'], 38000);
      expect('${events.first.payload}', isNot(contains('token')));
    });

    test('externalSurface sin esquema tampoco guarda ruta ni query', () async {
      final core = await ThorCore.init();
      core.externalSurface('www.shop.example.com/pago?token=abc#frag');
      final host = _env('external_surface').single.payload['host'];
      expect(host, 'www.shop.example.com');
    });
  });

  group('T-N11 problemas visibles', () {
    test('problem: evento error con source propio, no fatal', () async {
      final core = await ThorCore.init();
      core.problem(
        'freeze',
        'UiFreeze',
        'Pantalla congelada 4400 ms',
        extra: {'ms': 4400},
      );
      final e = core.store.ofKind(ThorEventKind.error).single.payload;
      expect(e['source'], 'freeze');
      expect(e['fatal'], false);
      expect(e['ms'], 4400);
    });

    test('logout silencioso: usuario → anónimo sin toque reciente', () async {
      final core = await ThorCore.init();
      core
        ..setUser('1737154')
        ..setUser(null);
      final e = core.store.ofKind(ThorEventKind.error).single.payload;
      expect(e['source'], 'silent_logout');
    });

    test('logout tras un toque del usuario NO es silencioso', () async {
      final core = await ThorCore.init();
      core
        ..setUser('1737154')
        ..recorder.record(ThorEventKind.interaction, {
          'gesture': ThorGesture.tap,
          'label': 'Cerrar sesión',
        })
        ..setUser(null);
      expect(core.store.ofKind(ThorEventKind.error), isEmpty);
    });

    test('anónimo → anónimo no dispara nada; toque viejo sí cuenta', () async {
      final core = await ThorCore.init();
      core.setUser(null);
      expect(core.store.ofKind(ThorEventKind.error), isEmpty);

      core
        ..setUser('7')
        ..recorder.record(ThorEventKind.interaction, {
          'gesture': ThorGesture.tap,
          'label': 'Comprar',
        });
      withClock(
        Clock.fixed(DateTime.now().add(const Duration(seconds: 30))),
        () => core.setUser(null),
      );
      final e = core.store.ofKind(ThorEventKind.error).single.payload;
      expect(e['source'], 'silent_logout');
      expect(e['lastAction'], contains('Comprar'));
    });
  });

  group('T-N08 niveles de log', () {
    test('[PERF] es informativo; con result=error sube a warn', () {
      expect(
        ThorLogLevel.infer('[PERF] search result=ok 312ms'),
        ThorLogLevel.info,
      );
      expect(
        ThorLogLevel.infer('[PERF] error: null en 12ms'),
        ThorLogLevel.info,
      );
      expect(
        ThorLogLevel.infer('[PERF] sponsored result=error (error) Format'),
        ThorLogLevel.warn,
      );
    });

    test('«GET error 404» es warn; un 500 sigue siendo error', () {
      expect(
        ThorLogLevel.infer('O2OBenefitResource GET error 404'),
        ThorLogLevel.warn,
      );
      expect(
        ThorLogLevel.infer('O2OBenefitResource GET error 500'),
        ThorLogLevel.error,
      );
      expect(ThorLogLevel.infer('Error al cobrar'), ThorLogLevel.error);
    });

    test('ERROR RESPONSE solo es error con estado HTTP de error', () {
      expect(ThorLogLevel.infer('ERROR RESPONSE [200] /x'), ThorLogLevel.info);
      expect(ThorLogLevel.infer('ERROR RESPONSE [404] /x'), ThorLogLevel.warn);
      expect(
        ThorLogLevel.infer('ERROR RESPONSE [502] /x'),
        ThorLogLevel.error,
      );
    });
  });

  group('T-N09 redactor', () {
    test('cabeceras CORS no son secretos; credenciales de verdad, sí', () {
      const policy = RedactionPolicy.secretsOnly();
      final out = policy.redactFlatMap({
        'access-control-allow-credentials': 'true',
        'Access-Control-Allow-Headers': 'authorization,content-type',
        'authorization': 'Bearer abc',
        'x-api-key': 'k',
        'set-cookie': 'a=1',
      });
      expect(out['access-control-allow-credentials'], 'true');
      expect(out['Access-Control-Allow-Headers'], 'authorization,content-type');
      expect(out['authorization'], RedactionPolicy.redactedMarker);
      expect(out['x-api-key'], RedactionPolicy.redactedMarker);
      expect(out['set-cookie'], RedactionPolicy.redactedMarker);
      expect(RedactionPolicy.isSecretKey('credentials'), isTrue);
    });

    test('un host con una corrida de dígitos Luhn no se parte', () {
      // 4111111111111111 pasa Luhn: dentro de un hash/host NO es tarjeta.
      const via = '1.1 55e94644734111111111111111.cloudfront.net (CloudFront)';
      expect(RedactionPolicy.scrubSecrets(via), via);
      const digitsHost = '1.1 4111111111111111.cloudfront.net';
      expect(RedactionPolicy.scrubSecrets(digitsHost), digitsHost);
      const policy = RedactionPolicy.secretsOnly();
      expect(policy.redactFlatMap({'via': via})['via'], via);
    });

    test('una tarjeta suelta sigue tapada', () {
      const marker = RedactionPolicy.redactedMarker;
      expect(
        RedactionPolicy.scrubSecrets('cobro 4111 1111 1111 1111 ok'),
        'cobro $marker ok',
      );
      expect(
        RedactionPolicy.scrubSecrets('{"n":"4111111111111111"}'),
        '{"n":"$marker"}',
      );
    });
  });
}
