import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thor/thor.dart';

ThorEvent _e(
  int seq,
  ThorEventKind kind,
  Map<String, Object?> payload, {
  String? screen,
  String? origin,
  DateTime? at,
}) =>
    ThorEvent(
      seq: seq,
      kind: kind,
      atUtc: at ?? DateTime.utc(2026, 8, 19, 12, 0, seq),
      utcOffset: const Duration(hours: -7),
      screen: screen == null ? null : ScreenId(widgetClass: screen),
      origin: origin,
      payload: payload,
    );

void main() {
  group('ThorNarrator', () {
    test('narra el flujo completo: nav → tap → red → error', () {
      final steps = ThorNarrator.narrate([
        _e(0, ThorEventKind.navigation, {'action': 'push', 'to': 'LoginPage'}),
        _e(
          1,
          ThorEventKind.interaction,
          {'widget': 'TextField', 'label': 'usuario', 'isTextInput': true},
        ),
        _e(
          2,
          ThorEventKind.interaction,
          {'widget': 'ElevatedButton', 'label': 'Entrar'},
        ),
        _e(3, ThorEventKind.network, {
          'method': 'POST',
          'url': 'https://api.x.mx/auth/login',
          'statusCode': 500,
          'durationMs': 2100,
        }),
        _e(
          4,
          ThorEventKind.error,
          {'type': 'StateError'},
          origin: 'package:app/login.dart:88',
        ),
      ]);

      expect(steps, '''
1. [+0.0s] Abrió LoginPage
2. [+1.0s] Llenó «usuario»
3. [+2.0s] Tocó «Entrar» (ElevatedButton)
   → POST /auth/login  500 ✗  (2100ms)
   ✗ StateError en package:app/login.dart:88''');
    });

    test('estado solo aparece si huele a fallo', () {
      final steps = ThorNarrator.narrate([
        _e(0, ThorEventKind.navigation, {'action': 'push', 'to': 'X'}),
        _e(
          1,
          ThorEventKind.state,
          {'bloc': 'CobroBloc', 'action': 'change', 'to': 'CobroLoading'},
        ),
        _e(
          2,
          ThorEventKind.state,
          {'bloc': 'CobroBloc', 'action': 'change', 'to': 'CobroError'},
        ),
      ]);
      expect(steps, isNot(contains('CobroLoading')));
      expect(steps, contains('CobroBloc: → CobroError'));
    });

    test('evento huérfano antes de la primera acción se promueve a paso', () {
      final steps = ThorNarrator.narrate([
        _e(
          0,
          ThorEventKind.network,
          {
            'method': 'GET',
            'url': '/boot',
            'statusCode': 200,
            'durationMs': 10,
          },
        ),
      ]);
      expect(steps, startsWith('1. [+0.0s] →'));
    });

    test('timeline vacía produce narrativa vacía, no explosión', () {
      expect(ThorNarrator.narrate([]), isEmpty);
    });
  });

  group('ThorAggregates', () {
    test('duplicados: misma URL en ráfaga se marca; espaciada no', () {
      final base = DateTime.utc(2026, 8, 19, 12);
      List<ThorEvent> burst(String url, List<int> secondOffsets) => [
            for (final (i, s) in secondOffsets.indexed)
              _e(
                i,
                ThorEventKind.network,
                {'method': 'GET', 'url': url, 'statusCode': 200},
                screen: 'HomePage',
                at: base.add(Duration(seconds: s)),
              ),
          ];

      // 3 disparos en 2 segundos: sospechoso.
      final dups = ThorAggregates.suspiciousDuplicates(
        burst('/products', [0, 1, 2]),
      );
      expect(dups.single['maxBurst'], 3);

      // 2 disparos con 60 s entre ellos: legítimo (refresh del usuario).
      expect(
        ThorAggregates.suspiciousDuplicates(burst('/products', [0, 60])),
        isEmpty,
      );
    });

    test('networkByScreen acumula count/failed/totalMs', () {
      final stats = ThorAggregates.networkByScreen([
        _e(
          0,
          ThorEventKind.network,
          {'statusCode': 200, 'durationMs': 100},
          screen: 'A',
        ),
        _e(
          1,
          ThorEventKind.network,
          {'statusCode': 500, 'durationMs': 300},
          screen: 'A',
        ),
        _e(
          2,
          ThorEventKind.network,
          {'error': 'SocketException', 'durationMs': 50},
          screen: 'B',
        ),
      ]);
      expect(stats['A'], {'count': 2, 'failed': 1, 'totalMs': 400});
      expect(stats['B'], {'count': 1, 'failed': 1, 'totalMs': 50});
    });

    test('errores idénticos se agrupan por huella con conteo', () {
      final groups = ThorAggregates.errorGroups([
        for (var i = 0; i < 5; i++)
          _e(
            i,
            ThorEventKind.error,
            {'type': 'StateError'},
            screen: 'CobroPage',
            origin: 'package:app/c.dart:1',
          ),
        _e(
          9,
          ThorEventKind.error,
          {'type': 'RangeError'},
          screen: 'OtraPage',
        ),
      ]);
      expect(groups, hasLength(2));
      expect(groups.first['count'], 5); // ordenado por frecuencia
      expect(groups.first['type'], 'StateError');
    });
  });

  group('ThorReport', () {
    late Directory tmp;

    setUp(() async {
      ThorCore.debugReset();
      tmp = await Directory.systemTemp.createTemp('thor_report');
    });

    tearDown(() async {
      ThorCore.debugReset();
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('roundtrip: writeTo produce .gz legible con schemaVersion', () async {
      final core = await ThorCore.init(
        appInfo: {'version': '1.2.3', 'flavor': 'qa'},
      );
      core
        ..setScreen('CobroPage')
        ..mark('inicio');
      core.recorder
          .record(ThorEventKind.error, {'type': 'StateError', 'message': 'x'});

      final report = ThorReport.fromCore(core, note: 'esperaba guardar');
      final file = await report.writeTo(tmp);

      expect(file.path, endsWith('.thor.json.gz'));
      final decoded = jsonDecode(
        utf8.decode(gzip.decode(await file.readAsBytes())),
      ) as Map<String, Object?>;
      expect(decoded['schemaVersion'], 1);
      expect(decoded['origin'], 'manual');
      expect(decoded['note'], 'esperaba guardar');
      expect(decoded['reportId'], isNotEmpty);
      expect((decoded['session']! as Map)['appInfo'], {
        'version': '1.2.3',
        'flavor': 'qa',
      });
      expect(decoded['timeline'], isNotEmpty);
      await core.dispose();
    });

    test('reporte de sesión recuperada queda con origen crashRecovery',
        () async {
      final journal = SessionJournal(
        directory: tmp,
        session: ThorSession(
          sessionId: 'muerta',
          installId: 'i1',
          startedAtUtc: DateTime.utc(2026),
          utcOffset: Duration.zero,
        ),
      );
      await journal.start();
      journal.append(
        _e(0, ThorEventKind.error, {'type': 'StateError'}),
        urgent: true,
      );
      // sin close(): crash

      final recovered = (await SessionJournal.recoverPrevious(tmp))!;
      final report = ThorReport.fromRecovered(recovered);
      expect(report.origin, ThorReportOrigin.crashRecovery);
      expect(report.narrative, contains('StateError'));
    });

    test('markdown declara el truncado por cuota (eviction visible)', () async {
      final core = await ThorCore.init(
        quotas: const BufferQuotas(defaultQuota: 2),
      );
      for (var i = 0; i < 10; i++) {
        core.mark('m$i');
      }
      final md = ThorReport.fromCore(core).toMarkdown();
      expect(md, contains('descartaron eventos por cuota'));
      await core.dispose();
    });
  });
}
