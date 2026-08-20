/// Adaptador Flutter del SDK de diagnóstico Thor.
///
/// Integración mínima:
/// ```dart
/// void main() => Thor.run(() => runApp(const MyApp()));
/// MaterialApp(navigatorObservers: [Thor.observer]);
/// ```
library;

export 'package:thor/thor.dart';

export 'src/error_capture.dart' show ErrorCapture;
export 'src/interaction_capture.dart' show InteractionCapture;
export 'src/navigator_observer.dart';
export 'src/performance_capture.dart' show PerformanceCapture;
export 'src/thor.dart';
