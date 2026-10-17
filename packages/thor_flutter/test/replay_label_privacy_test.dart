import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/src/replay/wireframe.dart';
import 'package:thor_flutter/thor_flutter.dart';

/// Pantalla con lo que fugaba: una fila con datos de la persona, un botón
/// con copy, copy marcado como seguro y una zona ignorada.
class _Page extends StatelessWidget {
  const _Page();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(
          children: [
            ListTile(
              key: const ValueKey('cliente-ana@mail.com'),
              title: const Text('Ana Pérez'),
              subtitle: const Text('ana@mail.com'),
              onTap: () {},
            ),
            ElevatedButton(
              key: const ValueKey('pagar-10293847'),
              onPressed: () {},
              child: const Text('Pagar'),
            ),
            ThorReplayShowText(
              child: ListTile(
                title: const Text('Mis pedidos'),
                subtitle: const Text('Soporte soporte@tienda.mx'),
                onTap: () {},
              ),
            ),
            ListTile(title: const Text('Ajustes'), onTap: () {}),
            ThorReplayIgnore(
              child: ElevatedButton(
                onPressed: () {},
                child: const Text('Tarjeta 4111'),
              ),
            ),
          ],
        ),
      );
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('thor_label_privacy');
    await ThorCore.init();
    InteractionCapture.install();
  });

  tearDown(() async {
    InteractionCapture.uninstall();
    await ThorReplay.stop();
    ThorCore.debugReset();
    dir.deleteSync(recursive: true);
  });

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

  List<Map<String, Object?>> taps(List<Object?> all) => [
        for (final r in all.whereType<Map<String, Object?>>())
          if (r['t'] == 'ev' && r['k'] == 'interaction')
            r['p']! as Map<String, Object?>,
      ];

  Future<void> start(WidgetTester tester, ThorReplayConfig config) async {
    await tester.pumpWidget(const MaterialApp(home: _Page()));
    await tester.runAsync(() => ThorReplay.start(config, directory: dir));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('tap on a ListTile with personal data: masked, no key',
      (tester) async {
    await start(tester, const ThorReplayConfig());
    await tester.tap(find.text('Ana Pérez'));
    await tester.pump(const Duration(milliseconds: 300));

    final all = await records(tester);
    final tap = taps(all).single;
    expect(tap['w'], 'ListTile');
    // Igual que el texto en pantalla: largos de palabra.
    expect(tap['l'], [3, 5]);
    expect(tap.containsKey('k'), isFalse);
    final body = jsonEncode(all);
    expect(body, isNot(contains('Ana')));
    expect(body, isNot(contains('mail.com')));

    // El journal local conserva el label completo (reporte de QA).
    final local =
        ThorCore.instance!.store.ofKind(ThorEventKind.interaction).last;
    expect(local.payload['label'], 'Ana Pérez');
    expect(local.payload.containsKey('copy'), isFalse);
  });

  testWidgets('high-level button copy stays readable; key scrubbed',
      (tester) async {
    await start(tester, const ThorReplayConfig());
    await tester.tap(find.text('Pagar'));
    await tester.pump(const Duration(milliseconds: 300));

    final tap = taps(await records(tester)).single;
    expect(tap['w'], 'ElevatedButton');
    expect(tap['l'], 'Pagar');
    expect(tap['k'], 'pagar-:n');
  });

  testWidgets('ThorReplayShowText: screen text and tap label unmasked',
      (tester) async {
    await start(tester, const ThorReplayConfig());
    await tester.tap(find.text('Mis pedidos'));
    await tester.pump(const Duration(milliseconds: 300));

    final all = await records(tester);
    expect(taps(all).single['l'], 'Mis pedidos');
    final texts = [
      for (final b in all.whereType<List<Object?>>())
        if (b[0] == 'blk')
          for (final op in b[2]! as List)
            if ((op as List)[0] == 't') op.last,
    ];
    expect(texts, contains('Mis pedidos'));
    // Copy declarado, pero lo que tiene forma de dato igual se quita.
    expect(texts, contains('Soporte :email'));
    // Fuera de la zona, todo sigue enmascarado.
    expect(texts, contains(equals([3, 5])));
    expect(texts, isNot(contains('Ana Pérez')));
  });

  testWidgets('unmaskedTexts: exact l10n strings travel readable',
      (tester) async {
    await start(tester, const ThorReplayConfig(unmaskedTexts: {'Ajustes'}));
    await tester.tap(find.text('Ajustes'));
    await tester.pump(const Duration(milliseconds: 300));

    final all = await records(tester);
    expect(taps(all).single['l'], 'Ajustes');
    final body = jsonEncode(all);
    expect(body, contains('"Ajustes"'));
    expect(body, isNot(contains('Ana')));
  });

  testWidgets('tap inside ThorReplayIgnore: neither label nor key',
      (tester) async {
    await start(tester, const ThorReplayConfig(maskText: false));
    await tester.tap(find.text('Tarjeta 4111'));
    await tester.pump(const Duration(milliseconds: 300));

    final all = await records(tester);
    final tap = taps(all).single;
    expect(tap.keys, unorderedEquals(['g', 'w']));
    expect(jsonEncode(all), isNot(contains('Tarjeta')));
  });

  testWidgets('maskText off: labels readable but always scrubbed',
      (tester) async {
    await start(tester, const ThorReplayConfig(maskText: false));
    await tester.tap(find.text('Ana Pérez'));
    await tester.pump(const Duration(milliseconds: 300));

    final tap = taps(await records(tester)).single;
    expect(tap['l'], 'Ana Pérez');
    // Cae el token completo alrededor de la @: un guión es válido en un
    // email, así que el prefijo podría ser parte del nombre.
    expect(tap['k'], ':email');
  });

  testWidgets('semantics-channel labels (merged children) are masked',
      (tester) async {
    await start(tester, const ThorReplayConfig());
    ThorCore.instance!.recorder.record(ThorEventKind.interaction, {
      'gesture': 'tap',
      'via': 'semantics',
      'label': 'Ana Pérez\nana@mail.com',
      'widget': 'Button',
    });

    final tap = taps(await records(tester)).single;
    expect(tap['l'], [3, 5, 12]);
  });

  testWidgets('wireframe ops of unchanged widgets are byte-identical',
      (tester) async {
    Widget screen({required bool wrap}) => MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const Text('Ana Pérez'),
                Container(color: Colors.blue, height: 40, width: 200),
                if (wrap)
                  const ThorReplayShowText(child: Text('Mis pedidos'))
                else
                  const Text('Mis pedidos'),
                const Text('Total 123'),
              ],
            ),
          ),
        );

    List<String> ops(Set<String> unmasked) => [
          for (final op in WireframeBuilder(
            maskText: true,
            unmaskedTexts: unmasked,
          ).build()!.ops)
            jsonEncode(op),
        ];

    await tester.pumpWidget(screen(wrap: false));
    final before = ops(const {});
    // Un allowlist que no toca esta pantalla no cambia nada.
    expect(ops(const {'Pagar'}), before);

    await tester.pumpWidget(screen(wrap: true));
    final after = ops(const {});
    expect(after, hasLength(before.length));
    final changed = [
      for (var i = 0; i < before.length; i++)
        if (before[i] != after[i]) after[i],
    ];
    // Solo el texto marcado cambia; el resto conserva su hash de bloque.
    expect(changed, hasLength(1));
    expect(changed.single, contains('"Mis pedidos"'));
  });
}
