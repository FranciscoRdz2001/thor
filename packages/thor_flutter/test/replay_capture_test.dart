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

  testWidgets('a screen state travels as block refs; blocks once, no URLs',
      (tester) async {
    await tester.pumpWidget(app('Hola'));
    await tester.runAsync(
      () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final all = await records(tester);
    final states = all.whereType<List<Object?>>().where((r) => r[0] == 'st');
    final blocks = all.whereType<List<Object?>>().where((r) => r[0] == 'blk');
    expect(states, hasLength(1));
    expect(blocks, isNotEmpty);

    final body = jsonEncode(all);
    // Masked by default; ignored subtrees and image URLs never leave.
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

  testWidgets('user identity: uid in meta when known, user record on change',
      (tester) async {
    Thor.setUser('cli_1');
    await tester.pumpWidget(app('Hola'));
    await tester.runAsync(
      () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
    );
    await tester.pump(const Duration(milliseconds: 100));
    Thor.setUser('cli_2', traits: {'plan': 'pro'});
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
    // Solo el id viaja en el replay; los traits se quedan en el journal.
    expect(users.first.keys, unorderedEquals(['t', 'ts', 'id']));
    // Y no se duplica como evento genérico.
    expect(
      maps.where((r) => r['t'] == 'ev' && r['k'] == 'environment'),
      isEmpty,
    );
  });

  testWidgets('going back to a seen state sends only a ref', (tester) async {
    await tester.pumpWidget(app('Uno'));
    await tester.runAsync(
      () => ThorReplay.start(
        const ThorReplayConfig(maskText: false),
        directory: dir,
      ),
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
}
