/// `log()` con la MISMA firma que el de `dart:developer`, que además lo
/// graba en Thor.
///
/// `developer.log` no se puede interceptar: va directo a la VM (DevTools)
/// sin pasar por la zona ni por ninguna función reasignable, a diferencia
/// de `print` y `debugPrint`. Migrar es cambiar UN import por archivo:
///
/// ```dart
/// // antes
/// import 'dart:developer';
/// // después
/// import 'package:thor_flutter/log.dart';
/// // (si el archivo usa más cosas de dart:developer:)
/// import 'dart:developer' hide log;
/// ```
///
/// El llamado sigue llegando a `developer.log` tal cual; sin Thor
/// inicializado, eso es TODO lo que hace.
library;

import 'dart:async';
import 'dart:developer' as developer;

import 'package:thor/src/model/log_level.dart';
import 'package:thor/src/thor_core.dart';

/// Igual que `dart:developer` [developer.log] y además graba la línea en
/// Thor (sin secretos, ver `ThorCore.log`).
///
/// Nivel: [level] en la escala de `package:logging` (900 warning, 1000
/// severe…). Con el default `0` se deduce del texto, y una llamada con
/// [error] cuenta como error.
void log(
  String message, {
  DateTime? time,
  int? sequenceNumber,
  int level = 0,
  String name = '',
  Zone? zone,
  Object? error,
  StackTrace? stackTrace,
}) {
  developer.log(
    message,
    time: time,
    sequenceNumber: sequenceNumber,
    level: level,
    name: name,
    zone: zone,
    error: error,
    stackTrace: stackTrace,
  );
  final core = ThorCore.instance;
  if (core == null) return;
  try {
    core.log(
      message,
      level: level == 0
          ? ThorLogLevel.infer(
              message,
              fallback: error != null ? ThorLogLevel.error : ThorLogLevel.info,
            )
          : ThorLogLevel.fromNumeric(level),
      source: 'log',
      name: name,
      error: error,
      stackTrace: stackTrace,
    );
  } on Object {
    // Loguear jamás debe tumbar a quien loguea.
  }
}
