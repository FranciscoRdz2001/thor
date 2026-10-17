import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/replay/wireframe.dart'
    show ThorReplayIgnore, ThorReplayShowText;
import 'package:thor_flutter/src/visible_tree.dart';

/// Captura de interacciones sin instrumentar la app.
///
/// Se cuelga del `PointerRouter` global (no requiere envolver widgets) y en
/// cada `PointerUp` recorre el árbol de elementos para identificar QUÉ se
/// tocó: label de Semantics, texto del botón, Key o tipo de widget. Produce
/// eventos como `tocó "Cobrar" (ElevatedButton)`.
///
/// PII: de los campos de texto NUNCA se captura el contenido — solo el hecho
/// de que se tocó el campo y su etiqueta/hint.
///
/// El label va completo al journal/reporte local (es lo que hace legible un
/// reporte de QA). Para el replay, que SÍ sale del dispositivo, el evento
/// lleva además de dónde salió el label: `copy: true` si es copy de la
/// interfaz (botón de alto nivel, tooltip, hint, ícono, o dentro de un
/// [ThorReplayShowText]) y `hidden: true` si el tap cayó en un
/// [ThorReplayIgnore]. Con el texto visible (default) el replay manda el
/// label legible (sin secretos); con `maskText`/estricto enmascara lo que
/// no sea copy.
///
/// De pasada hace la retro-corrección de pantalla: si el ancestro tipo
/// página del tap difiere de lo que resolvió el NavigatorObserver, gana el
/// árbol real montado.
class InteractionCapture {
  InteractionCapture._();

  static bool _installed = false;
  static PointerRoute? _route;

  /// Interactivos de ALTO NIVEL: lo que el desarrollador escribió.
  /// Tienen prioridad sobre los primitivos aunque queden más arriba en el
  /// árbol — un `ElevatedButton` contiene un `GestureDetector` interno del
  /// framework y reportar ese sería ruido.
  static const _highLevelTypes = {
    'ElevatedButton', 'TextButton', 'OutlinedButton', 'FilledButton',
    'IconButton', 'FloatingActionButton', 'ListTile', 'CheckboxListTile',
    'SwitchListTile', 'RadioListTile', 'PopupMenuButton', 'DropdownButton',
    'TextField', 'TextFormField', 'Checkbox', 'Switch', 'Radio', 'Slider',
    'Chip', 'ActionChip', 'ChoiceChip', 'FilterChip', 'BackButton',
    'CloseButton', 'SegmentedButton', 'CupertinoButton',
  };

  /// Botones cuyo texto es COPY de la interfaz ("Pagar", "Guardar"): el
  /// desarrollador lo escribió para la acción, casi nunca es un dato.
  /// Fuera a propósito: ListTile y sus variantes (su título suele ser el
  /// dato de la fila: un nombre, una dirección, un pedido), chips (tags,
  /// contactos), DropdownButton (muestra el VALOR elegido) y
  /// PopupMenuButton (idem). Esos se enmascaran en el replay con
  /// `maskText`/estricto.
  static const _copyTypes = {
    'ElevatedButton', 'TextButton', 'OutlinedButton', 'FilledButton',
    'IconButton', 'FloatingActionButton', 'BackButton', 'CloseButton',
    'SegmentedButton', 'CupertinoButton',
  };

  /// Interactivos primitivos: solo se reportan si ningún alto nivel
  /// contiene el punto (un `GestureDetector` escrito a mano sí cuenta).
  static const _primitiveTypes = {
    'GestureDetector', 'InkWell', 'InkResponse', 'Card',
  };

  /// Instala el listener global de punteros. Idempotente.
  static void install() {
    if (_installed) return;
    _installed = true;
    _route = _onPointer;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_route!);
  }

  /// Desinstala (tests).
  static void uninstall() {
    if (!_installed) return;
    _installed = false;
    if (_route != null) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_route!);
    }
  }

  static void _onPointer(PointerEvent event) {
    if (event is! PointerUpEvent) return;
    final core = ThorCore.instance;
    if (core == null) return;

    try {
      final hit = _describeHit(event.position);
      if (hit == null) return;

      // Retro-corrección: el árbol real manda sobre lo inferido en el push.
      final page = hit.pageClass;
      final current = core.recorder.currentScreen;
      if (page != null && current?.widgetClass != page) {
        core.recorder.currentScreen = ScreenId(
          routeName: current?.routeName,
          widgetClass: page,
          routeType: current?.routeType,
        );
      }

      core.recorder.record(ThorEventKind.interaction, {
        'gesture': 'tap',
        'widget': hit.widgetType,
        if (hit.label != null) 'label': hit.label,
        if (hit.keyValue != null) 'key': hit.keyValue,
        'isTextInput': hit.isTextInput,
        if (hit.labelIsCopy) 'copy': true,
        if (hit.hidden) 'hidden': true,
      });
    } on Object {
      // La captura de interacciones jamás puede tirar la app que observa.
    }
  }

  /// Recorre el árbol buscando el elemento interactivo más profundo cuyo
  /// RenderBox contiene [position]. Visible para tests.
  @visibleForTesting
  static HitDescription? describeHitForTest(Offset position) =>
      _describeHit(position);

  static _Hit? _describeHit(Offset position) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return null;

    Element? bestHighLevel;
    Element? bestPrimitive;
    // Marcas de privacidad del ancestro de cada candidato (ver [_Mark]).
    var highLevelMark = _Mark.none;
    var primitiveMark = _Mark.none;
    String? pageClass;

    void visit(Element element, _Mark inherited) {
      final widget = element.widget;
      final mark = switch (widget) {
        ThorReplayIgnore() => _Mark.hidden,
        ThorReplayShowText() when inherited != _Mark.hidden => _Mark.show,
        _ => inherited,
      };
      final render = element.renderObject;
      if (render is RenderBox && render.hasSize && render.attached) {
        final Offset local;
        try {
          local = render.globalToLocal(position);
        } on Object {
          return; // transform no invertible: rama fuera de pantalla.
        }
        if (!render.paintBounds.contains(local)) {
          return; // la rama entera no contiene el punto: poda.
        }
        final typeName = _stripGenerics(element.widget.runtimeType.toString());
        if (_highLevelTypes.contains(typeName)) {
          bestHighLevel = element; // el más profundo de su nivel gana
          highLevelMark = mark;
        } else if (_primitiveTypes.contains(typeName)) {
          bestPrimitive = element;
          primitiveMark = mark;
        }
        if (VisibleTree.isScreenName(typeName)) pageClass = typeName;
      }
      // Solo lo pintado: un toque nunca cae en una tab oculta.
      VisibleTree.visitChildren(element, (child) => visit(child, mark));
    }

    rootElement.visitChildElements((child) => visit(child, _Mark.none));

    // Alto nivel manda: el GestureDetector interno de un botón es ruido.
    final target = bestHighLevel ?? bestPrimitive;
    if (target == null) return null;
    final mark = bestHighLevel != null ? highLevelMark : primitiveMark;

    final type = _stripGenerics(target.widget.runtimeType.toString());
    final label = _labelOf(target, copyText: _copyTypes.contains(type));
    return _Hit(
      widgetType: type,
      label: label?.text,
      keyValue: _keyOf(target.widget.key),
      isTextInput: type == 'TextField' || type == 'TextFormField',
      pageClass: pageClass,
      labelIsCopy: mark == _Mark.show || (label?.copy ?? false),
      hidden: mark == _Mark.hidden,
    );
  }

  static String _stripGenerics(String type) {
    final i = type.indexOf('<');
    return i == -1 ? type : type.substring(0, i);
  }

  static String? _keyOf(Key? key) => switch (key) {
        ValueKey<Object?>(:final value) => value.toString(),
        null => null,
        _ => key.toString(),
      };

  /// Etiqueta legible del elemento: hint de un campo, texto del primer
  /// `Text` descendiente, o tooltip. Truncada — es una etiqueta, no datos.
  ///
  /// `copy` dice si es copy de la interfaz: hint/label de decoración,
  /// tooltip e ícono lo son siempre (los escribe la app); el texto de un
  /// `Text` solo si [copyText] (botón de alto nivel) o si está dentro de
  /// un [ThorReplayShowText] bajo el elemento tocado.
  static ({String text, bool copy})? _labelOf(
    Element element, {
    required bool copyText,
  }) {
    final widget = element.widget;

    // Campo de texto: SOLO metadata de decoración, jamás el contenido.
    if (widget is TextField) {
      final d = widget.decoration;
      final text = d?.labelText ?? d?.hintText;
      return text == null ? null : (text: text, copy: true);
    }

    String? text;
    var copy = false;
    void findText(Element e, {required bool inShow}) {
      if (text != null) return;
      final w = e.widget;
      final show = inShow || w is ThorReplayShowText;
      if (w is Text && w.data != null && w.data!.trim().isNotEmpty) {
        text = w.data!.trim();
        copy = copyText || show;
        return;
      }
      if (w is Tooltip) {
        text = w.message;
        copy = true;
        return;
      }
      if (w is Icon && w.icon != null) {
        text = 'icono:${w.icon}';
        copy = true;
      }
      e.visitChildElements((child) => findText(child, inShow: show));
    }

    element.visitChildElements((child) => findText(child, inShow: false));
    final found = text;
    if (found == null) return null;
    return (
      text: found.length > 60 ? '${found.substring(0, 60)}…' : found,
      copy: copy,
    );
  }
}

/// Descripción de un tap resuelta desde el árbol (visible para tests).
typedef HitDescription = _Hit;

class _Hit {
  const _Hit({
    required this.widgetType,
    required this.isTextInput,
    this.label,
    this.keyValue,
    this.pageClass,
    this.labelIsCopy = false,
    this.hidden = false,
  });

  final String widgetType;
  final String? label;
  final String? keyValue;
  final bool isTextInput;
  final String? pageClass;

  /// El label es copy de la interfaz: el replay lo puede mandar legible.
  final bool labelIsCopy;

  /// El tap cayó dentro de un [ThorReplayIgnore].
  final bool hidden;
}

/// Marca de privacidad heredada de los ancestros durante el recorrido.
/// `hidden` (ThorReplayIgnore) gana sobre `show` (ThorReplayShowText).
enum _Mark { none, show, hidden }
