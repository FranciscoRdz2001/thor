/// Puente opcional Thor → Firebase Crashlytics.
///
/// ```dart
/// void main() async {
///   await Firebase.initializeApp();
///   ThorCrashlytics.link(dashboardUrl: 'https://thor.miempresa.com');
///   await Thor.run(() => runApp(const MyApp()));
/// }
/// ```
library;

export 'src/thor_crashlytics.dart';
