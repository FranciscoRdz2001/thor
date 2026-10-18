import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

class CheckoutPage extends StatelessWidget {
  const CheckoutPage({super.key});
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('pagar'));
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                // Sin settings.name a propósito: el caso que rompe a
                // las librerías de analytics.
                builder: (_) => const CheckoutPage(),
              ),
            ),
            child: const Text('ir'),
          ),
        ),
      );
}

void main() {
  setUp(() async {
    ThorCore.debugReset();
    await ThorCore.init();
  });

  tearDown(ThorCore.debugReset);

  List<ThorEvent> navEvents() =>
      ThorCore.instance!.store.ofKind(ThorEventKind.navigation);

  testWidgets('push sin settings.name resuelve la CLASE del widget',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ThorNavigatorObserver()],
        home: const HomePage(),
      ),
    );
    await tester.tap(find.text('ir'));
    await tester.pumpAndSettle();

    final push = navEvents().last;
    expect(push.payload['action'], 'push');
    expect(push.payload['to'], 'CheckoutPage');
    expect(
      ThorCore.instance!.recorder.currentScreen?.widgetClass,
      'CheckoutPage',
    );
  });

  testWidgets('pop regresa la pantalla activa a la de abajo', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ThorNavigatorObserver()],
        home: const HomePage(),
      ),
    );
    await tester.tap(find.text('ir'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('pagar'))).pop();
    await tester.pumpAndSettle();

    final pop = navEvents().last;
    expect(pop.payload['action'], 'pop');
    // La activa vuelve a ser la ruta de abajo ('/', la home).
    expect(
      ThorCore.instance!.recorder.currentScreen?.display,
      isNot('CheckoutPage'),
    );
  });

  testWidgets('rutas con nombre conservan routeName Y clase', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ThorNavigatorObserver()],
        routes: {
          '/': (_) => const HomePage(),
          '/checkout': (_) => const CheckoutPage(),
        },
      ),
    );
    unawaited(
      Navigator.of(tester.element(find.byType(HomePage)))
          .pushNamed('/checkout'),
    );
    await tester.pumpAndSettle();

    final screen = ThorCore.instance!.recorder.currentScreen!;
    expect(screen.routeName, '/checkout');
    expect(screen.display, isNotEmpty);
  });

  testWidgets('diálogos entran a la línea de tiempo como rutas',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ThorNavigatorObserver()],
        home: const HomePage(),
      ),
    );
    final context = tester.element(find.byType(HomePage));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(title: Text('confirmar')),
      ),
    );
    await tester.pumpAndSettle();

    final push = navEvents().last;
    expect(push.payload['action'], 'push');
    expect(push.payload['to'], contains('DialogRoute'));
  });

  testWidgets('Thor apagado (sin init): el observer es inerte, no revienta',
      (tester) async {
    ThorCore.debugReset();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ThorNavigatorObserver()],
        home: const HomePage(),
      ),
    );
    await tester.tap(find.text('ir'));
    await tester.pumpAndSettle();
    expect(find.text('pagar'), findsOneWidget); // navegó normal
  });

  testWidgets('argumentos de ruta: solo el TIPO, jamás el valor',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ThorNavigatorObserver()],
        home: const HomePage(),
      ),
    );
    unawaited(
      Navigator.of(tester.element(find.byType(HomePage))).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(
            name: '/detalle',
            arguments: {'telefono': '6641234567'},
          ),
          builder: (_) => const CheckoutPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final push = navEvents().last;
    expect(push.payload['argsType'], isNotNull);
    expect(push.payload.toString(), isNot(contains('6641234567')));
  });

  testWidgets(
      'rutas de la UI de Thor (thor/…) no son navegación ni cambian la '
      'pantalla activa', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [ThorNavigatorObserver()],
        home: const HomePage(),
      ),
    );
    final recorder = ThorCore.instance!.recorder;
    final eventsBefore = navEvents().length;
    final screenBefore = recorder.currentScreen?.display;

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const CheckoutPage(),
          settings: const RouteSettings(name: 'thor/crash-report'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();

    expect(navEvents(), hasLength(eventsBefore));
    expect(recorder.currentScreen?.display, screenBefore);
  });
}
