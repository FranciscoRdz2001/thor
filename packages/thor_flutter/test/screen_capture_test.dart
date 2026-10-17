import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

class HomeBody extends StatelessWidget {
  const HomeBody({super.key});
  @override
  Widget build(BuildContext context) => const Text('inicio');
}

class FavoriteBody extends StatelessWidget {
  const FavoriteBody({super.key});
  @override
  Widget build(BuildContext context) => const Text('favoritos');
}

class BannerView extends StatelessWidget {
  const BannerView({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox(height: 80);
}

class DetailPage extends StatelessWidget {
  const DetailPage({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('detalle'));
}

Widget tabs(int index) => MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            // A small carousel named like a screen must not win.
            const SizedBox(height: 80, child: BannerView()),
            Expanded(
              child: IndexedStack(
                index: index,
                children: const [
                  SizedBox.expand(child: HomeBody()),
                  SizedBox.expand(child: FavoriteBody()),
                ],
              ),
            ),
          ],
        ),
      ),
    );

void main() {
  setUp(() async => ThorCore.init());
  tearDown(() {
    ScreenCapture.uninstall();
    ThorCore.debugReset();
  });

  testWidgets('the visible tab of an IndexedStack is the screen',
      (tester) async {
    await tester.pumpWidget(tabs(0));
    expect(ScreenCapture.detect(), 'HomeBody');

    await tester.pumpWidget(tabs(1));
    expect(ScreenCapture.detect(), 'FavoriteBody');
  });

  testWidgets('a change is recorded once as navigation', (tester) async {
    await tester.pumpWidget(tabs(0));
    ScreenCapture.check();
    ScreenCapture.check();
    await tester.pumpWidget(tabs(1));
    ScreenCapture.check();

    final nav = ThorCore.instance!.store
        .ofKind(ThorEventKind.navigation)
        .map((e) => e.payload['to'])
        .toList();
    expect(nav, ['HomeBody', 'FavoriteBody']);
    expect(
      ThorCore.instance!.recorder.currentScreen?.widgetClass,
      'FavoriteBody',
    );
  });

  testWidgets('the page of a PageView in view is the screen', (tester) async {
    final controller = PageController();
    await tester.pumpWidget(
      MaterialApp(
        home: PageView(
          controller: controller,
          children: const [HomeBody(), FavoriteBody()],
        ),
      ),
    );
    expect(ScreenCapture.detect(), 'HomeBody');
    controller.jumpToPage(1);
    await tester.pump();
    expect(ScreenCapture.detect(), 'FavoriteBody');
  });

  testWidgets('a route covered by an opaque one is not the screen',
      (tester) async {
    await tester.pumpWidget(tabs(0));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      nav.push(MaterialPageRoute<void>(builder: (_) => const DetailPage())),
    );
    await tester.pumpAndSettle();
    expect(ScreenCapture.detect(), 'DetailPage');
  });

  testWidgets('the replay draws only the visible tab', (tester) async {
    final dir = Directory.systemTemp.createTempSync('thor_tabs');
    await tester.pumpWidget(tabs(0));
    await tester.runAsync(
      () => ThorReplay.start(
        const ThorReplayConfig(maskText: false),
        directory: dir,
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(ThorReplay.stop);
    final body = dir
        .listSync()
        .whereType<File>()
        .singleWhere((f) => f.path.endsWith('.jsonl'))
        .readAsStringSync();
    expect(body, contains(jsonEncode('inicio')));
    expect(body, isNot(contains('favoritos')));
    dir.deleteSync(recursive: true);
  });
}
