// Atribución de pantalla (T-N04): primera pantalla transitoria, push
// duplicado, nombres semánticos de diálogos y `sd` que no se hereda.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/src/visible_tree.dart';
import 'package:thor_flutter/thor_flutter.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('hola'));
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('splash'));
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('home'));
}

List<ThorEvent> _navs() =>
    ThorCore.instance!.store.ofKind(ThorEventKind.navigation);

Route<void> _route(Widget page) =>
    MaterialPageRoute<void>(builder: (_) => page);

void main() {
  setUp(() async {
    ThorCore.debugReset();
    await ThorCore.init();
    ThorNavigatorObserver.holdFirstScreen = true;
  });

  tearDown(() {
    ThorNavigatorObserver.holdFirstScreen = false;
    ScreenCapture.uninstall();
    ThorCore.debugReset();
  });

  group('primera pantalla transitoria', () {
    testWidgets('Onboarding reemplazada al instante no queda en la línea',
        (tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: key,
          navigatorObservers: [ThorNavigatorObserver()],
          home: const OnboardingScreen(),
        ),
      );
      // Mismo cuadro: el reemplazo llega a los pocos ms.
      unawaited(
          key.currentState!.pushReplacement(_route(const SplashScreen())),);
      await tester.pumpAndSettle();
      final navs = _navs();
      expect(navs.map((e) => e.payload['to']), ['SplashScreen']);
      expect(navs.single.payload['skipped'], 'OnboardingScreen');
      expect(navs.single.payload.containsKey('from'), isFalse);
      expect(
        ThorCore.instance!.recorder.currentScreen?.widgetClass,
        'SplashScreen',
      );
    });

    testWidgets('una primera pantalla que aguanta SÍ queda registrada',
        (tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: key,
          navigatorObservers: [ThorNavigatorObserver()],
          home: const OnboardingScreen(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(_navs().map((e) => e.payload['to']), ['OnboardingScreen']);
      unawaited(
          key.currentState!.pushReplacement(_route(const SplashScreen())),);
      await tester.pumpAndSettle();
      expect(_navs().map((e) => e.payload['to']), [
        'OnboardingScreen',
        'SplashScreen',
      ]);
      expect(_navs().last.payload['skipped'], isNull);
    });
  });

  group('push duplicado', () {
    testWidgets('dos push de HomeScreen seguidos: el segundo se marca',
        (tester) async {
      ThorNavigatorObserver.holdFirstScreen = false;
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: key,
          navigatorObservers: [ThorNavigatorObserver()],
          home: const HomeScreen(),
        ),
      );
      unawaited(key.currentState!.push(_route(const HomeScreen())));
      await tester.pumpAndSettle();
      final pushes = _navs().where((e) => e.payload['action'] == 'push');
      expect(pushes.first.payload['duplicate'], isNull);
      expect(pushes.last.payload['duplicate'], isTrue);
    });

    testWidgets('push de otra pantalla no se marca', (tester) async {
      ThorNavigatorObserver.holdFirstScreen = false;
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: key,
          navigatorObservers: [ThorNavigatorObserver()],
          home: const HomeScreen(),
        ),
      );
      unawaited(key.currentState!.push(_route(const SplashScreen())));
      await tester.pumpAndSettle();
      expect(_navs().last.payload['duplicate'], isNull);
    });
  });

  group('nombres semánticos', () {
    test('diálogos y hojas se nombran, sin perder el tipo de ruta', () {
      expect(
        const ScreenId(routeType: 'DialogRoute<void>').display,
        'Dialog (DialogRoute<void>)',
      );
      expect(
        const ScreenId(routeType: 'ModalBottomSheetRoute<dynamic>').display,
        'BottomSheet (ModalBottomSheetRoute<dynamic>)',
      );
      expect(
        const ScreenId(routeType: 'MaterialPageRoute<void>').display,
        'MaterialPageRoute<void>',
      );
      expect(const ScreenId(widgetClass: 'CartPage').display, 'CartPage');
      expect(const ScreenId().display, 'Desconocida');
    });

    test('DisplayFeatureSubScreen no es una pantalla de la app', () {
      expect(VisibleTree.isScreenName('DisplayFeatureSubScreen'), isFalse);
      expect(VisibleTree.isScreenName('FiltersScreen'), isTrue);
    });

    testWidgets('un showDialog queda como Dialog, no como la pantalla de abajo',
        (tester) async {
      ThorNavigatorObserver.holdFirstScreen = false;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [ThorNavigatorObserver()],
          home: const HomeScreen(),
        ),
      );
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(HomeScreen)),
          builder: (_) => const AlertDialog(title: Text('micrófono')),
        ),
      );
      await tester.pumpAndSettle();
      final screen = ThorCore.instance!.recorder.currentScreen!;
      expect(screen.display, startsWith('Dialog ('));
      expect(screen.widgetClass, isNull);
    });
  });

  group('sd no se hereda', () {
    List<Map<String, Object?>> ctx() => [
          for (final e
              in ThorCore.instance!.store.ofKind(ThorEventKind.environment))
            if (e.payload['signal'] == 'screen_context') e.payload,
        ];

    testWidgets('al enfocar un campo se quita el contexto que puso la app',
        (tester) async {
      ThorNavigatorObserver.holdFirstScreen = false;
      await tester.pumpWidget(
        MaterialApp(
          navigatorObservers: [ThorNavigatorObserver()],
          home: const Scaffold(body: TextField()),
        ),
      );
      final core = ThorCore.instance!
        ..setScreen('SearchScreen')
        ..setScreenContext('Búsqueda > 7501055300');
      expect(core.recorder.currentScreen!.detail, 'Búsqueda > 7501055300');
      ScreenCapture.onTextFocus();
      expect(core.recorder.currentScreen!.detail, isNull);
      expect(ctx().last['reason'], 'text_focus');
      // Idempotente: sin contexto no hay nada que quitar.
      final before = ctx().length;
      ScreenCapture.onTextFocus();
      expect(ctx(), hasLength(before));
    });

    testWidgets('si el AppBar desaparece, su título no queda como sd',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            appBar: _Bar('Frutas'),
            body: FakeBody(),
          ),
        ),
      );
      ScreenCapture.check();
      final core = ThorCore.instance!;
      expect(core.recorder.currentScreen?.detail, 'Frutas');

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: FakeBody())),
      );
      ScreenCapture.check();
      expect(core.recorder.currentScreen?.detail, isNull);
    });
  });
}

class _Bar extends StatelessWidget implements PreferredSizeWidget {
  const _Bar(this.title);
  final String title;
  @override
  Size get preferredSize => const Size.fromHeight(56);
  @override
  Widget build(BuildContext context) => AppBar(title: Text(title));
}

class FakeBody extends StatelessWidget {
  const FakeBody({super.key});
  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(child: Center(child: Text('contenido')));
}
