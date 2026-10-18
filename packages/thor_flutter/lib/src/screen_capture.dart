import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoNavigationBar;
import 'package:flutter/material.dart' show AppBar, SliverAppBar;
import 'package:flutter/rendering.dart' show RenderBox, RenderIndexedStack;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/performance_capture.dart';
import 'package:thor_flutter/src/ui_health_capture.dart';
import 'package:thor_flutter/src/visible_tree.dart';

/// Pantallas que el Navigator no ve: tabs (`IndexedStack`, `TabBarView`),
/// páginas de un `PageView`, wizards internos.
///
/// Tras cada cambio de UI (cuando la app se queda quieta [idle]) busca la
/// pantalla visible MÁS PROFUNDA: un widget `*Page/*Screen/*View/*Body` que
/// se pinta y ocupa al menos [minCoverage] de la pantalla. Si cambió,
/// queda como pantalla actual y se graba la navegación — sin una línea de
/// código en la app.
///
/// El cambio se anota AL INICIO, no cuando termina de cargar: un toque en
/// una tab dispara [onTap], que mira el árbol una vez [tapDelay] después
/// (lo que tarda el frame de la tab nueva) en vez de esperar la quietud. Así
/// las peticiones y errores que siguen al toque ya llevan la pantalla nueva;
/// el "terminó de cargar" es el `screen_load` de `PerformanceCapture`.
///
/// De pasada lee el título del AppBar visible (en el mismo recorrido) como
/// `detail` de la pantalla: una clase para muchos contextos (un PLP) se
/// distingue por su título. `Thor.setScreenContext` gana sobre él.
///
/// Un carrusel de banners no cuenta: no cubre la pantalla. Una tab oculta
/// tampoco: [VisibleTree] solo entra al hijo visible de un `IndexedStack`.
class ScreenCapture {
  ScreenCapture._();

  static bool _installed = false;
  static Timer? _timer;
  static Timer? _tapTimer;
  static String? _lastReported;

  /// Última pantalla fijada por el árbol (tab, página). El toque no debe
  /// retro-corregirla a la clase de la ruta que contiene la barra de tabs:
  /// el árbol ya sabe algo más profundo y preciso.
  static String? get lastReported => _lastReported;

  /// Título puesto por esta clase (para no pisar uno que puso la app).
  static String? _autoDetail;

  /// Título del AppBar visible hallado por el último [detect].
  static String? _title;

  /// Cambios de título ya anotados en la pantalla vigente, y el tope: un
  /// título que cambia solo (contador del carrito, cuenta regresiva) no
  /// debe llenar la línea de tiempo de `screen_context`.
  static int _titleSyncs = 0;
  static const int _maxTitleSyncs = 5;

  /// Tras un toque, cuánto esperar antes de mirar el árbol (el frame de
  /// la pantalla nueva).
  @visibleForTesting
  static Duration tapDelay = const Duration(milliseconds: 50);

  /// Quietud tras el último frame antes de mirar el árbol.
  static Duration idle = const Duration(milliseconds: 300);

  /// Fracción mínima de la pantalla que debe cubrir un widget para ser
  /// "la pantalla".
  static double minCoverage = 0.4;

  /// Instala el detector. Idempotente.
  static void install() {
    if (_installed) return;
    _installed = true;
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
  }

  /// Desinstala (tests). El callback persistente queda inerte.
  static void uninstall() {
    _installed = false;
    _lastReported = null;
    _autoDetail = null;
    _titleSyncs = 0;
    _timer?.cancel();
    _tapTimer?.cancel();
    _tapTimer = null;
  }

  /// El usuario enfocó un campo de texto: un contexto de pantalla que
  /// PUSO LA APP (`Thor.setScreenContext('Búsqueda > 7501055300')`) ya no
  /// se puede dar por vigente — la consulta va a cambiar y la app aún no lo
  /// dijo. Se quita (queda `screen_context` nulo) hasta que la app lo
  /// vuelva a fijar; el título del AppBar, que sí se recalcula solo, no se
  /// toca. Así las peticiones de una búsqueda nueva no salen con la
  /// consulta anterior.
  static void onTextFocus() {
    final core = ThorCore.instance;
    final current = core?.recorder.currentScreen;
    if (core == null || current == null || current.detail == null) return;
    if (current.detail == _autoDetail) return;
    core.recorder.currentScreen = current.withDetail(null);
    core.recorder.record(ThorEventKind.environment, {
      'signal': 'screen_context',
      'value': null,
      'reason': 'text_focus',
    });
  }

  /// Un toque terminó (lo llama `InteractionCapture`): mira el árbol una
  /// vez, poco después, para anotar el cambio de pantalla que ese toque
  /// provoca (tab, página) sin esperar a que la pantalla nueva termine de
  /// cargar. Un solo chequeo pendiente a la vez.
  static void onTap() {
    if (!_installed) return;
    PerformanceCapture.onTap();
    if (_tapTimer != null) return;
    _tapTimer = Timer(tapDelay, () {
      _tapTimer = null;
      final scheduler = SchedulerBinding.instance;
      // Con un frame en camino, tras él: ahí está la pantalla nueva.
      if (scheduler.hasScheduledFrame) {
        scheduler.addPostFrameCallback((_) => check());
      } else {
        check();
      }
    });
  }

  static void _onFrame(Duration _) {
    if (!_installed) return;
    // Una lectura de reloj: de ahí sale screen_load (ver PerformanceCapture).
    PerformanceCapture.onFrame();
    UiHealthCapture.onFrame();
    _timer?.cancel();
    _timer = Timer(idle, _onIdle);
  }

  static void _onIdle() {
    check();
    PerformanceCapture.onIdle();
  }

  /// Mira el árbol ahora y actualiza la pantalla si cambió.
  @visibleForTesting
  static void check() {
    final core = ThorCore.instance;
    if (core == null) return;
    final String? screen;
    try {
      screen = detect();
    } on Object {
      return; // Un árbol a medio construir no debe tumbar nada.
    }
    if (screen == null) return;
    final title = _title;
    final current = core.recorder.currentScreen;
    // Otro capturador (el toque) pudo fijar ya la misma pantalla: no se
    // graba dos veces la misma llegada.
    if (current?.widgetClass == screen || _lastReported == screen) {
      _lastReported = screen;
      _syncTitle(core, title);
      return;
    }
    _lastReported = screen;
    _autoDetail = title;
    _titleSyncs = 0;
    core.recorder.currentScreen = ScreenId(
      routeName: current?.routeName,
      widgetClass: screen,
      routeType: current?.routeType,
      detail: title,
    );
    core.recorder.record(ThorEventKind.navigation, {
      'action': 'screen',
      'to': screen,
      if (current != null) 'from': current.display,
    });
  }

  /// La misma pantalla con otro título de AppBar (un PLP reutilizado para
  /// otro departamento): el contexto se actualiza, salvo que la app haya
  /// puesto el suyo con `Thor.setScreenContext`.
  static void _syncTitle(ThorCore core, String? title) {
    final current = core.recorder.currentScreen;
    if (current == null) return;
    if (title == null) {
      // El AppBar que daba el contexto ya no está: no se hereda su título
      // (el escáner salía con `sd` de la pantalla anterior).
      if (current.detail != null && current.detail == _autoDetail) {
        _autoDetail = null;
        core.recorder.currentScreen = current.withDetail(null);
        core.recorder.record(ThorEventKind.environment, {
          'signal': 'screen_context',
          'value': null,
        });
      }
      return;
    }
    if (current.detail == title) return;
    if (current.detail != null && current.detail != _autoDetail) return;
    if (_titleSyncs >= _maxTitleSyncs) return;
    _titleSyncs++;
    _autoDetail = title;
    core.recorder.currentScreen = current.withDetail(title);
    core.recorder.record(ThorEventKind.environment, {
      'signal': 'screen_context',
      'value': title,
    });
  }

  /// La pantalla visible más profunda, o `null` si no hay árbol.
  @visibleForTesting
  static String? detect() {
    final root = WidgetsBinding.instance.rootElement;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (root == null || views.isEmpty) return null;
    final view = views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    final screenRect = Offset.zero & size;
    final minArea = size.width * size.height * minCoverage;
    String? found;
    String? title;
    var titleDepth = -1;
    _title = null;

    void visit(Element element) {
      final ro = element.renderObject;
      if (ro != null && VisibleTree.isHidden(ro)) return;
      final widget = element.widget;
      // El AppBar más profundo gana: el de la tab/pantalla interna sobre el
      // del contenedor.
      if (element.depth >= titleDepth &&
          (widget is AppBar ||
              widget is SliverAppBar ||
              widget is CupertinoNavigationBar)) {
        final text = _titleText(
          switch (widget) {
            AppBar(:final title) => title,
            SliverAppBar(:final title) => title,
            CupertinoNavigationBar(:final middle) => middle,
            _ => null,
          },
        );
        if (text != null) {
          title = text;
          titleDepth = element.depth;
        }
      }
      final name = VisibleTree.typeName(widget);
      if (VisibleTree.isScreenName(name) && ro is RenderBox && ro.hasSize) {
        final rect = MatrixUtils.transformRect(
          ro.getTransformTo(null),
          Offset.zero & ro.size,
        ).intersect(screenRect);
        // Visible y grande: una página de PageView fuera de vista o un
        // carrusel de banners no son "la pantalla".
        if (!rect.isEmpty && rect.width * rect.height >= minArea) {
          found = name;
        }
      }
      // La tab visible de un IndexedStack es "la pantalla" aunque, cargando,
      // pinte poco (un skeleton): sin esto las peticiones que dispara la tab
      // salen con la pantalla contenedora hasta que la tab llena la pantalla.
      if (element is RenderObjectElement && ro is RenderIndexedStack) {
        VisibleTree.visitChildren(element, (child) {
          // Flutter envuelve cada hijo (`_VisibilityScope`, `ExcludeFocus`…):
          // se baja por esos envoltorios de un solo hijo hasta la tab.
          var tab = child;
          for (var i = 0;
              i < 12 &&
                  !VisibleTree.isScreenName(VisibleTree.typeName(tab.widget));
              i++) {
            Element? next;
            var count = 0;
            tab.visitChildElements((c) {
              count++;
              next ??= c;
            });
            if (count != 1) break;
            tab = next!;
          }
          final tabName = VisibleTree.typeName(tab.widget);
          final tabRo = tab.renderObject;
          if (VisibleTree.isScreenName(tabName) &&
              tabRo is RenderBox &&
              tabRo.hasSize &&
              !tabRo.size.isEmpty) {
            found = tabName;
          }
        });
      }
      VisibleTree.visitChildren(element, visit);
    }

    root.visitChildElements(visit);
    _title = title;
    return found;
  }

  /// El texto de un título de AppBar: un `Text` directo o dentro de pocos
  /// envoltorios (`Padding`, `Center`, `Row`…). Limpio y corto.
  static String? _titleText(Widget? widget, [int depth = 0]) {
    if (widget == null || depth > 4) return null;
    String? raw;
    if (widget is Text) {
      raw = widget.data ?? widget.textSpan?.toPlainText();
    } else if (widget is SingleChildRenderObjectWidget) {
      return _titleText(widget.child, depth + 1);
    } else if (widget is ProxyWidget) {
      return _titleText(widget.child, depth + 1);
    } else if (widget is MultiChildRenderObjectWidget) {
      for (final child in widget.children) {
        final text = _titleText(child, depth + 1);
        if (text != null) return text;
      }
      return null;
    }
    if (raw == null) return null;
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return null;
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
  }
}
