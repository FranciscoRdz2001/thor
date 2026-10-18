import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

/// Contrato de forma de los registros del replay con el servidor: arreglos
/// con `q` al FINAL (`st` 7, `ref` 5, `sc` 5, `p` 6, `blk` 3 sin `q`), la
/// segunda fase de la subida, la cola tras el último flush y lo que el
/// replay trae del núcleo (sesión anterior, `from`, texto de un error).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() async {
    HttpOverrides.global = null;
    dir = Directory.systemTemp.createTempSync('thor_replay_contract');
    ThorReplay.backgroundFlushDelay = const Duration(milliseconds: 20);
    await ThorCore.init();
  });

  tearDown(() async {
    await ThorReplay.stop();
    ThorCore.debugReset();
    dir.deleteSync(recursive: true);
  });

  List<Object?> onDisk() {
    final file = dir
        .listSync()
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.jsonl'));
    return [
      for (final l in file.readAsLinesSync())
        if (l.isNotEmpty) jsonDecode(l) as Object?,
    ];
  }

  List<Map<String, Object?>> evs(String kind) => [
        for (final r in onDisk())
          if (r is Map<String, Object?> && r['t'] == 'ev' && r['k'] == kind) r,
      ];

  group('array shapes (q last)', () {
    Widget app(String label) => MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                for (var i = 0; i < 60; i++) Text('$label $i'),
              ],
            ),
          ),
        );

    testWidgets('st 7, ref 5, sc 5, p 6, blk 3 without q', (tester) async {
      await tester.pumpWidget(app('A'));
      await tester.runAsync(
        () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
      );
      await tester.pump(const Duration(milliseconds: 300));
      // Otro estado y de vuelta al primero: el segundo es un `ref`.
      await tester.pumpWidget(app('B'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpWidget(app('A'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tapAt(const Offset(100, 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(ThorReplay.stop);

      final arrays = onDisk().whereType<List<Object?>>().toList();
      List<List<Object?>> of(String t) =>
          [for (final a in arrays) if (a.first == t) a];
      expect(of('st'), isNotEmpty);
      expect(of('ref'), isNotEmpty);
      expect(of('sc'), isNotEmpty);
      expect(of('p'), isNotEmpty);
      expect(of('blk'), isNotEmpty);
      for (final r in of('st')) {
        expect(r, hasLength(7));
        expect(r[5], isA<List<Object?>>(), reason: 'refs antes de q');
        expect(r.last, isA<int>());
      }
      for (final r in of('ref')) {
        expect(r, hasLength(5));
        expect(r.last, isA<int>());
      }
      for (final r in of('sc')) {
        expect(r, hasLength(5));
        expect(r.last, isA<int>());
      }
      for (final r in of('p')) {
        expect(r, hasLength(6));
        expect(r[2], anyOf('d', 'm', 'u'));
        expect(r.last, isA<int>());
      }
      for (final r in of('blk')) {
        expect(r, hasLength(3));
      }
    });

    testWidgets('a changed view size writes a corrected meta', (tester) async {
      await tester.pumpWidget(app('A'));
      await tester.runAsync(
        () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
      );
      addTearDown(tester.view.reset);
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(402, 874);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.runAsync(ThorReplay.stop);

      final metas = [
        for (final r in onDisk())
          if (r is Map<String, Object?> && r['t'] == 'meta') r,
      ];
      expect(metas, hasLength(2));
      expect(metas.last['w'], 402);
      expect(metas.last['h'], 874);
    });
  });

  group('second phase', () {
    late HttpServer server;
    late Object? answer; // null = `{}` (sin `missing`)
    var failBlocks = false;
    final received = <String>[];

    Uri endpoint() => Uri.parse('http://127.0.0.1:${server.port}/api/ingest');

    setUp(() async {
      received.clear();
      answer = null;
      failBlocks = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
        ..listen((req) async {
          final lines = const LineSplitter().convert(
            utf8.decode(gzip.decode(await req.expand((c) => c).toList())),
          );
          if (failBlocks && lines.any((l) => l.startsWith('["blk"'))) {
            req.response.statusCode = 500;
            await req.response.close();
            return;
          }
          received.addAll(lines);
          req.response.write(jsonEncode(answer ?? <String, Object?>{}));
          await req.response.close();
        });
    });

    tearDown(() => server.close(force: true));

    const blk = '["blk","aaaaaaaaaaaaaaaa",[["r",0,0,10,10,null,null,null]]]';
    const st =
        '["st",10,"1111111111111111",{},[],[["aaaaaaaaaaaaaaaa",0,0,0]],2]';

    void writeOld() {
      File('${dir.path}/replay-old-1.jsonl').writeAsStringSync(
        ['{"t":"meta","v":2,"q":1}', st, blk, ''].join('\n'),
      );
      File('${dir.path}/replay-old-1.on').writeAsStringSync('1');
    }

    Future<void> recover() => ThorReplay.recover(
          dir,
          endpoint(),
          File('${dir.path}/replay-now.jsonl')..writeAsStringSync(''),
        );

    test('referencedHashes reads the refs of st records, ignoring q', () {
      expect(
        ThorReplay.referencedHashes([
          st,
          '["ref",5,"1111111111111111",{},3]',
          '{"t":"meta","q":1}',
          '["st",1,',
        ]),
        {'aaaaaaaaaaaaaaaa'},
      );
    });

    test('a response without "missing" still sends the blocks the states cite',
        () async {
      writeOld();
      await recover();
      expect(received, contains(blk));
      expect(File('${dir.path}/replay-old-1.jsonl').existsSync(), isFalse);
    });

    test('an explicit empty "missing" sends no blocks', () async {
      answer = {'missing': <String>[]};
      writeOld();
      await recover();
      expect(received, isNot(contains(blk)));
      expect(File('${dir.path}/replay-old-1.jsonl').existsSync(), isFalse);
    });

    test('blocks that could not travel keep the session for next launch',
        () async {
      failBlocks = true;
      writeOld();
      await recover();
      expect(received, contains(st));
      expect(File('${dir.path}/replay-old-1.jsonl').existsSync(), isTrue);
      expect(File('${dir.path}/replay-old-1.on').existsSync(), isTrue);

      // El servidor se recupera: llegan los bloques y se limpia.
      failBlocks = false;
      await recover();
      expect(received, contains(blk));
      expect(File('${dir.path}/replay-old-1.jsonl').existsSync(), isFalse);
    });

    test('an event written right after the paused flush still goes out',
        () async {
      await ThorReplay.start(
        ThorReplayConfig(
          endpoint: endpoint(),
          saveEvery: const Duration(hours: 1),
        ),
        directory: dir,
      );
      TestWidgetsFlutterBinding.instance
          .handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await ThorReplay.instance!.flush();
      // Escrito DESPUÉS del flush de `paused` (otro observador, el último
      // evento): sin el flush corto esperaría a un relanzamiento.
      ThorCore.instance!.mark('cola');
      for (var i = 0; i < 50 && !received.any((l) => l.contains('cola')); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(received.any((l) => l.contains('cola')), isTrue);
      final sent = dir
          .listSync()
          .whereType<File>()
          .singleWhere((f) => f.path.endsWith('.sent'))
          .readAsStringSync();
      final lastQ = onDisk().last! as Map<String, Object?>;
      expect(sent, 'q:${lastQ['q']}');
    });
  });

  group('what the replay brings from the core', () {
    test('the previous session end reason reaches the replay', () async {
      ThorCore.instance!.recorder.record(ThorEventKind.environment, {
        'signal': 'previous_session',
        'session': 'old-1',
        'reason': 'killed',
        'backgroundMs': 5000,
      });
      await ThorReplay.start(const ThorReplayConfig(), directory: dir);
      await ThorReplay.stop();
      final prev = evs('environment')
          .map((e) => e['p']! as Map)
          .singleWhere((p) => p['signal'] == 'previous_session');
      expect(prev['reason'], 'killed');
      expect(prev['session'], 'old-1');
      expect(prev['backgroundMs'], 5000);
    });

    test('navigation keeps from; errors keep text and lastAction', () async {
      await ThorReplay.start(const ThorReplayConfig(), directory: dir);
      ThorCore.instance!.recorder
        ..record(ThorEventKind.navigation, {
          'action': 'pop',
          'to': 'SearchScreen',
          'from': 'SearchScreen',
        })
        ..record(ThorEventKind.error, {
          'source': 'ui_error',
          'type': 'UiError',
          'message': 'AlertDialog: «No pudimos activar el micrófono»',
          'text': 'No pudimos activar el micrófono',
          'lastAction': 'tocó «Buscar» (#3)',
        })
        ..record(ThorEventKind.interaction, {
          'gesture': 'edge_swipe',
          'widget': 'screen_edge',
          'edge': 'left',
          'popped': true,
        });
      await ThorReplay.stop();
      expect((evs('navigation').single['p']! as Map)['from'], 'SearchScreen');
      final err = evs('error').single['p']! as Map;
      expect(err['text'], 'No pudimos activar el micrófono');
      expect(err['lastAction'], 'tocó «Buscar» (#3)');
      expect((evs('interaction').single['p']! as Map)['popped'], true);
    });

    test('a transient ui_message keeps its flag', () async {
      await ThorReplay.start(const ThorReplayConfig(), directory: dir);
      ThorCore.instance!.recorder.record(ThorEventKind.environment, {
        'signal': 'ui_message',
        'widget': 'SimpleDialog',
        'text': 'Espera la señal para hablar',
        'transient': true,
      });
      await ThorReplay.stop();
      final p = evs('environment')
          .map((e) => e['p']! as Map)
          .singleWhere((p) => p['signal'] == 'ui_message');
      expect(p['transient'], true);
    });
  });
}
