import 'dart:async';
import 'dart:io' show Platform;

import 'package:clock/clock.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/overlay/thor_overlay.dart';
import 'package:thor_flutter/src/overlay/thor_ui.dart';

/// Navegación inicial retenida (ver `ThorNavigatorObserver.firstScreenSettle`).
class _HeldNav {
  _HeldNav({
    required this.payload,
    required this.screen,
    required this.at,
    required this.timer,
  });

  final Map<String, Object?> payload;
  final ScreenId screen;
  final DateTime at;
  final Timer timer;
}

/// Observer universal de navegación.
///
/// Funciona con CUALQUIER router porque `NavigatorObserver` es la primitiva
/// que todos aceptan (go_router `observers:`, auto_route
/// `navigatorObservers:`, Beamer, `MaterialApp` pelón). Único punto de
/// integración manual del paquete:
///
/// ```dart
/// MaterialApp(navigatorObservers: [ThorNavigatorObserver()]);
/// GoRouter(observers: [ThorNavigatorObserver()]);
/// ```
///
/// Resuelve la identidad de pantalla en cascada (barato → certero):
/// 1. `settings.name` — lo que el router declaró.
/// 2. El `runtimeType` del widget construido por el builder de la ruta
///    (cubre el `Navigator.push(MaterialPageRoute(...))` sin settings).
/// 3. Retro-corrección desde el árbol montado (la hace el capturador de
///    interacciones al primer tap — ver `InteractionCapture`).
class ThorNavigatorObserver extends NavigatorObserver {
  /// Crea el observer.
  ///
  /// [resolveWidgetClass]: si `false`, salta el paso 2 de la cascada
  /// (instanciar el widget del builder). Apágalo solo si algún constructor
  /// de página tiene efectos secundarios — raro, pero posible.
  ThorNavigatorObserver({this.resolveWidgetClass = true});

  /// Controla el paso 2 de la cascada de resolución.
  final bool resolveWidgetClass;

  /// Si el observer monta la burbuja del inspector al primer push.
  /// Lo fija `Thor.run(showOverlay: ...)`; default apagado hasta el run.
  static bool overlayEnabled = false;

  ThorCore? get _core => ThorCore.instance;

  /// La primera pantalla de la sesión que se reemplaza en este tiempo no la
  /// vio el usuario (`Onboarding` → `Splash` a los 3 ms): no queda en la
  /// línea de tiempo. Igual que `PerformanceCapture.firstScreenSettle` (una
  /// sola regla para "la primera pantalla").
  @visibleForTesting
  static Duration firstScreenSettle = const Duration(milliseconds: 50);

  /// Retener la primera pantalla (ver [firstScreenSettle]). Apagado en las
  /// pruebas de widgets de la app (`FLUTTER_TEST`): el `Timer` de espera
  /// dejaría "timers pendientes". Las pruebas de Thor lo encienden.
  @visibleForTesting
  static bool holdFirstScreen =
      !Platform.environment.containsKey('FLUTTER_TEST');

  /// La primera navegación, retenida mientras no se sabe si es transitoria.
  _HeldNav? _held;
  bool _firstNavSeen = false;

  /// Graba la navegación retenida (la primera pantalla aguantó).
  void _flushHeld() {
    final held = _held;
    if (held == null) return;
    _held = null;
    held.timer.cancel();
    final core = _core;
    if (core == null) return;
    _record(core, held);
  }

  /// La pantalla que estaba activa MIENTRAS la ruta era la de arriba, al
  /// momento de taparla con otra ruta. Al hacer pop hay que devolver
  /// esa y no la que se deduce del builder de la ruta: una ruta raíz
  /// (`HomeScreen`) puede mostrar tabs/sub-pantallas que solo ve el árbol
  /// (`ScreenCapture`), y volver de un detalle a un PLP dentro del home
  /// aparecía siempre como `HomeScreen`.
  static final Expando<ScreenId> _screenUnder = Expando('thor screen under');

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _onActive(route, action: 'push', from: previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // Al hacer pop, la pantalla activa vuelve a ser la de abajo.
    if (previousRoute != null) {
      _onActive(previousRoute, action: 'pop', from: route);
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) {
      _onActive(newRoute, action: 'replace', from: oldRoute);
    }
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null && previousRoute.isCurrent) {
      _onActive(previousRoute, action: 'remove', from: route);
    }
  }

  void _onActive(
    Route<dynamic> route, {
    required String action,
    Route<dynamic>? from,
  }) {
    final core = _core;
    if (core == null) return; // Thor apagado = no-op, jamás error.

    // Primer contacto con un Navigator vivo: montar la burbuja del
    // inspector (integración cero — la app no agrega ningún widget).
    final navigator = route.navigator;
    if (overlayEnabled && navigator != null) {
      ThorOverlayManager.ensureAttached(navigator);
    }

    // La UI de Thor (inspector, reporte de crash) no es una pantalla de la
    // app: ni navegación, ni pantalla activa, ni `screen_load`. Tampoco el
    // regreso desde ella (`from` es la ruta de Thor que se cerró).
    if (ThorUi.isThorRoute(route) || ThorUi.isThorRoute(from)) return;

    // La pantalla en la que estaba el usuario: es el `from` de verdad (el de
    // la ruta de abajo, sin builder, salía como `MaterialPageRoute<void>`).
    final previous = core.recorder.currentScreen;
    // Lo que se ve debajo de la ruta que se tapa (push), para devolverlo
    // tal cual al regresar.
    if (action == 'push' && from != null && !ThorUi.isThorRoute(from)) {
      _screenUnder[from] = core.recorder.currentScreen;
    }
    // Pop/remove: la pantalla que queda visible es la de la ruta de abajo
    // tal como estaba (incluido lo que el árbol afinó), no su builder.
    final restored = action == 'pop' || action == 'remove'
        ? _screenUnder[route]
        : null;
    final screen =
        restored ?? resolveScreen(route, tryBuilder: resolveWidgetClass);
    core.recorder.currentScreen = screen;
    final payload = <String, Object?>{
      'action': action,
      'to': screen.display,
      if (from != null)
        'from': previous?.display ??
            resolveScreen(from, tryBuilder: false).display,
      if (route.settings.arguments != null)
        // Solo la FORMA de los argumentos, nunca valores (PII).
        'argsType': route.settings.arguments.runtimeType.toString(),
    };

    // La primera pantalla de la sesión se retiene [firstScreenSettle]: si
    // otra la reemplaza antes, nunca fue "visible" y no se anota.
    final held = _held;
    if (held != null) {
      held.timer.cancel();
      _held = null;
      final settled = clock.now().difference(held.at) > firstScreenSettle;
      if (settled) {
        _record(core, held);
      } else {
        // Transitoria: el destino no hereda su `from` (no está en la línea
        // de tiempo) y deja constancia de lo que se saltó.
        payload
          ..remove('from')
          ..['skipped'] = held.payload['to'];
      }
    } else if (holdFirstScreen &&
        !_firstNavSeen &&
        previous == null &&
        action == 'push') {
      _firstNavSeen = true;
      _held = _HeldNav(
        payload: payload,
        screen: screen,
        at: clock.now(),
        timer: Timer(firstScreenSettle, _flushHeld),
      );
      return;
    }
    _firstNavSeen = true;

    // Empujar encima la MISMA pantalla que ya está (doble `push HomeScreen`
    // tras un logout silencioso o un doble toque): se marca.
    if (action == 'push' &&
        previous != null &&
        previous.widgetClass != null &&
        previous.widgetClass == screen.widgetClass) {
      payload['duplicate'] = true;
    }
    core.recorder.record(ThorEventKind.navigation, payload);
  }

  void _record(ThorCore core, _HeldNav held) {
    core.recorder.record(
      ThorEventKind.navigation,
      held.payload,
      screenOverride: held.screen,
    );
  }

  /// Cascada de resolución de identidad. Estática y pública para que el
  /// capturador de interacciones pueda retro-corregir con la misma lógica.
  static ScreenId resolveScreen(
    Route<dynamic> route, {
    required bool tryBuilder,
  }) {
    final name = route.settings.name;
    String? widgetClass;

    if (tryBuilder && route is PageRoute<dynamic>) {
      widgetClass = _classFromBuilder(route);
    }

    return ScreenId(
      routeName: name,
      widgetClass: widgetClass,
      routeType: route.runtimeType.toString(),
    );
  }

  static String? _classFromBuilder(PageRoute<dynamic> route) {
    // Solo tipos con builder público y síncrono. El widget se CONSTRUYE
    // (sin montarse) únicamente para leerle el runtimeType.
    final builder = switch (route) {
      MaterialPageRoute<dynamic>(:final builder) => builder,
      CupertinoPageRoute<dynamic>(:final builder) => builder,
      _ => null,
    };
    final context = route.navigator?.context;
    if (builder == null || context == null) return null;
    try {
      final type = builder(context).runtimeType.toString();
      // Un builder que devuelve envoltorios genéricos no identifica nada.
      return _genericWrappers.contains(type) ? null : type;
    } on Object {
      // Constructor con efectos/asserts de contexto: se ignora y la
      // retro-corrección por árbol lo resolverá.
      return null;
    }
  }

  static const _genericWrappers = {
    'Builder', 'Container', 'SizedBox', 'Scaffold', 'Material',
  };
}
