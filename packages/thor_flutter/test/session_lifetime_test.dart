import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/src/environment_capture.dart';
import 'package:thor_flutter/src/session_lifetime.dart';
import 'package:thor_flutter/thor_flutter.dart';

/// Vida de la sesión en segundo plano: el reloj del replay se detiene
/// mientras la app no está al frente, y pasado el timeout la sesión se
/// cierra y empieza otra al volver.
void main() {
  late Directory dir;
  late DateTime clockNow;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('thor_lifetime');
    clockNow = DateTime(2026, 8, 20, 12);
    SessionLifetime.now = () => clockNow;
    ThorCore.debugReset();
    await ThorCore.init(installId: 'inst-1');
  });

  tearDown(() async {
    await ThorReplay.stop();
    SessionLifetime.uninstall();
    EnvironmentCapture.uninstall();
    ThorCore.debugReset();
    dir.deleteSync(recursive: true);
  });

  const app = MaterialApp(home: Scaffold(body: Text('hola')));

  Future<void> real(WidgetTester tester, int ms) =>
      tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));

  testWidgets('el replay no crece en segundo plano y deja un marcador de hueco',
      (tester) async {
    await tester.pumpWidget(app);
    await tester.runAsync(
      () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
    );
    final sid = ThorCore.instance!.session.sessionId;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await real(tester, 400);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    ThorCore.instance!.recorder.record(ThorEventKind.log, {'label': 'vuelta'});
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(ThorReplay.stop);

    final lines = [
      for (final l in File('${dir.path}/replay-$sid.jsonl').readAsLinesSync())
        jsonDecode(l),
    ];
    final gap = lines.whereType<Map<String, dynamic>>().singleWhere(
          (m) => m['t'] == 'gap',
        );
    expect(gap['k'], 'background');
    expect(gap['ms'], greaterThanOrEqualTo(380));
    // El hueco no está en el reloj del video: todo ts queda por debajo de
    // lo que duró el hueco.
    final stamps = <num>[
      for (final l in lines)
        if (l is List && l.length > 1 && l[1] is num) l[1] as num,
      for (final l in lines.whereType<Map<String, dynamic>>())
        if (l['ts'] is num) l['ts'] as num,
    ];
    expect(stamps, isNotEmpty);
    expect(
      stamps.reduce((a, b) => a > b ? a : b),
      lessThan(gap['ms'] as num),
    );
  });

  testWidgets('lifecycle resumed trae backgroundMs para excluirlo de la '
      'duración', (tester) async {
    await tester.pumpWidget(app);
    EnvironmentCapture.install();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await real(tester, 120);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final resumed = ThorCore.instance!.store
        .ofKind(ThorEventKind.environment)
        .map((e) => e.payload)
        .lastWhere((p) => p['state'] == 'resumed');
    expect(resumed['backgroundMs'], greaterThanOrEqualTo(100));
  });

  testWidgets('background corto: la sesión sigue', (tester) async {
    await tester.pumpWidget(app);
    var renewed = 0;
    SessionLifetime.install(
      const Duration(minutes: 30),
      onRenewed: () => renewed++,
    );
    final id = ThorCore.instance!.session.sessionId;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    clockNow = clockNow.add(const Duration(minutes: 29));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await real(tester, 50);

    expect(ThorCore.instance!.session.sessionId, id);
    expect(renewed, 0);
  });

  testWidgets(
      'background largo: cierra la sesión (replay incluido) y abre otra al '
      'volver, con el mismo usuario', (tester) async {
    await tester.pumpWidget(app);
    await tester.runAsync(
      () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
    );
    Thor.setUser('42', props: {'plan': 'pro'});
    var renewed = 0;
    SessionLifetime.install(
      const Duration(minutes: 30),
      onRenewed: () => renewed++,
    );
    final first = ThorCore.instance!.session.sessionId;

    // En zona real: la renovación hace I/O de disco, que en FakeAsync se
    // cuelga.
    await tester.runAsync(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      clockNow = clockNow.add(const Duration(minutes: 31));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });

    final core = ThorCore.instance!;
    expect(core.session.sessionId, isNot(first));
    expect(core.userId, '42');
    expect(renewed, 1);
    expect(Thor.sessionId, core.session.sessionId);
    // La sesión vieja terminó su replay; la nueva arrancó el suyo con el
    // usuario en el meta.
    expect(File('${dir.path}/replay-$first.jsonl').existsSync(), isTrue);
    await tester.runAsync(() => ThorReplay.instance!.flush(upload: false));
    final meta = jsonDecode(
      File('${dir.path}/replay-${core.session.sessionId}.jsonl')
          .readAsLinesSync()
          .first,
    ) as Map<String, dynamic>;
    expect(meta['sid'], core.session.sessionId);
    expect(meta['uid'], '42');
    expect(ThorReplay.instance, isNotNull);

    await tester.runAsync(ThorReplay.stop);
  });
}
