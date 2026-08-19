/// Núcleo del SDK de diagnóstico Thor.
///
/// Dart puro — sin dependencias de Flutter. Las apps normalmente no importan
/// este paquete directamente sino `thor_flutter`, que monta los capturadores
/// automáticos encima de este motor.
library;

export 'src/model/event.dart';
export 'src/model/session.dart';
export 'src/persistence/journal.dart';
export 'src/recorder.dart';
export 'src/redaction/redaction_policy.dart';
export 'src/store/event_store.dart';
export 'src/thor_core.dart';
