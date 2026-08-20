import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// El estado del test en curso solo vive en el Invoker; es un
// implementation import asumido (mismo camino que toman patrol y las
// herramientas de screenshot-on-fail). El rango de test_api va fijado
// en el pubspec por esto mismo.
// ignore: implementation_imports
import 'package:test_api/src/backend/invoker.dart';
// Mismo motivo que el import de Invoker de arriba.
// ignore: implementation_imports
import 'package:test_api/src/backend/state.dart' show Result;
import 'package:thor/thor.dart';

/// Firma del callback que recibe cada reporte generado.
typedef ThorTestReportCallback = void Function(ThorReport report, File? file);

/// Registra el hook: al terminar CADA test, si falló y Thor está activo,
/// se genera un [ThorReport] con origen [ThorReportOrigin.automatedTest]
/// y la nota `test: <nombre>`.
///
/// - El markdown se imprime al log del runner (visible en CI).
/// - Si hay [directory] (o journal activo), el artefacto `.thor.json.gz`
///   se escribe ahí — listo para recogerse como artifact de CI.
/// - [onReport] permite enchufar destino propio (la futura plataforma).
/// - La línea de tiempo se LIMPIA entre tests para que cada reporte
///   cuente solo lo que su prueba hizo.
///
/// Llamar UNA vez en el `main()` del archivo de pruebas, después de
/// inicializar el binding.
void thorAutoReport({
  Directory? directory,
  ThorTestReportCallback? onReport,
  // Inyectable solo para las pruebas del propio hook.
  bool Function()? isFailed,
}) {
  final failed = isFailed ?? _currentTestFailed;

  setUp(() {
    // Cada test arranca con línea de tiempo propia.
    ThorCore.instance?.store.clear();
  });

  tearDown(() async {
    final core = ThorCore.instance;
    if (core == null || !failed()) return;

    final report = ThorReport.fromCore(
      core,
      origin: ThorReportOrigin.automatedTest,
      note: 'test: ${_currentTestName() ?? '(desconocido)'}',
    );

    File? file;
    final dir = directory ?? core.journal?.directory;
    if (dir != null) {
      try {
        file = await report.writeTo(Directory('${dir.path}/reportes'));
      } on Object {
        // Sin FS (o FakeAsync): el markdown de abajo sigue saliendo.
      }
    }

    // Al log del runner — en CI esto queda pegado al fallo del test.
    // ignore: avoid_print
    print('\n══ Thor: reporte del test fallido ══\n'
        '${report.toMarkdown()}\n'
        '${file == null ? '' : 'Artefacto: ${file.path}\n'}'
        '══════════════════════════════════════');

    onReport?.call(report, file);
  });
}

bool _currentTestFailed() {
  final liveTest = Invoker.current?.liveTest;
  if (liveTest == null) return false;
  return liveTest.state.result != Result.success;
}

String? _currentTestName() => Invoker.current?.liveTest.test.name;
