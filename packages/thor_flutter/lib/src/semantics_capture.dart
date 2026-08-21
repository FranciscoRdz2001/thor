import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:thor/thor.dart';

/// Interacciones que llegan por el canal de **accesibilidad**, no por
/// punteros.
///
/// `InteractionCapture` engancha el `PointerRouter`, que ve dedos y ratón.
/// No ve nada de esto:
/// - Un usuario con VoiceOver/TalkBack activando un botón: el sistema
///   despacha una acción semántica y jamás sintetiza un toque. Su sesión
///   entera salía en el reporte sin una sola interacción — Thor
///   concluiría "el usuario no tocó nada" cuando en realidad recorrió
///   toda la pantalla.
///
/// Es observador puro: usa `addSemanticsActionListener`, que corre ANTES
/// de que la acción se ejecute y no puede impedirla. Nada de secuestrar
/// `onSemanticsActionEvent` — eso sí podría romper la accesibilidad.
///
/// **Límite conocido.** Solo se ve lo que entra por el engine
/// (`PlatformDispatcher.onSemanticsActionEvent` → binding → listeners),
/// que es el camino de un lector de pantalla real. Un arnés in-process
/// que llame `SemanticsOwner.performAction` directo se salta ese tramo y
/// queda invisible: es el caso de `mcp_toolkit`, verificado en su fuente.
/// No hay hook público en `SemanticsOwner` para cubrirlo. Consecuencia
/// práctica: un reporte generado desde ese arnés no trae pasos de
/// interacción aunque la app sí se haya manejado.
class SemanticsInteractionCapture {
  const SemanticsInteractionCapture._();

  /// Acciones que son una interacción real del usuario. El resto
  /// (`didGainAccessibilityFocus`, `setSelection`, `showOnScreen`…) es
  /// ruido de navegación del lector de pantalla: se mueve el foco sin que
  /// el usuario decida nada, y llenaría la línea de tiempo.
  static const _meaningful = {
    SemanticsAction.tap,
    SemanticsAction.longPress,
    SemanticsAction.scrollUp,
    SemanticsAction.scrollDown,
    SemanticsAction.scrollLeft,
    SemanticsAction.scrollRight,
    SemanticsAction.increase,
    SemanticsAction.decrease,
    SemanticsAction.dismiss,
    SemanticsAction.copy,
    SemanticsAction.paste,
  };

  static bool _installed = false;

  /// Instala el observador. Idempotente y no-op sin Thor activo.
  static void install() {
    if (_installed || ThorCore.instance == null) return;
    _installed = true;
    SemanticsBinding.instance.addSemanticsActionListener(_onAction);
  }

  /// Desinstala (tests).
  static void uninstall() {
    if (!_installed) return;
    _installed = false;
    SemanticsBinding.instance.removeSemanticsActionListener(_onAction);
  }

  static void _onAction(ui.SemanticsActionEvent event) {
    if (!_meaningful.contains(event.type)) return;
    final core = ThorCore.instance;
    if (core == null) return;

    final node = _findNode(event.viewId, event.nodeId);
    core.recorder.record(ThorEventKind.interaction, {
      'gesture': _gestureName(event.type),
      // Marca la vía: un reporte con solo interacciones semánticas
      // probablemente viene de un lector de pantalla o de un arnés
      // automatizado, y eso cambia cómo se lee.
      'via': 'semantics',
      if (node != null) ...{
        'label': node.label.isEmpty ? null : node.label,
        'widget': _roleOf(node),
      },
    });
  }

  /// Busca el nodo por id recorriendo desde la raíz de su vista.
  ///
  /// `SemanticsOwner` no expone búsqueda por id (su mapa es privado), así
  /// que se recorre. Es aceptable porque solo ocurre en una acción real
  /// del usuario, no por frame.
  static SemanticsNode? _findNode(int viewId, int nodeId) {
    for (final view in RendererBinding.instance.renderViews) {
      if (view.flutterView.viewId != viewId) continue;
      final root = view.owner?.semanticsOwner?.rootSemanticsNode;
      if (root == null) return null;
      return _search(root, nodeId);
    }
    return null;
  }

  static SemanticsNode? _search(SemanticsNode node, int id) {
    if (node.id == id) return node;
    SemanticsNode? found;
    node.visitChildren((child) {
      if (found != null) return false;
      found = _search(child, id);
      return found == null;
    });
    return found;
  }

  /// Nombre del rol para que el reporte diga algo grepeable. La clase de
  /// widget no está disponible desde el nodo semántico: lo más cercano es
  /// su rol declarado.
  static String _roleOf(SemanticsNode node) {
    final flags = node.getSemanticsData().flagsCollection;
    if (flags.isButton) return 'Button';
    if (flags.isTextField) return 'TextField';
    if (flags.isSlider) return 'Slider';
    if (flags.isLink) return 'Link';
    return 'Semantics';
  }

  static String _gestureName(SemanticsAction action) => switch (action) {
        SemanticsAction.tap => 'tap',
        SemanticsAction.longPress => 'longPress',
        SemanticsAction.scrollUp => 'scrollUp',
        SemanticsAction.scrollDown => 'scrollDown',
        SemanticsAction.scrollLeft => 'scrollLeft',
        SemanticsAction.scrollRight => 'scrollRight',
        SemanticsAction.increase => 'increase',
        SemanticsAction.decrease => 'decrease',
        SemanticsAction.dismiss => 'dismiss',
        SemanticsAction.copy => 'copy',
        SemanticsAction.paste => 'paste',
        _ => action.name,
      };
}
