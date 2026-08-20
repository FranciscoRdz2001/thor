import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thor/thor.dart';
import 'package:thor_test/thor_test.dart';

void main() {
  group('thorAutoReport con fallo simulado', () {
    final reports = <ThorReport>[];
    var shouldFail = false;

    setUp(() async {
      shouldFail = false;
      ThorCore.debugReset();
      await ThorCore.init();
    });

    tearDown(ThorCore.debugReset);

    // El hook se registra DESPUÉS de los setUp/tearDown propios: los
    // tearDown corren LIFO, así el del hook (que necesita el core vivo)
    // corre ANTES del debugReset. Cazado por test: al revés, el core
    // moría antes de generar el reporte.
    thorAutoReport(
      isFailed: () => shouldFail,
      onReport: (report, file) => reports.add(report),
    );

    test('test que "pasa": ningún reporte', () {
      ThorCore.instance!.mark('trabajo del test');
      shouldFail = false;
      expect(reports, isEmpty);
    });

    test('test que "falla": reporte con origen automatedTest y nota', () {
      ThorCore.instance!
        ..setScreen('CobroPage')
        ..mark('antes_del_fallo');
      shouldFail = true;
      // El tearDown del hook corre después de este cuerpo; se verifica en
      // el siguiente test (orden garantizado dentro del grupo).
    });

    test('el reporte del test anterior quedó capturado', () {
      expect(reports, hasLength(1));
      final report = reports.single;
      expect(report.origin, ThorReportOrigin.automatedTest);
      expect(report.note, contains('test:'));
      expect(report.note, contains('falla'));
      expect(report.narrative, contains('antes_del_fallo'));
    });

    test('la línea de tiempo se limpia entre tests (setUp del hook)', () {
      // Si no se limpiara, aquí habría eventos del test anterior.
      expect(ThorCore.instance!.store.length, 0);
    });
  });

  group('escritura del artefacto', () {
    late Directory tmp;
    final files = <File?>[];
    var fail = false;

    setUp(() async {
      ThorCore.debugReset();
      await ThorCore.init();
    });

    tearDown(ThorCore.debugReset);

    tmp = Directory.systemTemp.createTempSync('thor_test_artifacts');
    thorAutoReport(
      directory: tmp,
      isFailed: () => fail,
      onReport: (report, file) => files.add(file),
    );

    test('falla → se escribe el .gz en el directorio dado', () {
      ThorCore.instance!.mark('x');
      fail = true;
    });

    test('el artefacto del test anterior existe en disco', () {
      fail = false;
      expect(files, hasLength(1));
      expect(files.single, isNotNull);
      expect(files.single!.existsSync(), isTrue);
      expect(files.single!.path, endsWith('.thor.json.gz'));
    });
  });
}
