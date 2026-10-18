import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('thor_replay_test');
    await ThorCore.init();
  });

  tearDown(() async {
    await ThorReplay.stop();
    ThorCore.debugReset();
    dir.deleteSync(recursive: true);
  });

  /// Flushes, stops the replay (its timers must not outlive the test)
  /// and reads what reached the disk.
  Future<List<Object?>> records(WidgetTester tester) async {
    await tester.runAsync(ThorReplay.stop);
    final file = dir
        .listSync()
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.jsonl'));
    return [
      for (final line in file.readAsLinesSync()) jsonDecode(line) as Object?,
    ];
  }

  Widget app(String label) => MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Container(color: Colors.blue, height: 40, width: 200),
              Text(label),
              const RawImage(width: 20, height: 20),
              ThorReplayIgnore(child: Text('secreto $label')),
            ],
          ),
        ),
      );

  testWidgets('default: deep-link route names stay readable, secrets out',
      (tester) async {
    await tester.pumpWidget(app('Hola'));
    await tester.runAsync(
      () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
    );
    Thor.setScreen('/orders/10293847?token=abc123secret');
    await tester.pump(const Duration(milliseconds: 100));
    final body = jsonEncode(await records(tester));
    expect(body, contains('/orders/10293847'));
    expect(body, isNot(contains('abc123secret')));
  });

  testWidgets('strict: route names from deep links are scrubbed in the replay',
      (tester) async {
    await tester.pumpWidget(app('Hola'));
    await tester.runAsync(
      () => ThorReplay.start(
        const ThorReplayConfig(privacy: ThorPrivacy.strict),
        directory: dir,
      ),
    );
    Thor.setScreen('/orders/10293847');
    await tester.pump(const Duration(milliseconds: 100));
    final body = jsonEncode(await records(tester));
    expect(body, isNot(contains('10293847')));
    expect(body, contains('/orders/:n'));
  });

  testWidgets(
      'default: screen text is visible, like a video; ignored '
      'subtrees still never leave', (tester) async {
    await tester.pumpWidget(app('Hola'));
    await tester.runAsync(
      () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final all = await records(tester);
    final blocks = all.whereType<List<Object?>>().where((r) => r[0] == 'blk');
    final texts = blocks
        .expand((b) => b[2]! as List)
        .where((op) => (op as List)[0] == 't');
    expect(texts.map((op) => (op as List).last), contains('Hola'));
    expect(jsonEncode(all), isNot(contains('secreto')));
  });

  testWidgets(
      'strict: a screen state travels as block refs; blocks once, '
      'masked text, no URLs', (tester) async {
    await tester.pumpWidget(app('Hola'));
    await tester.runAsync(
      () => ThorReplay.start(
        const ThorReplayConfig(privacy: ThorPrivacy.strict),
        directory: dir,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final all = await records(tester);
    final states = all.whereType<List<Object?>>().where((r) => r[0] == 'st');
    final blocks = all.whereType<List<Object?>>().where((r) => r[0] == 'blk');
    expect(states, hasLength(1));
    expect(blocks, isNotEmpty);

    final body = jsonEncode(all);
    // Masked in strict; ignored subtrees and image URLs never leave.
    expect(body, isNot(contains('Hola')));
    // Masked text travels as word lengths: "Hola" → [4].
    final texts = blocks
        .expand((b) => b[2]! as List)
        .where((op) => (op as List)[0] == 't');
    expect(texts.map((op) => (op as List).last), contains(equals([4])));
    expect(body, isNot(contains('secreto')));
    // An image is only a box: kind + x, y, w, h — no URL, no pixels.
    final images = blocks
        .expand((b) => b[2]! as List)
        .where((op) => (op as List)[0] == 'm');
    expect(images, isNotEmpty);
    expect(images.every((op) => (op as List).length == 5), isTrue);

    // Every block a state references is written.
    final refs = (states.single[5]! as List).map((r) => (r as List)[0]);
    final written = blocks.map((b) => b[1]).toSet();
    expect(written.containsAll(refs), isTrue);
  });

  testWidgets(
      'default: a password never leaves, neither screen nor tap; '
      'a normal field does', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextField(key: ValueKey('correo')),
              TextField(
                obscureText: true,
                decoration: InputDecoration(labelText: 'Contraseña'),
              ),
            ],
          ),
        ),
      ),
    );
    InteractionCapture.install();
    addTearDown(InteractionCapture.uninstall);
    await tester.runAsync(
      () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
    );
    await tester.enterText(find.byType(TextField).first, 'ana@mail.com');
    await tester.tap(find.byType(TextField).last);
    await tester.enterText(find.byType(TextField).last, 'hunter2-secreta');
    await tester.pump(const Duration(milliseconds: 300));

    final body = jsonEncode(await records(tester));
    expect(body, isNot(contains('hunter2')));
    expect(body, contains('ana@mail.com'));
    expect(body, contains('Contraseña'), reason: 'el label es copy');
  });

  testWidgets('meta carries app version/build and the redaction mode',
      (tester) async {
    ThorCore.debugReset();
    await ThorCore.init(
      appInfo: ThorSession.mergeAppInfo(
        const {'flavor': 'qa'},
        version: '1.4.2',
        build: '87',
      ),
    );
    await tester.pumpWidget(app('Hola'));
    await tester.runAsync(
      () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
    );
    final maps = (await records(tester)).whereType<Map<String, Object?>>();
    final meta = maps.firstWhere((r) => r['t'] == 'meta');
    expect(meta['app'], {'flavor': 'qa', 'version': '1.4.2', 'build': '87'});
    expect(meta['redaction'], 'secretsOnly');
  });

  testWidgets('meta redaction is strict when the app asked for it',
      (tester) async {
    ThorCore.debugReset();
    await ThorCore.init(redaction: const RedactionPolicy.strict());
    await tester.pumpWidget(app('Hola'));
    await tester.runAsync(
      () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
    );
    final maps = (await records(tester)).whereType<Map<String, Object?>>();
    expect(maps.firstWhere((r) => r['t'] == 'meta')['redaction'], 'strict');
  });

  testWidgets('user identity: uid in meta when known, user record on change',
      (tester) async {
    Thor.setUser('cli_1');
    await tester.pumpWidget(app('Hola'));
    await tester.runAsync(
      () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
    );
    await tester.pump(const Duration(milliseconds: 100));
    Thor.setUser('cli_2', props: {'email': 'ana@mail.com', 'pin': '1234'});
    Thor.setUser(null);
    await tester.pump(const Duration(milliseconds: 100));

    final all = await records(tester);
    final maps = all.whereType<Map<String, Object?>>();
    expect(maps.firstWhere((r) => r['t'] == 'meta')['uid'], 'cli_1');
    final users = [
      for (final r in maps)
        if (r['t'] == 'user') r,
    ];
    expect(users.map((u) => u['id']), ['cli_2', null]);
    // Los props viajan (la app los mandó a propósito), sin secretos.
    expect(users.first['props'], {
      'email': 'ana@mail.com',
      'pin': RedactionPolicy.redactedMarker,
    });
    expect(users.last.keys, unorderedEquals(['t', 'ts', 'id', 'q']));
    // Y no se duplica como evento genérico.
    expect(
      maps.where((r) => r['t'] == 'ev' && r['k'] == 'environment'),
      isEmpty,
    );
  });

  testWidgets('ui health events reach the replay: error, message, perf',
      (tester) async {
    await tester.pumpWidget(app('Hola'));
    await tester.runAsync(
      () => ThorReplay.start(
        const ThorReplayConfig(uploadOnError: false),
        directory: dir,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final core = ThorCore.instance!;
    core.recorder
      ..record(ThorEventKind.error, {
        'source': 'ui_error',
        'type': 'UiError',
        'message': 'SnackBar: «No se pudo cargar»',
      })
      ..record(ThorEventKind.environment, {
        'signal': 'ui_message',
        'widget': 'SnackBar',
        'text': 'Producto agregado',
      })
      ..record(ThorEventKind.performance, {
        'kind': 'blank_screen',
        'screen': 'OrdersPage',
        'ms': 5200,
        'nodes': 1,
      })
      ..record(ThorEventKind.performance, {
        'kind': 'stuck_loading',
        'screen': 'OrdersPage',
        'ms': 9000,
      });
    await tester.pump(const Duration(milliseconds: 100));
    final evs = [
      for (final r in await records(tester))
        if (r is Map<String, Object?> && r['t'] == 'ev') r,
    ];
    Map<String, Object?> p(
      String k,
      bool Function(Map<String, Object?>) f,
    ) =>
        evs
            .where((e) => e['k'] == k)
            .map((e) => e['p']! as Map<String, Object?>)
            .firstWhere(f);
    expect(
      p('error', (m) => m['src'] == 'ui_error')['msg'],
      'SnackBar: «No se pudo cargar»',
    );
    final msg = p('environment', (m) => m['signal'] == 'ui_message');
    expect(msg['widget'], 'SnackBar');
    expect(msg['text'], 'Producto agregado');
    expect(p('performance', (m) => m['kind'] == 'blank_screen')['nodes'], 1);
    expect(p('performance', (m) => m['kind'] == 'stuck_loading')['ms'], 9000);
  });

  testWidgets('going back to a seen state sends only a ref', (tester) async {
    await tester.pumpWidget(app('Uno'));
    await tester.runAsync(
      () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(app('Dos'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(app('Uno'));
    await tester.pump(const Duration(milliseconds: 300));

    final kinds = [
      for (final r in await records(tester))
        if (r is List) r[0],
    ];
    expect(kinds.where((k) => k == 'st'), hasLength(2));
    expect(kinds.where((k) => k == 'ref'), hasLength(1));
  });

  testWidgets('the same content pushed down a few px reuses its blocks',
      (tester) async {
    Widget shifted(double top) => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  SizedBox(height: top),
                  for (var i = 0; i < 120; i++)
                    Container(
                      color: Color(0xFF000000 + i * 0x050505),
                      height: 30,
                      child: Text('Producto $i con nombre ${'x' * (i % 7)}'),
                    ),
                ],
              ),
            ),
          ),
        );

    Future<Set<Object?>> blocksFor(double top) async {
      await tester.pumpWidget(shifted(top));
      await tester.runAsync(() async {
        await ThorReplay.start(const ThorReplayConfig(), directory: dir);
        // UI quieta: el snapshot corre en un timer real, sin frame.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      // Con un frame en camino, el snapshot espera a que pinte.
      await tester.pump(const Duration(milliseconds: 300));
      final all = await records(tester);
      for (final f in dir.listSync()) {
        f.deleteSync();
      }
      return {
        for (final r in all.whereType<List<Object?>>())
          if (r[0] == 'st')
            for (final ref in r[5]! as List) (ref as List)[0],
      };
    }

    final a = await blocksFor(10);
    final b = await blocksFor(37);
    // Only the block that holds the shift itself may change.
    expect(a.length, greaterThanOrEqualTo(3));
    expect(a.difference(b), hasLength(lessThanOrEqualTo(1)));
  });

  test('hash is stable and 16 hex chars', () {
    expect(ThorReplay.fnv('abc'), ThorReplay.fnv('abc'));
    expect(ThorReplay.fnv('abc'), hasLength(16));
    expect(ThorReplay.fnv('abc'), isNot(ThorReplay.fnv('abd')));
  });

  test('single-pass fnv equals the two fnv32 passes (block hashes kept)', () {
    String twoPass(String s) =>
        ThorReplay.fnv32(s).toRadixString(16).padLeft(8, '0') +
        ThorReplay.fnv32(s, 0x9747b28c, 0x5bd1e995)
            .toRadixString(16)
            .padLeft(8, '0');
    for (final s in ['', 'abc', '["blk",1,2.5,"ñ"]', 'x' * 5000, '😀🛒']) {
      expect(ThorReplay.fnv(s), twoPass(s));
    }
    // Valor fijo: un cambio de algoritmo invalida todos los bloques ya
    // subidos y debe ser deliberado.
    expect(ThorReplay.fnv('abc'), '1a47e90b6fd80d5c');
  });
}
