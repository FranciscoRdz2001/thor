import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/replay/replay_capture.dart';
import 'package:thor_flutter/src/replay/wireframe.dart';

/// Benchmark del recorrido del replay sobre un árbol pesado. No afirma
/// milisegundos (flutter test corre en JIT de debug, con asserts: los
/// números son pesimistas y varían por máquina); los imprime. Sí afirma
/// que el resultado es sano y que las optimizaciones no cambian el
/// formato ni los hashes.
void main() {
  Widget card(int tab, int i) => Card(
        margin: const EdgeInsets.all(4),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Color(0xFF103050 + i * 0x010203),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.shopping_cart, size: 20),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Producto $tab-$i',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text('Descripción larga del producto número $i'),
                    Row(
                      children: [
                        const Icon(Icons.star, size: 14),
                        Text('${i % 5}.${i % 10}'),
                        const Spacer(),
                        Text('\$${i * 3}.00'),
                      ],
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      );

  Widget chips(int tab) => SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (var c = 0; c < 12; c++)
              Container(
                margin: const EdgeInsets.all(4),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                color: Colors.grey.shade300,
                alignment: Alignment.center,
                child: Text('Filtro $c'),
              ),
          ],
        ),
      );

  Widget tab(int t) => SingleChildScrollView(
        child: Column(
          children: [
            chips(t),
            for (var i = 0; i < 30; i++) card(t, i),
          ],
        ),
      );

  Widget heavyApp(int index) => MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Catálogo')),
          body: IndexedStack(
            index: index,
            children: [for (var t = 0; t < 5; t++) tab(t)],
          ),
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: index,
            type: BottomNavigationBarType.fixed,
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Inicio'),
              BottomNavigationBarItem(
                icon: Icon(Icons.search),
                label: 'Buscar',
              ),
              BottomNavigationBarItem(icon: Icon(Icons.list), label: 'Lista'),
              BottomNavigationBarItem(icon: Icon(Icons.favorite), label: 'Fav'),
              BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Yo'),
            ],
          ),
        ),
      );

  int countElements() {
    var n = 0;
    void visit(Element e) {
      n++;
      e.visitChildElements(visit);
    }

    WidgetsBinding.instance.rootElement!.visitChildElements(visit);
    return n;
  }

  double pct(List<int> us, double p) {
    final s = [...us]..sort();
    return s[((s.length - 1) * p).round()] / 1000;
  }

  testWidgets('heavy tree: sane ops, timing printed, output unchanged',
      (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(heavyApp(2));
    await tester.pumpAndSettle();

    final elements = countElements();
    expect(elements, greaterThan(1500));

    Wireframe build() => WireframeBuilder(maskText: true).build()!;

    // Calentamiento: la primera vuelta compila en JIT.
    for (var i = 0; i < 3; i++) {
      ThorReplay.split(build().ops);
    }

    // Antes/después en el MISMO proceso e intercalados: la máquina puede
    // estar cargada y eso mueve los números absolutos, no la proporción.
    final walkUs = <int>[];
    final splitUs = <int>[];
    final refWalkUs = <int>[];
    final refSplitUs = <int>[];
    late Wireframe wire;
    late ({
      List<List<Object?>> vps,
      List<List<Object?>> refs,
      Map<String, String> blocks,
    }) parts;
    for (var i = 0; i < 60; i++) {
      final sw = Stopwatch()..start();
      wire = build();
      walkUs.add(sw.elapsedMicroseconds);
      sw.reset();
      parts = ThorReplay.split(wire.ops);
      ThorReplay.fnv(jsonEncode([parts.vps, parts.refs]));
      splitUs.add(sw.elapsedMicroseconds);

      WireframeBuilder.debugExactTransforms = true;
      sw.reset();
      final exact = build();
      refWalkUs.add(sw.elapsedMicroseconds);
      WireframeBuilder.debugExactTransforms = false;
      sw.reset();
      final ref = _referenceSplit(exact.ops);
      ThorReplay.fnv(jsonEncode([ref.vps, ref.refs]));
      refSplitUs.add(sw.elapsedMicroseconds);
    }

    // Sano: solo la tab activa (IndexedStack), textos enmascarados,
    // íconos como codepoint, viewports del scroll y de los chips.
    final kinds = <Object?, int>{};
    for (final op in wire.ops) {
      kinds[op[0]] = (kinds[op[0]] ?? 0) + 1;
    }
    expect(kinds['t'], greaterThan(20));
    expect(kinds['i'], greaterThan(10));
    expect(kinds['r'], greaterThan(20));
    expect(kinds['v'], greaterThanOrEqualTo(2));
    final body = jsonEncode(wire.ops);
    expect(body, isNot(contains('Producto')));
    expect(body, isNot(contains('Filtro')));
    // Las tabs ocultas no se recorren: ningún texto de otra tab. Con el
    // texto enmascarado se comprueba sin máscara.
    final plain = jsonEncode(WireframeBuilder(maskText: false).build()!.ops);
    expect(plain, contains('Producto 2-0'));
    expect(plain, isNot(contains('Producto 0-0')));
    expect(plain, isNot(contains('Producto 4-0')));

    // Las optimizaciones no cambian nada: misma salida que la versión de
    // referencia (transform por nodo con getTransformTo, jsonEncode por op).
    WireframeBuilder.debugExactTransforms = true;
    final exact = WireframeBuilder(maskText: true).build()!;
    WireframeBuilder.debugExactTransforms = false;
    expect(jsonEncode(wire.ops), jsonEncode(exact.ops));
    final ref = _referenceSplit(wire.ops);
    expect(jsonEncode(parts.refs), jsonEncode(ref.refs));
    expect(jsonEncode(parts.vps), jsonEncode(ref.vps));
    expect(parts.blocks, ref.blocks);

    final fingerprint = ThorReplay.fnv(
      jsonEncode([parts.vps, parts.refs, parts.blocks.values.toList()]),
    );
    // El benchmark existe para imprimir sus números.
    // ignore: avoid_print
    print(
      'replay cost (debug JIT, pesimista): elements=$elements '
      'ops=${wire.ops.length} blocks=${parts.blocks.length}\n'
      '  walk        p50=${pct(walkUs, .5)}ms p95=${pct(walkUs, .95)}ms '
      '(antes p50=${pct(refWalkUs, .5)}ms p95=${pct(refWalkUs, .95)}ms)\n'
      '  split+hash  p50=${pct(splitUs, .5)}ms p95=${pct(splitUs, .95)}ms '
      '(antes p50=${pct(refSplitUs, .5)}ms p95=${pct(refSplitUs, .95)}ms)\n'
      '  fingerprint=$fingerprint',
    );
  });

  group('stats y back-off', () {
    late Directory dir;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('thor_replay_cost');
      await ThorCore.init();
    });

    tearDown(() async {
      await ThorReplay.stop();
      ThorCore.debugReset();
      dir.deleteSync(recursive: true);
    });

    List<Map<String, Object?>> statsRecords() => [
          for (final line in dir
              .listSync()
              .whereType<File>()
              .singleWhere((f) => f.path.endsWith('.jsonl'))
              .readAsLinesSync())
            if (jsonDecode(line)
                case {'t': 'stats'} && final Map<String, Object?> r)
              r,
        ];

    testWidgets('each snapshot is timed; stats travel on flush',
        (tester) async {
      await tester.pumpWidget(heavyApp(0));
      await tester.runAsync(
        () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
      );
      await tester.pump(const Duration(milliseconds: 300));
      // Cambiar de tab varias veces: el primer snapshot paga la compilación
      // JIT; los siguientes son el costo de régimen.
      for (var i = 1; i <= 10; i++) {
        await tester.pumpWidget(heavyApp(i % 5));
        await tester.pump(const Duration(milliseconds: 300));
      }

      final live = ThorReplay.instance!.stats.toJson();
      final snap = live['snap']! as Map;
      expect(snap['n'], greaterThanOrEqualTo(2));
      expect(snap['max'], greaterThanOrEqualTo(snap['p50']! as num));
      expect((live['ops']! as Map)['max'], greaterThan(50));
      expect((live['blk']! as Map)['max'], greaterThan(0));
      // El benchmark existe para imprimir sus números.
      // ignore: avoid_print
      print('replay stats (debug JIT): ${ThorReplay.instance!.stats}');

      await tester.runAsync(ThorReplay.stop);
      final records = statsRecords();
      // Una sola línea por flush con snapshots nuevos.
      expect(records, hasLength(1));
      expect((records.single['snap']! as Map)['n'], snap['n']);
    });

    testWidgets('snapshots over budget back off idle/maxGap', (tester) async {
      await tester.pumpWidget(heavyApp(0));
      await tester.runAsync(
        () => ThorReplay.start(
          // Presupuesto imposible: todo snapshot se pasa.
          const ThorReplayConfig(snapshotBudget: Duration.zero),
          directory: dir,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 1; i <= 3; i++) {
        await tester.pumpWidget(heavyApp(i));
        await tester.pump(const Duration(seconds: 3));
      }
      final bo = ThorReplay.instance!.stats.toJson()['bo']! as Map;
      expect(bo['n'], greaterThanOrEqualTo(1));
      expect(bo['x'], greaterThanOrEqualTo(2));

      // Espaciado: con ×2 el idle es 500 ms; a los 300 ms aún no captura.
      final before =
          (ThorReplay.instance!.stats.toJson()['snap']! as Map)['n']! as int;
      final x = bo['x']! as int;
      await tester.pumpWidget(heavyApp(4));
      await tester.pump(Duration(milliseconds: 250 * x - 50));
      final after =
          (ThorReplay.instance!.stats.toJson()['snap']! as Map)['n']! as int;
      expect(after, before);
      await tester.pump(const Duration(seconds: 3));
      // Sus timers no deben sobrevivir al test.
      await tester.runAsync(ThorReplay.stop);
    });
  });
}

/// Copia literal del `_split` original (jsonEncode por op): la referencia
/// contra la que se compara la versión optimizada.
({
  List<List<Object?>> vps,
  List<List<Object?>> refs,
  Map<String, String> blocks,
}) _referenceSplit(List<List<Object?>> ops) {
  num sub(num a, num b) {
    final d = ((a - b) * 2).round();
    return d.isEven ? d ~/ 2 : d / 2;
  }

  bool isBoundary(List<Object?> op) =>
      ThorReplay.fnv32(jsonEncode([op[0], op[3], op[4], ...op.skip(6)])) % 32 ==
      0;

  final vps = <List<Object?>>[];
  final refs = <List<Object?>>[];
  final blocks = <String, String>{};
  var current = <List<Object?>>[];
  int? vp;

  void close() {
    if (current.isEmpty) return;
    final first = current.first;
    final ox = first[1]! as num;
    final oy = first[2]! as num;
    final rel = [
      for (final op in current)
        [
          op[0],
          sub(op[1]! as num, ox),
          sub(op[2]! as num, oy),
          op[3],
          op[4],
          ...op.skip(6),
        ],
    ];
    final body = jsonEncode(rel);
    final hash = ThorReplay.fnv(body);
    blocks[hash] = '["blk","$hash",$body]';
    refs.add([hash, vp, ox, oy]);
    current = [];
  }

  for (final op in ops) {
    if (op[0] == 'v') {
      vps.add([op[6], op[5], op[1], op[2], op[3], op[4], op[7]]);
      continue;
    }
    final opVp = op[5]! as int;
    if (opVp != vp) {
      close();
      vp = opVp;
    }
    current.add(op);
    if (current.length >= 4 && isBoundary(op)) close();
  }
  close();
  return (vps: vps, refs: refs, blocks: blocks);
}
