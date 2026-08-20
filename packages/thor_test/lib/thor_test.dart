/// Hook de Thor para `integration_test` / `flutter_test`.
///
/// ```dart
/// void main() {
///   IntegrationTestWidgetsFlutterBinding.ensureInitialized();
///   thorAutoReport(); // una línea: cada test fallido deja su reporte
///
///   testWidgets('cobrar una orden', (tester) async { ... });
/// }
/// ```
library;

export 'src/auto_report.dart';
