import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/material.dart' show MaterialPageRoute;
import 'package:flutter/widgets.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/overlay/thor_overlay.dart';

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

    final screen = resolveScreen(route, tryBuilder: resolveWidgetClass);
    core.recorder.currentScreen = screen;
    core.recorder.record(ThorEventKind.navigation, {
      'action': action,
      'to': screen.display,
      if (from != null)
        'from': resolveScreen(from, tryBuilder: false).display,
      if (route.settings.arguments != null)
        // Solo la FORMA de los argumentos, nunca valores (PII).
        'argsType': route.settings.arguments.runtimeType.toString(),
    });
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
