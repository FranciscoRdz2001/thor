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
export 'src/overlay/crash_prompt.dart'
    show ThorCrashPrompt, ThorCrashReportPage;
export 'src/overlay/inspector_page.dart' show ThorInspectorPage;
export 'src/overlay/report_share.dart' show ThorReportSharer, ThorShareOutcome;
export 'src/overlay/thor_overlay.dart' show ThorOverlayManager;
export 'src/performance_capture.dart' show PerformanceCapture;
export 'src/replay/replay_capture.dart' show ThorReplay, ThorReplayConfig;
export 'src/replay/wireframe.dart' show ThorReplayIgnore;
export 'src/screenshot_capture.dart'
    show ThorScreenshot, ThorScreenshotBoundary;
export 'src/semantics_capture.dart' show SemanticsInteractionCapture;
export 'src/thor.dart';
