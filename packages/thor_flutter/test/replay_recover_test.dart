import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

void main() {
  test('a session left on disk uploads what it missed, then is deleted',
      () async {
    final dir = Directory.systemTemp.createTempSync('thor_recover');
    final received = <String, List<String>>{};
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body =
          utf8.decode(gzip.decode(await req.expand((c) => c).toList()));
      final lines = const LineSplitter().convert(body);
      received
          .putIfAbsent(req.headers.value('x-thor-session')!, () => [])
          .addAll(lines);
      final asksBlock = lines.any((l) => l.startsWith('["st"'));
      req.response
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({
            'missing': asksBlock ? ['aaaaaaaaaaaaaaaa'] : <String>[],
          }),
        );
      await req.response.close();
    });
    final endpoint = Uri.parse('http://127.0.0.1:${server.port}/api/ingest');

    // Crashed session: 3 records, the first one already uploaded.
    File('${dir.path}/replay-old-1.jsonl').writeAsStringSync(
      [
        '["blk","aaaaaaaaaaaaaaaa",[["r",0,0,10,10,null,null,null,null]]]',
        '{"t":"meta","v":2}',
        '["st",10,"1111111111111111",{},[],[["aaaaaaaaaaaaaaaa",0,0,0]]]',
        '["p",20,"d",1,1]',
      ].join('\n'),
    );
    File('${dir.path}/replay-old-1.on').writeAsStringSync('1');
    File('${dir.path}/replay-old-1.sent').writeAsStringSync('1');
    // Not sampled, no error: never uploads, just goes away.
    File('${dir.path}/replay-old-2.jsonl').writeAsStringSync('["p",1,"d",1,1]');
    final current = File('${dir.path}/replay-now.jsonl')..writeAsStringSync('');

    await ThorReplay.recover(dir, endpoint, current);
    await server.close(force: true);

    expect(received.keys, ['old-1']);
    expect(received['old-1'], [
      '["st",10,"1111111111111111",{},[],[["aaaaaaaaaaaaaaaa",0,0,0]]]',
      '["p",20,"d",1,1]',
      '["blk","aaaaaaaaaaaaaaaa",[["r",0,0,10,10,null,null,null,null]]]',
    ]);
    expect(
      dir.listSync().map((f) => f.uri.pathSegments.last),
      ['replay-now.jsonl'],
    );
    dir.deleteSync(recursive: true);
  });
}
