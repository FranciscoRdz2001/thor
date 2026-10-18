import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/performance_capture.dart';
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
/// Un carrusel de banners no cuenta: no cubre la pantalla. Una tab oculta
/// tampoco: [VisibleTree] solo entra al hijo visible de un `IndexedStack`.
class ScreenCapture {
  ScreenCapture._();

  static bool _installed = false;
  static Timer? _timer;
  static String? _lastReported;

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
    _timer?.cancel();
  }

  static void _onFrame(Duration _) {
    if (!_installed) return;
    // Una lectura de reloj: de ahí sale screen_load (ver PerformanceCapture).
    PerformanceCapture.onFrame();
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
    final current = core.recorder.currentScreen;
    // Otro capturador (el toque) pudo fijar ya la misma pantalla: no se
    // graba dos veces la misma llegada.
    if (current?.widgetClass == screen || _lastReported == screen) {
      _lastReported = screen;
      return;
    }
    _lastReported = screen;
    core.recorder.currentScreen = ScreenId(
      routeName: current?.routeName,
      widgetClass: screen,
      routeType: current?.routeType,
    );
    core.recorder.record(ThorEventKind.navigation, {
      'action': 'screen',
      'to': screen,
      if (current != null) 'from': current.display,
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

    void visit(Element element) {
      final ro = element.renderObject;
      if (ro != null && VisibleTree.isHidden(ro)) return;
      final name = VisibleTree.typeName(element.widget);
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
      VisibleTree.visitChildren(element, visit);
    }

    root.visitChildElements(visit);
    return found;
  }
}
