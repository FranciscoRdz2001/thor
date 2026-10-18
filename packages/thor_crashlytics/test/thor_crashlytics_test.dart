import 'package:flutter_test/flutter_test.dart';
import 'package:thor_crashlytics/thor_crashlytics.dart';
import 'package:thor_flutter/thor_flutter.dart';

class _Fake implements ThorCrashlyticsClient {
  final Map<String, Object> keys = {};
  final List<String> logs = [];
  bool failing = false;

  @override
  Future<void> setCustomKey(String key, Object value) async {
    if (failing) throw StateError('crashlytics caído');
    keys[key] = value;
  }

  @override
  Future<void> log(String message) async {
    if (failing) throw StateError('crashlytics caído');
    logs.add(message);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    ThorCore.debugReset();
    Thor.dashboardBaseUrl = null;
  });

  test('apagado: no hay ninguna llamada a Crashlytics', () async {
    final fake = _Fake();
    final unlink = ThorCrashlytics.link(
      dashboardUrl: 'https://thor.example.com',
      client: fake,
    );
    await Thor.run(() async {}, enabled: false);
    Thor.setUser('u1');
    await Future<void>.delayed(Duration.zero);
    expect(fake.keys, isEmpty);
    expect(fake.logs, isEmpty);
    unlink();
  });

  test('link antes de run: fija keys y log al arrancar', () async {
    final fake = _Fake();
    final unlink = ThorCrashlytics.link(
      dashboardUrl: 'https://thor.example.com/',
      client: fake,
    );
    await Thor.run(() async {});
    await Future<void>.delayed(Duration.zero);
    final id = Thor.sessionId!;
    expect(fake.keys[ThorCrashlytics.sessionIdKey], id);
    expect(
      fake.keys[ThorCrashlytics.sessionUrlKey],
      'https://thor.example.com/sessions/$id',
    );
    expect(fake.keys[ThorCrashlytics.userIdKey], '');
    expect(fake.logs.single, contains(id));
    unlink();
  });

  test('cambio de usuario actualiza la key y añade log', () async {
    final fake = _Fake();
    final unlink = ThorCrashlytics.link(client: fake);
    await Thor.run(() async {});
    Thor.setUser('cli_7');
    await Future<void>.delayed(Duration.zero);
    expect(fake.keys[ThorCrashlytics.userIdKey], 'cli_7');
    expect(
      fake.keys.containsKey(ThorCrashlytics.sessionUrlKey),
      isFalse,
      reason: 'sin base de dashboard no hay url',
    );
    expect(fake.logs, hasLength(2));
    expect(fake.logs.last, contains('user=cli_7'));
    unlink();
  });

  test('unlink deja de escribir', () async {
    final fake = _Fake();
    final unlink = ThorCrashlytics.link(client: fake);
    await Thor.run(() async {});
    unlink();
    Thor.setUser('x');
    await Future<void>.delayed(Duration.zero);
    expect(fake.keys[ThorCrashlytics.userIdKey], '');
  });

  test('un Crashlytics que falla no tumba a la app', () async {
    final fake = _Fake()..failing = true;
    final unlink = ThorCrashlytics.link(client: fake);
    await Thor.run(() async {});
    Thor.setUser('x');
    await Future<void>.delayed(Duration.zero);
    expect(ThorCore.instance, isNotNull);
    unlink();
  });
}
