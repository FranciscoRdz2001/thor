import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:test/test.dart';
import 'package:thor/thor.dart';

/// Reloj manual: los topes de ráfaga dependen del tiempo y un test con
/// `Future.delayed` sería lento y frágil.
class _Time {
  DateTime now = DateTime.utc(2026, 10, 17, 12);
  void advance(int ms) => now = now.add(Duration(milliseconds: ms));
}

void main() {
  group('BurstLimiter', () {
    test('deja pasar el tope por ventana y cuenta el resto', () {
      final t = _Time();
      final l = BurstLimiter(
        limit: 2,
        window: const Duration(seconds: 1),
        summaryEvery: const Duration(seconds: 10),
      );
      final allowed = [for (var i = 0; i < 5; i++) l.allow('A|change', t.now)];
      expect(allowed, [true, true, false, false, false]);
      expect(l.hasPending, isTrue);
      // La ráfaga sigue abierta: aún no hay resumen.
      expect(l.due(t.now), isEmpty);
      // Una ventana completa sin descartes = ráfaga terminada.
      t.advance(1000);
      final due = l.due(t.now);
      expect(due.single.dropped, 3);
      expect(l.hasPending, isFalse);
      // Se entrega una sola vez.
      expect(l.due(t.now), isEmpty);
    });

    test('ráfaga sostenida resume cada summaryEvery', () {
      final t = _Time();
      final l = BurstLimiter(
        limit: 1,
        window: const Duration(seconds: 1),
        summaryEvery: const Duration(seconds: 3),
      );
      var summaries = 0;
      var dropped = 0;
      // 10 eventos por segundo durante 10 s, sin pausa.
      for (var i = 0; i < 100; i++) {
        l.allow('A|event', t.now);
        for (final s in l.due(t.now)) {
          summaries++;
          dropped += s.dropped;
        }
        t.advance(100);
      }
      for (final s in l.due(t.now, all: true)) {
        summaries++;
        dropped += s.dropped;
      }
      // 1 por ventana pasa: 10 conservados, 90 contados en pocos resúmenes.
      expect(dropped, 90);
      expect(summaries, inInclusiveRange(3, 4));
    });
  });

  group('ThorRecorder — tope de ráfagas de estado', () {
    ThorRecorder recorder(_Time t, {int limit = 3}) => ThorRecorder(
          store: EventStore(),
          policy: ThorCapturePolicy(stateBurstLimit: limit),
        );

    Map<String, Object?> change(String bloc, String to) =>
        {'bloc': bloc, 'action': 'change', 'from': 'X', 'to': to};

    test('recorta el spam de un bloc y emite un resumen con el conteo', () {
      final t = _Time();
      withClock(Clock(() => t.now), () {
        final r = recorder(t);
        for (var i = 0; i < 20; i++) {
          r.record(ThorEventKind.state, change('MedalliaImageBloc', 'Loaded'));
          t.advance(10);
        }
        // Otro bloc en la misma ventana tiene su propio cupo.
        expect(
          r.record(ThorEventKind.state, change('CartBloc', 'Ready')),
          isNotNull,
        );
        t.advance(1500);
        // Cualquier evento posterior destapa el resumen vencido.
        r.record(ThorEventKind.log, {'label': 'x'});

        final states = r.store.ofKind(ThorEventKind.state);
        final bursts =
            states.where((e) => e.payload['action'] == 'burst').toList();
        expect(bursts, hasLength(1));
        expect(bursts.single.payload['bloc'], 'MedalliaImageBloc');
        expect(bursts.single.payload['burstOf'], 'change');
        expect(bursts.single.payload['dropped'], 17);
        expect(bursts.single.payload['limit'], 3);
        // El resumen va antes del evento que lo destapó (orden de seq).
        final log = r.store.ofKind(ThorEventKind.log).single;
        expect(bursts.single.seq, lessThan(log.seq));
      });
    });

    test('una transición a fallo nunca se recorta', () {
      final t = _Time();
      withClock(Clock(() => t.now), () {
        final r = recorder(t, limit: 1)
          ..record(ThorEventKind.state, change('PayBloc', 'Loading'))
          ..record(ThorEventKind.state, change('PayBloc', 'Loading'));
        final err =
            r.record(ThorEventKind.state, change('PayBloc', 'PayError'));
        expect(err, isNotNull);
        // También con valores de estado capturados (to = {type, value}).
        final err2 = r.record(ThorEventKind.state, {
          'bloc': 'PayBloc',
          'action': 'change',
          'to': {'type': 'PayFailure', 'value': '█redactado█'},
        });
        expect(err2, isNotNull);
      });
    });

    test('flushBursts declara una ráfaga aún abierta', () {
      final t = _Time();
      withClock(Clock(() => t.now), () {
        final r = recorder(t, limit: 1);
        for (var i = 0; i < 4; i++) {
          r.record(ThorEventKind.state, change('A', 'S'));
        }
        r.flushBursts();
        final burst = r.store
            .ofKind(ThorEventKind.state)
            .singleWhere((e) => e.payload['action'] == 'burst');
        expect(burst.payload['dropped'], 3);
      });
    });

    test('el resumen trae el último estado recortado y su pantalla', () {
      final t = _Time();
      withClock(Clock(() => t.now), () {
        final r = recorder(t, limit: 1)
          ..currentScreen = const ScreenId(routeName: '/home')
          ..record(ThorEventKind.state, change('A', 'Loading'))
          ..record(ThorEventKind.state, change('A', 'Loaded'))
          ..record(ThorEventKind.state, change('A', 'Done'))
          // El resumen sale ya en otra pantalla: debe quedar en la de la
          // ráfaga.
          ..currentScreen = const ScreenId(routeName: '/detail');
        t.advance(1500);
        r.record(ThorEventKind.log, {'label': 'x'});
        final burst = r.store
            .ofKind(ThorEventKind.state)
            .singleWhere((e) => e.payload['action'] == 'burst');
        expect(burst.payload['lastTo'], 'Done');
        expect(burst.screen, const ScreenId(routeName: '/home'));
        final noisy = ThorAggregates.noisyBlocs(r.store.timeline());
        expect(noisy.single['lastTo'], 'Done');
      });
    });

    test('stateBurstLimit 0 desactiva el tope', () {
      final r = ThorRecorder(
        store: EventStore(),
        policy: const ThorCapturePolicy.unlimited(),
      );
      for (var i = 0; i < 50; i++) {
        r.record(ThorEventKind.state, change('A', 'S'));
      }
      expect(r.store.ofKind(ThorEventKind.state), hasLength(50));
    });

    test('el reporte muestra los blocs ruidosos', () async {
      final t = _Time();
      await withClock(Clock(() => t.now), () async {
        final core = await ThorCore.init();
        for (var i = 0; i < 10; i++) {
          core.recorder.record(ThorEventKind.state, change('SpamBloc', 'S'));
        }
        final report = ThorReport.fromCore(core);
        final noisy = report.aggregates['noisyBlocs']! as List;
        expect(noisy.single, containsPair('bloc', 'SpamBloc'));
        expect(noisy.single, containsPair('dropped', 7));
        expect(noisy.single, containsPair('kept', 3));
        expect(report.toMarkdown(), contains('Blocs ruidosos'));
        await core.dispose();
      });
    });

    tearDown(ThorCore.debugReset);
  });

  group('Journal — red ligera', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('thor_capture_policy');
    });
    tearDown(() async {
      ThorCore.debugReset();
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    Map<String, Object?> request(int status) => {
          'method': 'GET',
          'url': 'https://api.x/items?page=1',
          'durationMs': 120,
          'requestHeaders': {'accept': 'application/json'},
          'requestBytes': 0,
          'statusCode': status,
          'responseHeaders': {'content-type': 'application/json'},
          'responseBytes': 2048,
          'responseBody': {'message': 'detalle del backend'},
          'curl': "curl -X GET 'https://api.x/items?page=1'",
        };

    test('exitosa va ligera al journal, fallida completa; memoria completa',
        () async {
      final core = await ThorCore.init(storageDirectory: tmp);
      core.recorder
        ..record(ThorEventKind.network, request(200))
        ..record(ThorEventKind.network, request(500))
        ..record(ThorEventKind.network, {
          'method': 'GET',
          'url': 'https://api.x/down',
          'error': 'SocketException',
        });
      await core.journal!.flush();
      final events = [
        for (final line in await core.journal!.file.readAsLines())
          if ((jsonDecode(line) as Map)['type'] == 'event')
            jsonDecode(line) as Map<String, Object?>,
      ];
      final ok = events[0]['payload']! as Map;
      final failed = events[1]['payload']! as Map;
      final dead = events[2]['payload']! as Map;
      expect(ok['lite'], isTrue);
      expect(ok['statusCode'], 200);
      expect(ok['responseBytes'], 2048);
      expect(ok.containsKey('curl'), isFalse);
      expect(ok.containsKey('requestHeaders'), isFalse);
      expect(ok.containsKey('responseBody'), isFalse);
      expect(failed['responseBody'], isNotNull);
      expect(failed['curl'], isNotNull);
      expect(dead['error'], 'SocketException');
      // En memoria (inspector, reporte manual) el detalle sigue completo.
      final inMemory = core.store.ofKind(ThorEventKind.network).first;
      expect(inMemory.payload['curl'], isNotNull);
      await core.dispose();
    });

    test('fullNetworkInJournal conserva todo', () async {
      final core = await ThorCore.init(
        storageDirectory: tmp,
        capture: const ThorCapturePolicy(fullNetworkInJournal: true),
      );
      core.recorder.record(ThorEventKind.network, request(200));
      await core.journal!.flush();
      expect(await core.journal!.file.readAsString(), contains('curl -X GET'));
      await core.dispose();
    });

    test('la ligera pesa una fracción de la completa', () {
      final full = jsonEncode(request(200)).length;
      final light =
          jsonEncode(SessionJournal.lightNetworkPayload(request(200))).length;
      expect(light, lessThan(full ~/ 2));
    });
  });

  group('ThorCore.setUser', () {
    tearDown(ThorCore.debugReset);

    test('graba el cambio una vez, guarda el id tal cual y redacta traits',
        () async {
      final core = await ThorCore.init();
      core
        ..setUser('cli_8f2a', traits: {'plan': 'pro', 'status': 'activo'})
        ..setUser('cli_8f2a', traits: {'plan': 'pro', 'status': 'activo'});
      final users = core.store
          .ofKind(ThorEventKind.environment)
          .where((e) => e.payload['signal'] == 'user')
          .toList();
      expect(users, hasLength(1), reason: 'sin cambio no hay evento');
      expect(core.userId, 'cli_8f2a');
      expect(users.single.payload['id'], 'cli_8f2a');
      final traits = users.single.payload['traits']! as Map;
      // `plan` no está en la allowlist estricta; `status` sí.
      expect(traits['plan'], RedactionPolicy.redactedMarker);
      expect(traits['status'], 'activo');

      core.setUser(null);
      expect(core.userId, isNull);
      final report = ThorReport.fromCore(core);
      expect(report.aggregates['userId'], isNull);
      expect(report.narrative, contains('Usuario: cli_8f2a'));
      expect(report.narrative, contains('Sesión sin usuario'));
      await core.dispose();
    });

    test('un id con forma de email jamás se guarda en claro', () async {
      final core = await ThorCore.init()
        ..setUser('ana.perez@gmail.com');
      expect(core.userId, RedactionPolicy.redactedMarker);
      final user = core.store
          .ofKind(ThorEventKind.environment)
          .singleWhere((e) => e.payload['signal'] == 'user');
      expect(user.payload['id'], RedactionPolicy.redactedMarker);
      expect(jsonEncode(core.store.timeline()), isNot(contains('gmail')));
      await core.dispose();
    });

    test('el reporte declara el usuario vigente', () async {
      final core = await ThorCore.init()
        ..setUser('cli_1');
      final report = ThorReport.fromCore(core);
      expect(report.aggregates['userId'], 'cli_1');
      expect(report.toMarkdown(), contains('Usuario: `cli_1`'));
      await core.dispose();
    });
  });
}
