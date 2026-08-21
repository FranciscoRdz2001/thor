import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thor/thor.dart';

ThorEvent _e(
  int seq,
  ThorEventKind kind,
  Map<String, Object?> payload, {
  String? screen,
  DateTime? at,
}) =>
    ThorEvent(
      seq: seq,
      kind: kind,
      atUtc: at ?? DateTime.utc(2026, 8, 21, 12, 0, seq),
      utcOffset: Duration.zero,
      screen: screen == null ? null : ScreenId(widgetClass: screen),
      payload: payload,
    );

void main() {
  group('Veredicto (TL;DR del reporte)', () {
    test('sesión sana lo dice explícitamente', () {
      final verdict = ThorAggregates.verdict([
        _e(
          0,
          ThorEventKind.navigation,
          {'action': 'push', 'to': 'A'},
          screen: 'A',
        ),
        _e(1, ThorEventKind.network, {'statusCode': 200, 'durationMs': 30}),
      ]);
      expect(verdict, contains('sin errores'));
      expect(verdict, contains('1 pantalla'));
    });

    test('cuenta errores y peticiones fallidas', () {
      final verdict = ThorAggregates.verdict([
        _e(
          0,
          ThorEventKind.navigation,
          {'action': 'push', 'to': 'A'},
          screen: 'A',
        ),
        _e(
          1,
          ThorEventKind.navigation,
          {'action': 'push', 'to': 'B'},
          screen: 'B',
        ),
        _e(2, ThorEventKind.network, {'statusCode': 500, 'durationMs': 10}),
        _e(3, ThorEventKind.network, {'statusCode': 200, 'durationMs': 10}),
        _e(4, ThorEventKind.error, {'type': 'StateError'}),
        _e(5, ThorEventKind.error, {'type': 'RangeError'}),
      ]);
      expect(verdict, contains('2 errores'));
      expect(verdict, contains('1 de 2 peticiones fallaron'));
      expect(verdict, contains('2 pantallas'));
    });

    test('timeline vacía no revienta', () {
      expect(ThorAggregates.verdict([]), 'Sesión sin eventos.');
    });

    test('duración larga se muestra en minutos', () {
      final base = DateTime.utc(2026, 8, 21, 12);
      final verdict = ThorAggregates.verdict([
        _e(0, ThorEventKind.log, {'label': 'a'}, at: base),
        _e(
          1,
          ThorEventKind.log,
          {'label': 'b'},
          at: base.add(const Duration(minutes: 1, seconds: 40)),
        ),
      ]);
      expect(verdict, contains('1m 40s'));
    });
  });

  group('Rage taps', () {
    final base = DateTime.utc(2026, 8, 21, 12);

    ThorEvent tap(int seq, String label, int atMs) => _e(
          seq,
          ThorEventKind.interaction,
          {'label': label, 'widget': 'ElevatedButton'},
          screen: 'CobroPage',
          at: base.add(Duration(milliseconds: atMs)),
        );

    test('tres toques al mismo botón en ráfaga se marcan', () {
      final rage = ThorAggregates.rageTaps([
        tap(0, 'Cobrar', 0),
        tap(1, 'Cobrar', 400),
        tap(2, 'Cobrar', 900),
      ]);
      expect(rage, hasLength(1));
      expect(rage.single['target'], 'Cobrar');
      expect(rage.single['taps'], 3);
      expect(rage.single['withinMs'], 900);
      expect(rage.single['screen'], 'CobroPage');
    });

    test('dos toques NO son frustración (bajo el mínimo)', () {
      expect(
        ThorAggregates.rageTaps([tap(0, 'Cobrar', 0), tap(1, 'Cobrar', 300)]),
        isEmpty,
      );
    });

    test('toques espaciados son uso normal', () {
      expect(
        ThorAggregates.rageTaps([
          tap(0, 'Cobrar', 0),
          tap(1, 'Cobrar', 5000),
          tap(2, 'Cobrar', 10000),
        ]),
        isEmpty,
      );
    });

    test('botones distintos no se agrupan entre sí', () {
      expect(
        ThorAggregates.rageTaps([
          tap(0, 'Cobrar', 0),
          tap(1, 'Cancelar', 200),
          tap(2, 'Cobrar', 400),
        ]),
        isEmpty,
      );
    });
  });

  group('Reporte con captura adjunta', () {
    late Directory tmp;

    setUp(() async {
      ThorCore.debugReset();
      tmp = await Directory.systemTemp.createTemp('thor_shot');
      await ThorCore.init();
    });

    tearDown(() async {
      ThorCore.debugReset();
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('el PNG se escribe aparte y el JSON solo lo referencia', () async {
      final core = ThorCore.instance!..mark('x');
      // Bytes arbitrarios: writeTo no interpreta la imagen.
      final report = ThorReport.fromCore(
        core,
        screenshotPng: const [1, 2, 3, 4],
      );
      final file = await report.writeTo(tmp);

      final png = report.screenshotFile(tmp)!;
      expect(png.existsSync(), isTrue);
      expect(await png.readAsBytes(), [1, 2, 3, 4]);

      final json = jsonDecode(
        utf8.decode(gzip.decode(await file.readAsBytes())),
      ) as Map<String, Object?>;
      // Referencia por nombre, NO la imagen embebida (inflaría el .gz).
      expect(json['screenshot'], '${report.reportId}.png');
      expect(json.toString(), isNot(contains('[1, 2, 3, 4]')));

      expect(report.toMarkdown(), contains('Captura adjunta'));
    });

    test('sin captura: ni archivo ni referencia', () async {
      final report = ThorReport.fromCore(ThorCore.instance!);
      await report.writeTo(tmp);
      expect(report.screenshotFile(tmp), isNull);
      expect(report.toJson().containsKey('screenshot'), isFalse);
      expect(report.toMarkdown(), isNot(contains('Captura adjunta')));
    });

    test('el markdown arranca con el veredicto', () async {
      final core = ThorCore.instance!;
      core.recorder.record(ThorEventKind.error, {'type': 'StateError'});
      final md = ThorReport.fromCore(core).toMarkdown();
      final lines = md.split('\n').where((l) => l.trim().isNotEmpty);
      expect(lines.elementAt(1), startsWith('**'));
      expect(lines.elementAt(1), contains('1 error'));
    });
  });
}
