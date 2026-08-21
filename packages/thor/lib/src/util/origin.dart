/// Extracción del "origen": el primer frame de un stack trace que sea
/// código de la APP (no framework, no paquetes de infraestructura).
///
/// Es la pieza que convierte "falló una petición" en
/// `package:mi_app/checkout/checkout_page.dart:142` — del síntoma al código.
library;

import 'package:stack_trace/stack_trace.dart';

final _packageFrame = RegExp(r'package:([a-z0-9_]+)/[^\s):]+:\d+(?::\d+)?');

/// Paquetes EXTRA que la app declara como infraestructura propia.
///
/// Motivo real: muchas apps envuelven la red en su propio paquete
/// (`stelyt_sdk`, `mi_api_client`). Sin esto, el origen apunta al interior
/// de ESE paquete y no a la pantalla/bloc que disparó la petición — que es
/// lo que el dev quiere. Se configura con `Thor.run(infraPackages: {...})`.
final Set<String> extraInfraPackages = <String>{};

bool _isInfra(String package) =>
    _infraPackages.contains(package) || extraInfraPackages.contains(package);

/// Paquetes que jamás cuentan como "código de la app".
const _infraPackages = {
  // Flutter y Dart
  'flutter', 'flutter_test', 'flutter_localizations',
  'stack_trace', 'async', 'meta', 'collection', 'clock',
  // Thor mismo
  'thor', 'thor_flutter', 'thor_dio', 'thor_bloc', 'thor_test',
  // Transporte y estado comunes
  'dio', 'http', 'bloc', 'flutter_bloc', 'go_router', 'provider',
  'riverpod', 'flutter_riverpod',
  // Runners de test (los stacks de tests no deben atribuirse al runner)
  'test', 'test_api', 'test_core', 'matcher', 'stream_channel',
  'boolean_selector',
};

/// Devuelve el primer frame `package:app/...` del [stack] que no pertenezca
/// a infraestructura conocida, o `null` si no hay ninguno (no se inventa
/// origen).
String? originFromStack(StackTrace stack) {
  for (final line in stack.toString().split('\n')) {
    final match = _packageFrame.firstMatch(line);
    if (match == null) continue;
    if (_isInfra(match.group(1)!)) continue;
    return match.group(0);
  }
  return null;
}

/// Origen del punto de disparo ACTUAL, atravesando gaps asíncronos.
///
/// El problema que resuelve: `StackTrace.current` se corta en el primer
/// `await`. Una petición que sale de la app → bloc → dio pierde el frame
/// de la app y el origen queda `null` — justo donde más se necesita
/// (verificado contra el POS real: el login no traía origen).
///
/// [Chain.current] reconstruye la cadena completa **si la zona actual la
/// está capturando** (`Chain.capture`, que `Thor.run` instala). Fuera de
/// esa zona la cadena degrada a un stack normal y esto devuelve lo mismo
/// que [originFromStack] — nunca peor, nunca inventado.
///
/// [skipFrames] descarta frames propios del capturador que llama.
String? currentOrigin({int skipFrames = 1}) {
  try {
    final chain = Chain.current(skipFrames);
    // `terse` colapsa el ruido del core de dart:async entre gaps y deja
    // los frames de usuario, que es exactamente lo que se busca.
    for (final trace in chain.terse.traces) {
      for (final frame in trace.frames) {
        if (_isAppFrame(frame)) return _formatFrame(frame);
      }
    }
    return null;
  } on Object {
    // Cualquier problema resolviendo la cadena: se cae al stack simple.
    return originFromStack(StackTrace.current);
  }
}

/// ¿Este frame es código de la app?
///
/// Se decide con las propiedades del [Frame], no re-parseando su texto:
/// en una app compilada los frames propios son `package:mi_app/...`, pero
/// en tests y scripts locales son rutas relativas (`test/x_test.dart`) —
/// mirar solo `package:` dejaba fuera ese caso (bug cazado por test).
bool _isAppFrame(Frame frame) {
  if (frame.isCore) return false; // dart:async, dart:io…
  final package = frame.package;
  if (package != null && _isInfra(package)) return false;
  // Sin línea no sirve como puntero al código.
  return frame.line != null;
}

String _formatFrame(Frame frame) =>
    '${frame.library}:${frame.line}'
    '${frame.column == null ? '' : ':${frame.column}'}';
