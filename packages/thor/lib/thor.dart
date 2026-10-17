/// Núcleo del SDK de diagnóstico Thor.
///
/// Dart puro — sin dependencias de Flutter. Las apps normalmente no importan
/// este paquete directamente sino `thor_flutter`, que monta los capturadores
/// automáticos encima de este motor.
library;

export 'src/model/event.dart';
export 'src/model/session.dart';
export 'src/network/network_capture.dart' show ThorNetworkCapture;
export 'src/network/raw_network_store.dart';
export 'src/persistence/journal.dart';
export 'src/recorder.dart';
export 'src/redaction/redaction_policy.dart';
export 'src/report/aggregates.dart';
export 'src/report/narrator.dart';
export 'src/report/report.dart';
export 'src/report/repro_test_builder.dart';
export 'src/report/session_diff.dart';
export 'src/storage/storage_capture.dart';
export 'src/store/capture_policy.dart';
export 'src/store/event_store.dart';
export 'src/thor_core.dart';
export 'src/util/origin.dart';
