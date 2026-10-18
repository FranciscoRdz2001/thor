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
/// severe…). Con el default `0` se deduce del texto (los volcados de
/// `onChange(` de un bloc y `error: null` no cuentan como error), y una
/// llamada con [error] NO nulo cuenta como error.
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
      level: _levelOf(level, message, error),
      source: 'log',
      name: name,
      error: error,
      stackTrace: stackTrace,
    );
  } on Object {
    // Loguear jamás debe tumbar a quien loguea.
  }
}

/// Nivel de un `log()`: la escala numérica de `dart:developer` manda
/// (< 800 debug, 800 info, 900 warn, >= 1000 error); con el `0` por
/// defecto, un [error] NO nulo es error y lo demás se deduce del texto
/// con fallback info. Un `error: null` explícito no cuenta.
ThorLogLevel _levelOf(int level, String message, Object? error) {
  if (level != 0) return ThorLogLevel.fromNumeric(level);
  if (error != null) return ThorLogLevel.error;
  return ThorLogLevel.infer(message, fallback: ThorLogLevel.info);
}
