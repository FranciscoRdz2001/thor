import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

/// Duplicados en la subida del replay: secuencia `q` por registro, un solo
/// flush a la vez, recuperación que no pisa a un dueño vivo y `meta`/`user`
/// una vez por sesión.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late HttpServer server;
  final ingested = <String>[];
  var requests = 0;
  var inFlight = 0;
  var maxInFlight = 0;
  var delay = Duration.zero;

  Uri endpointUri() => Uri.parse('http://127.0.0.1:${server.port}/api/ingest');

  setUp(() async {
    // El binding de test cambia HttpClient por uno falso: aquí se quiere el
    // servidor local de verdad.
    HttpOverrides.global = null;
    dir = Directory.systemTemp.createTempSync('thor_dedupe');
    ingested.clear();
    requests = 0;
    inFlight = 0;
    maxInFlight = 0;
    delay = Duration.zero;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
      ..listen((req) async {
        requests++;
        inFlight++;
        if (inFlight > maxInFlight) maxInFlight = inFlight;
        final bytes = await req.expand((c) => c).toList();
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        ingested.addAll(
          const LineSplitter().convert(utf8.decode(gzip.decode(bytes))),
        );
        req.response.write(jsonEncode({'missing': <String>[]}));
        await req.response.close();
        inFlight--;
      });
    await ThorCore.init(
      deviceInfo: const {
        'os': 'ios',
        'osVersion': 'Version 18.2',
        'locale': 'es_MX',
        'model': 'iPhone16,1',
        'simulator': 'true',
      },
    );
  });

  tearDown(() async {
    await ThorReplay.stop();
    ThorCore.debugReset();
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  List<Object?> parse(Iterable<String> lines) => [
        for (final l in lines)
          if (l.isNotEmpty) jsonDecode(l) as Object?,
      ];

  /// `q` de un registro (mapa: clave; arreglo: último elemento).
  int? seqOf(Object? r) => switch (r) {
        final Map<String, Object?> m => m['q'] as int?,
        final List<Object?> l when l.first != 'blk' => l.last as int?,
        _ => null,
      };

  List<Object?> onDisk() {
    final file = dir
        .listSync()
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.jsonl'));
    return parse(file.readAsLinesSync());
  }

  test('every record carries a monotonic q; blocks do not', () async {
    await ThorReplay.start(const ThorReplayConfig(), directory: dir);
    final core = ThorCore.instance!;
    for (var i = 0; i < 5; i++) {
      core.mark('m$i');
    }
    await ThorReplay.stop();

    final records = onDisk();
    final qs = [
      for (final r in records)
        if (seqOf(r) != null) seqOf(r)!,
    ];
    expect(qs, isNotEmpty);
    expect(qs, [for (var i = 1; i <= qs.length; i++) i]);
    for (final r in records) {
      if (r is List && r.first == 'blk') expect(r, hasLength(3));
    }
    expect((records.first! as Map)['t'], 'meta');
    expect((records.first! as Map)['q'], 1);
  });

  test('meta carries the install id and the device', () async {
    await ThorReplay.start(const ThorReplayConfig(), directory: dir);
    await ThorReplay.stop();
    final meta = onDisk().first! as Map<String, Object?>;
    expect(meta['iid'], ThorCore.instance!.session.installId);
    expect(meta['device'], {
      'os': 'ios',
      'osVersion': 'Version 18.2',
      'locale': 'es_MX',
      'model': 'iPhone16,1',
      'simulator': true,
    });
  });

  test('meta and user are written once per session', () async {
    Thor.setUser('cli_1', props: {'plan': 'gold'});
    await ThorReplay.start(const ThorReplayConfig(), directory: dir);
    // Lo mismo otra vez (login que reafirma al usuario): nada nuevo.
    Thor.setUser('cli_1', props: {'plan': 'gold'});
    Thor.setUser('cli_2');
    Thor.setUser('cli_2');
    Thor.setUser('cli_1', props: {'plan': 'gold'});
    await ThorReplay.stop();

    final maps = onDisk().whereType<Map<String, Object?>>();
    expect(maps.where((m) => m['t'] == 'meta'), hasLength(1));
    expect(maps.where((m) => m['t'] == 'meta').single['uid'], 'cli_1');
    expect(
      [
        for (final m in maps)
          if (m['t'] == 'user') m['id'],
      ],
      ['cli_2', 'cli_1'],
    );
  });

  test('concurrent flushes upload each record exactly once, one at a time',
      () async {
    delay = const Duration(milliseconds: 40);
    await ThorReplay.start(
      ThorReplayConfig(
        endpoint: endpointUri(),
        saveEvery: const Duration(hours: 1),
      ),
      directory: dir,
    );
    final core = ThorCore.instance!;
    final flushes = <Future<void>>[];
    for (var i = 0; i < 6; i++) {
      core.mark('lote $i');
      // Fondo + error + dashboard a la vez: antes dos subidas mandaban el
      // mismo lote.
      flushes
        ..add(ThorReplay.instance!.flush())
        ..add(ThorReplay.instance!.flush());
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future.wait(flushes);
    await ThorReplay.stop();

    expect(maxInFlight, 1, reason: 'una subida a la vez');
    final qs = [
      for (final r in parse(ingested))
        if (seqOf(r) != null) seqOf(r)!,
    ];
    expect(qs.toSet(), hasLength(qs.length), reason: 'sin repetidos');
    final onDiskQs = [
      for (final r in onDisk())
        if (seqOf(r) != null) seqOf(r)!,
    ];
    expect(qs..sort(), onDiskQs, reason: 'sube todo lo que grabó');
    // El servidor confirmó hasta el último: `.sent` lo dice.
    final sent = dir
        .listSync()
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.sent'))
        .readAsStringSync();
    expect(sent, 'q:${onDiskQs.last}');
  });

  test('recovery resumes after the acknowledged q, not from the start',
      () async {
    File('${dir.path}/replay-old-1.jsonl').writeAsStringSync(
      [
        '{"t":"meta","v":2,"q":1}',
        '["p",20,"d",1,1,2]',
        '["p",30,"u",1,1,3]',
        '{"t":"ev","ts":40,"k":"log","p":{"l":"x"},"q":4}',
      ].join('\n'),
    );
    File('${dir.path}/replay-old-1.on').writeAsStringSync('1');
    File('${dir.path}/replay-old-1.sent').writeAsStringSync('q:2');
    final current = File('${dir.path}/replay-now.jsonl')..writeAsStringSync('');

    await ThorReplay.recover(dir, endpointUri(), current);

    expect(ingested, [
      '["p",30,"u",1,1,3]',
      '{"t":"ev","ts":40,"k":"log","p":{"l":"x"},"q":4}',
    ]);
    expect(
      dir.listSync().map((f) => f.uri.pathSegments.last),
      ['replay-now.jsonl'],
    );
  });

  test('recovery leaves alone a session whose owner is still alive', () async {
    await ThorReplay.start(
      ThorReplayConfig(
        endpoint: endpointUri(),
        saveEvery: const Duration(hours: 1),
      ),
      directory: dir,
    );
    ThorCore.instance!.mark('pendiente');
    await ThorReplay.instance!.flush(upload: false); // a disco, sin subir
    final sid = ThorCore.instance!.session.sessionId;
    final other = File('${dir.path}/replay-otra.jsonl')..writeAsStringSync('');

    await ThorReplay.recover(dir, endpointUri(), other);

    expect(requests, 0, reason: 'la recuperación no sube la sesión viva');
    expect(File('${dir.path}/replay-$sid.jsonl').existsSync(), isTrue);

    // Cuando el dueño termina (su flush final sube todo), ya no es suyo: la
    // recuperación solo limpia, sin volver a subir nada.
    await ThorReplay.stop();
    final uploaded = ingested.length;
    expect(uploaded, greaterThan(0));
    await ThorReplay.recover(dir, endpointUri(), other);
    expect(ingested, hasLength(uploaded), reason: 'nada se sube dos veces');
    expect(File('${dir.path}/replay-$sid.jsonl').existsSync(), isFalse);
  });

  test('events carry the screen context (sd) and screen_context signals',
      () async {
    await ThorReplay.start(const ThorReplayConfig(), directory: dir);
    final core = ThorCore.instance!..setScreen('SearchScreen');
    Thor.setScreenContext('Departamentos > Carnes > Res Selecta');
    core.mark('despues');
    await ThorReplay.stop();

    final evs = onDisk().whereType<Map<String, Object?>>().where(
          (m) => m['t'] == 'ev',
        );
    final after = evs.lastWhere((m) => m['k'] == 'log');
    expect(after['sc'], 'SearchScreen');
    expect(after['sd'], 'Departamentos > Carnes > Res Selecta');
    final ctx = evs.firstWhere(
      (m) => m['k'] == 'environment' && (m['p']! as Map)['signal'] != null,
    );
    expect((ctx['p']! as Map)['signal'], 'screen_context');
    expect((ctx['p']! as Map)['value'], 'Departamentos > Carnes > Res Selecta');
  });
}
