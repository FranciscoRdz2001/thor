import 'dart:collection';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Recorrido del árbol "como lo ve el usuario": lo montado pero no pintado
/// no cuenta.
///
/// Un `IndexedStack` (la forma más común de hacer tabs) mantiene montados
/// TODOS sus hijos y solo pinta uno; un `Offstage` monta sin pintar; el
/// Overlay del Navigator mantiene las rutas tapadas sin pintarlas.
/// Recorrer el árbol crudo atribuía pantallas a tabs ocultas y dibujaba en
/// el replay la última tab del stack encima de la visible.
abstract final class VisibleTree {
  /// Si [ro] está montado pero no se ve (ni él ni sus hijos).
  static bool isHidden(RenderObject ro) =>
      (ro is RenderOffstage && ro.offstage) ||
      (ro is RenderOpacity && ro.opacity == 0) ||
      (ro is RenderAnimatedOpacity && ro.opacity.value == 0);

  /// Visita solo los hijos de [element] que se pintan.
  static void visitChildren(Element element, void Function(Element) visit) {
    if (element is RenderObjectElement) {
      final ro = element.renderObject;
      if (ro is RenderIndexedStack) {
        final index = ro.index;
        if (index == null) return;
        var i = 0;
        element.visitChildElements((child) {
          if (i++ == index) visit(child);
        });
        return;
      }
      // El Overlay del Navigator mantiene montadas las rutas tapadas por
      // una opaca (las primeras `skipCount`) pero no las pinta.
      if (runtimeName(ro) == '_RenderTheater') {
        final int skip;
        try {
          skip = (ro as dynamic).skipCount as int;
        } on Object {
          element.visitChildElements(visit);
          return;
        }
        var i = 0;
        element.visitChildElements((child) {
          if (i++ >= skip) visit(child);
        });
        return;
      }
    }
    element.visitChildElements(visit);
  }

  /// Sufijos que identifican a un widget como "pantalla". `Body` cubre el
  /// patrón común de tabs (`HomeBody`, `FavoriteBody` dentro de un
  /// `IndexedStack`).
  static const screenSuffixes = ['Page', 'Screen', 'View', 'Body'];

  /// Widgets del framework que MATCHEAN los sufijos pero jamás son la
  /// pantalla de la app (bug real: SingleChildScrollView se reportaba como
  /// pantalla en el POS). Si aparece un falso positivo nuevo, va aquí.
  static const screenDenylist = {
    'SingleChildScrollView',
    'ListView',
    'GridView',
    'CustomScrollView',
    'NestedScrollView',
    'PageView',
    'TabBarView',
    'ScrollView',
    'BoxScrollView',
    'ReorderableListView',
    'InteractiveViewer',
    'DraggableScrollableSheet',
    'ThorInspectorPage',
    'ThorCrashReportPage',
  };

  static final Map<Type, String> _names = HashMap();

  /// `runtimeType.toString()` memorizado por tipo. Para clases privadas
  /// del framework (`_RenderTheater`) no hay otra forma de reconocerlas, y
  /// el recorrido lo pregunta en miles de nodos por snapshot: construir el
  /// String cada vez se notaba en el perfil.
  static String runtimeName(Object o) {
    final t = o.runtimeType;
    return _names[t] ??= t.toString();
  }

  /// Nombre de clase sin genéricos (`Foo<int>` → `Foo`).
  static String typeName(Widget widget) {
    final type = runtimeName(widget);
    final i = type.indexOf('<');
    return i == -1 ? type : type.substring(0, i);
  }

  /// Si [name] es una clase de pantalla de la app. Las privadas no: son
  /// piezas internas (de la app) o del framework (`_MediaQueryFromView`).
  static bool isScreenName(String name) =>
      !name.startsWith('_') &&
      screenSuffixes.any(name.endsWith) &&
      !screenDenylist.contains(name);
}
