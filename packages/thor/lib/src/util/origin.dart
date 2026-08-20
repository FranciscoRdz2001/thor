/// Extracción del "origen": el primer frame de un stack trace que sea
/// código de la APP (no framework, no paquetes de infraestructura).
///
/// Es la pieza que convierte "falló una petición" en
/// `package:mi_app/checkout/checkout_page.dart:142` — del síntoma al código.
library;

final _packageFrame = RegExp(r'package:([a-z0-9_]+)/[^\s):]+:\d+(?::\d+)?');

/// Paquetes que jamás cuentan como "código de la app".
const _infraPackages = {
  // Flutter y Dart
  'flutter', 'flutter_test', 'flutter_localizations',
  'stack_trace', 'async', 'meta', 'collection', 'clock',
  // Thor mismo
  'thor', 'thor_flutter', 'thor_dio', 'thor_bloc',
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
    if (_infraPackages.contains(match.group(1))) continue;
    return match.group(0);
  }
  return null;
}
