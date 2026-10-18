import 'package:clock/clock.dart';
import 'package:flutter/cupertino.dart' show CupertinoButton;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/dead_tap_capture.dart';
import 'package:thor_flutter/src/icon_names.dart';
import 'package:thor_flutter/src/overlay/thor_ui.dart' show ThorOwnUi;
import 'package:thor_flutter/src/replay/wireframe.dart'
    show ThorReplayIgnore, ThorReplayShowText;
import 'package:thor_flutter/src/screen_capture.dart';
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
/// Qué se registra (`gesture`, ver [ThorGesture]): `tap`, `long_press`
/// (≥ 500 ms quieto), `scroll` (arrastre que empieza sobre algo
/// desplazable: `axis`, `dir`, `distance`, `start`, `end`, `durationMs`),
/// `swipe` (arrastre fuera de lo desplazable), `edge_swipe` (el gesto de
/// "atrás" de iOS: arrastre horizontal desde el borde) y `text_focus` (un
/// campo de texto recibió el foco → teclado; SOLO su etiqueta, nunca lo
/// escrito). Todo sale de los mismos eventos de puntero ya escuchados: sin
/// trabajo por frame ni por `PointerMove`.
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

  /// Superficies de un diálogo / hoja modal: un toque dentro de una de
  /// ellas no es un toque a la barrera.
  static const _surfaceTypes = {
    'Material', 'PhysicalModel', 'PhysicalShape', 'CupertinoPopupSurface', //
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
    FocusManager.instance.addListener(_onFocusChanged);
  }

  /// Desinstala (tests).
  static void uninstall() {
    if (!_installed) return;
    _installed = false;
    if (_route != null) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_route!);
    }
    FocusManager.instance.removeListener(_onFocusChanged);
    _endTextWatch();
    _focused = null;
    _downPointer = null;
    _downAt = null;
    _lastScrollAt = null;
  }

  /// Un arrastre (no un toque) pasa de este recorrido: el `kTouchSlop`.
  static const double _dragSlop = 18;

  /// Zona del borde de pantalla donde empieza el gesto de "atrás".
  static const double _edgeZone = 24;

  /// Recorrido horizontal mínimo de un gesto de borde.
  static const double _edgeMinTravel = 60;

  /// Dos desplazamientos seguidos más juntos que esto cuentan como uno
  /// (una lista larga = muchos arrastres; no deben desalojar los toques
  /// de la cuota de interacciones).
  static const Duration _scrollCoalesce = Duration(milliseconds: 500);

  /// Dónde y cuándo cayó el dedo (un solo puntero a la vez).
  static Offset? _downAt;
  static DateTime? _downTime;
  static int? _downPointer;

  /// Hubo un segundo dedo durante el gesto (pinch): no es toque ni arrastre.
  static bool _multiTouch = false;
  static DateTime? _lastScrollAt;

  /// `seq` de la última navegación al bajar el dedo (ver `popped`).
  static int? _downNavSeq;

  static void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) {
      if (_downPointer != null && _downPointer != event.pointer) {
        _multiTouch = true; // segundo dedo: pinch/zoom.
        return;
      }
      _downPointer = event.pointer;
      _downAt = event.position;
      _downTime = clock.now();
      _multiTouch = false;
      _downNavSeq =
          ThorCore.instance?.store.lastOfKind(ThorEventKind.navigation)?.seq;
      return;
    }
    if (event is PointerCancelEvent) {
      if (event.pointer == _downPointer) _downPointer = null;
      return;
    }
    if (event is! PointerUpEvent) return;
    if (event.pointer != _downPointer) return;
    final down = _downAt;
    final downTime = _downTime;
    final multi = _multiTouch;
    _downPointer = null;
    _multiTouch = false;
    final core = ThorCore.instance;
    if (core == null) return;
    final travel = down == null ? 0.0 : (event.position - down).distance;
    final held =
        downTime == null ? Duration.zero : clock.now().difference(downTime);
    // Un toque puede cambiar de pantalla (tab): se anota al INICIO, no al
    // terminar de cargar. Un scroll no.
    if (down != null && travel < _dragSlop) ScreenCapture.onTap();
    if (multi) return;

    try {
      if (down != null && travel >= _dragSlop) {
        _recordDrag(core, event, down, held);
        return;
      }
      final probe = _probe(event.position);
      final hit = probe.hit;
      // Un toque en la UI de Thor (burbuja, aviso, inspector) no es del
      // usuario sobre la app: ni interacción ni retro-corrección.
      if (probe.thorUi) return;
      _retroCorrect(core, probe.pageClass);
      if (hit == null) return;
      final long = held >= kLongPressTimeout;
      final tapEvent = core.recorder.record(ThorEventKind.interaction, {
        'gesture': long ? ThorGesture.longPress : ThorGesture.tap,
        'widget': hit.widgetType,
        if (hit.label != null) 'label': hit.label,
        if (hit.keyValue != null) 'key': hit.keyValue,
        'isTextInput': hit.isTextInput,
        if (hit.labelIsCopy) 'copy': true,
        if (hit.hidden) 'hidden': true,
        if (long) 'durationMs': held.inMilliseconds,
      });
      // ¿Hizo algo ese botón? (toque sin efecto)
      if (tapEvent != null && !long && !hit.hidden) {
        DeadTapCapture.onTap(
          core,
          tapEvent,
          widgetType: hit.widgetType,
          label: hit.label,
          disabled: hit.disabled,
        );
      }
    } on Object {
      // La captura de interacciones jamás puede tirar la app que observa.
    }
  }

  /// Retro-corrección: el árbol real manda sobre lo inferido en el push.
  static void _retroCorrect(ThorCore core, String? page) {
    final current = core.recorder.currentScreen;
    // Si la pantalla vigente la fijó el árbol (una tab), el toque en la barra
    // de tabs no la baja a la ruta contenedora: las peticiones que siguen al
    // cambio de tab saldrían con la pantalla equivocada.
    final tree = ScreenCapture.lastReported;
    if (tree != null && current?.widgetClass == tree) return;
    if (page != null && current?.widgetClass != page) {
      core.recorder.currentScreen = ScreenId(
        routeName: current?.routeName,
        widgetClass: page,
        routeType: current?.routeType,
      );
    }
  }

  /// Un arrastre terminado: borde (atrás), scroll o swipe.
  static void _recordDrag(
    ThorCore core,
    PointerUpEvent up,
    Offset down,
    Duration held,
  ) {
    final delta = up.position - down;
    final horizontal = delta.dx.abs() >= delta.dy.abs();
    final dir = horizontal
        ? (delta.dx >= 0 ? 'right' : 'left')
        : (delta.dy >= 0 ? 'down' : 'up');

    final width = _viewWidth(up.viewId);
    final edge = width == null
        ? null
        : down.dx <= _edgeZone
            ? 'left'
            : down.dx >= width - _edgeZone
                ? 'right'
                : null;
    final isEdge = edge != null &&
        horizontal &&
        delta.dx.abs() >= _edgeMinTravel &&
        delta.dx.abs() > delta.dy.abs() * 2;

    // Vía rápida: un arrastre pegado al anterior (una lista larga = muchos
    // arrastres seguidos) ya es parte de la ráfaga de scroll ya anotada.
    // Evita recorrer el árbol entero en cada soltada del dedo.
    final lastScroll = _lastScrollAt;
    if (!isEdge &&
        lastScroll != null &&
        clock.now().difference(lastScroll) < _scrollCoalesce) {
      _lastScrollAt = clock.now();
      return;
    }
    final probe = _probe(down);
    if (probe.thorUi) return;
    _retroCorrect(core, probe.pageClass);

    final base = <String, Object?>{
      'dir': dir,
      'distance': delta.distance.round(),
      'durationMs': held.inMilliseconds,
      'start': [down.dx.round(), down.dy.round()],
      'end': [up.position.dx.round(), up.position.dy.round()],
    };
    if (isEdge) {
      // El gesto se anota al SOLTAR, pero la pantalla ya pudo retroceder a
      // mitad del arrastre (el pop queda antes en la línea de tiempo): se
      // dice aquí para que nadie lo lea como «no regresó».
      final nav = core.store.lastOfKind(ThorEventKind.navigation);
      final navAction = nav?.payload['action'];
      final popped = nav != null &&
          nav.seq > (_downNavSeq ?? -1) &&
          (navAction == 'pop' || navAction == 'remove');
      core.recorder.record(ThorEventKind.interaction, {
        'gesture': ThorGesture.edgeSwipe,
        'widget': 'screen_edge',
        'edge': edge,
        if (popped) 'popped': true,
        ...base,
      });
      return;
    }
    final axis = probe.scrollAxis;
    if (axis != null) {
      // Una lista larga = muchos arrastres seguidos: uno solo por ráfaga.
      final now = clock.now();
      final last = _lastScrollAt;
      _lastScrollAt = now;
      if (last != null && now.difference(last) < _scrollCoalesce) return;
      core.recorder.record(ThorEventKind.interaction, {
        'gesture': ThorGesture.scroll,
        'widget': 'Scrollable',
        'axis': axis == Axis.vertical ? 'vertical' : 'horizontal',
        if (probe.pageClass != null) 'page': probe.pageClass,
        ...base,
      });
      return;
    }
    core.recorder.record(ThorEventKind.interaction, {
      'gesture': ThorGesture.swipe,
      'widget': probe.hit?.widgetType ?? 'screen',
      if (probe.hit?.label != null) 'label': probe.hit!.label,
      if (probe.hit?.labelIsCopy ?? false) 'copy': true,
      if (probe.hit?.hidden ?? false) 'hidden': true,
      ...base,
    });
  }

  static double? _viewWidth(int viewId) {
    final view = WidgetsBinding.instance.platformDispatcher.view(id: viewId);
    if (view == null || view.devicePixelRatio == 0) return null;
    return view.physicalSize.width / view.devicePixelRatio;
  }

  // ── Foco de campos de texto (teclado) ──

  static FocusNode? _focused;

  /// Texto de al menos este largo: el evento de edición dice de dónde vino
  /// (`typed` o `pasted_or_scanned`). Una consulta de 60 caracteres no la
  /// tecleó nadie: la pegó o la escaneó, y ese dato explica el bug.
  @visibleForTesting
  static int longTextThreshold = 50;

  /// Un solo cambio que agrega más de esto de golpe = pegado, autocompletar
  /// o lector de códigos (teclear agrega 1; el IME, 2–3 con corrección).
  static const int _pasteJump = 3;

  static _TextWatch? _watch;

  /// Cierra la observación del campo anterior: si el texto cambió, deja un
  /// `text_edit` con tamaños (nunca el contenido).
  static void _endTextWatch() {
    final w = _watch;
    _watch = null;
    if (w == null) return;
    try {
      w.controller.removeListener(w.onChange);
      if (w.edits == 0) return;
      final core = ThorCore.instance;
      if (core == null) return;
      final length = w.controller.text.length;
      core.recorder.record(ThorEventKind.interaction, {
        'gesture': ThorGesture.textEdit,
        'widget': w.type,
        if (w.label != null) 'label': w.label,
        'copy': true,
        'isTextInput': true,
        'edits': w.edits,
        if (w.obscure)
          // Contraseña: ni el largo (revela información); solo si quedó vacío.
          ...{'obscure': true, 'empty': length == 0}
        else ...{
          'length': length,
          'startLength': w.startLength,
          'empty': length == 0,
          if (length >= longTextThreshold)
            'source': w.maxJump > _pasteJump ? 'pasted_or_scanned' : 'typed',
        },
      });
    } on Object {
      // El controlador pudo morir con su pantalla: nada que anotar.
    }
  }

  static void _onFocusChanged() {
    final node = FocusManager.instance.primaryFocus;
    if (identical(node, _focused)) return;
    _endTextWatch();
    _focused = node;
    final context = node?.context;
    if (context == null) return;
    final core = ThorCore.instance;
    if (core == null) return;
    try {
      // `EditableText` adjunta su nodo de foco con el contexto de un
      // `Focus` propio, que cuelga de él.
      final editable = context.widget is EditableText
          ? context.widget as EditableText
          : context.findAncestorWidgetOfExactType<EditableText>();
      if (editable == null) return;
      var ownUi = false;
      TextField? field;
      String? formField;
      context.visitAncestorElements((e) {
        final w = e.widget;
        if (w is ThorOwnUi) ownUi = true;
        if (w is TextField && field == null) field = w;
        if (formField == null && w is FormField) {
          formField = _stripGenerics(w.runtimeType.toString());
        }
        return field == null || !ownUi;
      });
      if (ownUi) return;
      final d = field?.decoration;
      final label = d?.labelText ?? d?.hintText;
      final type = formField == 'TextFormField'
          ? 'TextFormField'
          : field != null
              ? 'TextField'
              : _stripGenerics(editable.runtimeType.toString());
      ScreenCapture.onTextFocus();
      core.recorder.record(ThorEventKind.interaction, {
        'gesture': ThorGesture.textFocus,
        'widget': type,
        if (label != null) 'label': label,
        'copy': true,
        'isTextInput': true,
        if (editable.obscureText) 'obscure': true,
        'keyboard': editable.keyboardType.toString(),
        // Tamaño del texto al enfocar (nunca el contenido; en un campo de
        // contraseña, ni el tamaño).
        if (!editable.obscureText) ...{
          'length': editable.controller.text.length,
          'empty': editable.controller.text.isEmpty,
        } else
          'empty': editable.controller.text.isEmpty,
      });
      _watch = _TextWatch(
        controller: editable.controller,
        type: type,
        label: label,
        obscure: editable.obscureText,
      )..attach();
    } on Object {
      // Observar el foco jamás puede tirar la app.
    }
  }

  /// Recorre el árbol buscando el elemento interactivo más profundo cuyo
  /// RenderBox contiene [position]. Visible para tests.
  @visibleForTesting
  static HitDescription? describeHitForTest(Offset position) =>
      _probe(position).hit;

  /// Qué hay bajo [position]: el interactivo más profundo, la lista
  /// desplazable más profunda, la clase de página y si es la UI de Thor.
  static _Probe _probe(Offset position) {
    final rootElement = WidgetsBinding.instance.rootElement;
    if (rootElement == null) return const _Probe();

    Element? bestHighLevel;
    Element? bestPrimitive;
    // Marcas de privacidad del ancestro de cada candidato (ver [_Mark]).
    var highLevelMark = _Mark.none;
    var primitiveMark = _Mark.none;
    String? pageClass;
    Axis? scrollAxis;
    var thorUi = false;
    // Barrera de un diálogo / hoja modal bajo el dedo (ver abajo).
    var barrier = false;
    var surfaceAboveBarrier = false;

    void visit(Element element, _Mark inherited) {
      final widget = element.widget;
      final mark = switch (widget) {
        ThorOwnUi() => _Mark.thor,
        _ when inherited == _Mark.thor => _Mark.thor,
        ThorReplayIgnore() => _Mark.hidden,
        ThorReplayShowText() when inherited != _Mark.hidden => _Mark.show,
        _ => inherited,
      };
      if (widget is ModalBarrier && widget.dismissible) {
        // Un diálogo u hoja modal tapa la página de abajo: lo que esta
        // tenía bajo el dedo NO es lo que se tocó. Quien venga después
        // (lo de la propia hoja) sí cuenta. El `ModalBarrier` no tiene
        // render propio: se mide con el primero de sus hijos.
        final box = element.findRenderObject();
        if (box is RenderBox && box.hasSize && box.attached) {
          try {
            if (box.paintBounds.contains(box.globalToLocal(position))) {
              bestHighLevel = null;
              bestPrimitive = null;
              barrier = true;
              surfaceAboveBarrier = false;
            }
          } on Object {
            // Transform no invertible: la barrera no cuenta.
          }
        }
      }
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
        if (mark == _Mark.thor) thorUi = true;
        final typeName = _stripGenerics(element.widget.runtimeType.toString());
        if (barrier && _surfaceTypes.contains(typeName)) {
          surfaceAboveBarrier = true;
        }
        if (_highLevelTypes.contains(typeName)) {
          bestHighLevel = element; // el más profundo de su nivel gana
          highLevelMark = mark;
        } else if (_primitiveTypes.contains(typeName)) {
          bestPrimitive = element;
          primitiveMark = mark;
        }
        // El scroll interno de un campo de texto no es una lista.
        if (widget is Scrollable &&
            element.findAncestorWidgetOfExactType<EditableText>() == null) {
          scrollAxis = widget.axis;
        }
        if (VisibleTree.isScreenName(typeName)) pageClass = typeName;
      }
      // Solo lo pintado: un toque nunca cae en una tab oculta.
      VisibleTree.visitChildren(element, (child) => visit(child, mark));
    }

    rootElement.visitChildElements((child) => visit(child, _Mark.none));

    // Alto nivel manda: el GestureDetector interno de un botón es ruido.
    final target = bestHighLevel ?? bestPrimitive;
    _Hit? hit;
    if (target != null) {
      final mark = bestHighLevel != null ? highLevelMark : primitiveMark;
      final type = _stripGenerics(target.widget.runtimeType.toString());
      final label = _labelOf(target, copyText: _copyTypes.contains(type));
      hit = _Hit(
        widgetType: type,
        label: label?.text,
        keyValue: _keyOf(target.widget.key),
        isTextInput: type == 'TextField' || type == 'TextFormField',
        pageClass: pageClass,
        labelIsCopy: mark == _Mark.show || (label?.copy ?? false),
        hidden: mark == _Mark.hidden,
        thorUi: mark == _Mark.thor,
        disabled: _isDisabledButton(target.widget),
      );
    }
    // El toque cayó en la barrera misma (fuera de la hoja/diálogo): es un
    // descarte, no un toque a la página de atrás.
    if (hit == null && barrier && !surfaceAboveBarrier) {
      hit = _Hit(
        widgetType: 'ModalBarrier',
        label: 'barrier',
        isTextInput: false,
        pageClass: pageClass,
        labelIsCopy: true,
      );
    }
    return _Probe(
      hit: hit,
      scrollAxis: scrollAxis,
      pageClass: pageClass,
      thorUi: thorUi || (hit?.thorUi ?? false),
    );
  }

  /// Botón de acción con `onPressed: null`: el toque no puede hacer nada.
  static bool _isDisabledButton(Widget w) => switch (w) {
        ButtonStyleButton(:final onPressed, :final onLongPress) =>
          onPressed == null && onLongPress == null,
        IconButton(:final onPressed) => onPressed == null,
        FloatingActionButton(:final onPressed) => onPressed == null,
        CupertinoButton(:final onPressed) => onPressed == null,
        _ => false,
      };

  static String _stripGenerics(String type) {
    final i = type.indexOf('<');
    return i == -1 ? type : type.substring(0, i);
  }

  static String? _keyOf(Key? key) => switch (key) {
        ValueKey<Object?>(:final value) => value.toString(),
        null => null,
        _ => key.toString(),
      };

  /// Etiqueta legible del elemento: hint de un campo, `Semantics.label`,
  /// tooltip, texto del primer `Text` descendiente o NOMBRE del ícono
  /// (`icono:arrow_back`). Un número suelto (la insignia "1" del carrito)
  /// solo vale si no hay nada mejor. Si el elemento no trae nada (un
  /// `GestureDetector` sobre un `Container` vacío), se mira la envoltura
  /// cercana ([_labelFromAncestors]). Truncada — es una etiqueta, no datos.
  ///
  /// `copy` dice si es copy de la interfaz: hint/label de decoración,
  /// semántica, tooltip e ícono lo son siempre (los escribe la app); el
  /// texto de un `Text` solo si [copyText] (botón de alto nivel) o si está
  /// dentro de un [ThorReplayShowText] bajo el elemento tocado.
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

    final found = _searchLabel(element, copyText: copyText) ??
        _labelFromAncestors(element);
    if (found == null) return null;
    return (
      text: found.text.length > 60
          ? '${found.text.substring(0, 60)}…'
          : found.text,
      copy: found.copy,
    );
  }

  /// Primera etiqueta en el subárbol de [element] (profundidad primero,
  /// como se lee en pantalla). Los números sueltos son el último recurso.
  static ({String text, bool copy})? _searchLabel(
    Element element, {
    required bool copyText,
  }) {
    String? text;
    var copy = false;
    String? numeric;
    var numericCopy = false;
    void findText(Element e, {required bool inShow}) {
      if (text != null) return;
      final w = e.widget;
      final show = inShow || w is ThorReplayShowText;
      if (w is Semantics) {
        final label = _semanticText(w);
        if (label != null) {
          text = label;
          copy = true;
          return;
        }
      }
      if (w is Text) {
        final data = (w.data ?? w.textSpan?.toPlainText())?.trim();
        if (data != null && data.isNotEmpty) {
          if (_isCounter(data)) {
            numeric ??= data;
            numericCopy = copyText || show;
          } else {
            text = data;
            copy = copyText || show;
            return;
          }
        }
      }
      if (w is Tooltip && (w.message ?? '').trim().isNotEmpty) {
        text = w.message!.trim();
        copy = true;
        return;
      }
      if (w is Icon && w.icon != null) {
        final semantic = w.semanticLabel?.trim();
        text = semantic != null && semantic.isNotEmpty
            ? semantic
            : IconNames.labelOf(w.icon!);
        copy = true;
        return;
      }
      e.visitChildElements((child) => findText(child, inShow: show));
    }

    element.visitChildElements((child) => findText(child, inShow: false));
    if (text != null) return (text: text!, copy: copy);
    if (numeric != null) return (text: numeric!, copy: numericCopy);
    return null;
  }

  /// `label` o `tooltip` de un `Semantics`, si traen texto.
  static String? _semanticText(Semantics w) {
    for (final t in [w.properties.label, w.properties.tooltip]) {
      if (t != null && t.trim().isNotEmpty) return t.trim();
    }
    return null;
  }

  static final _counter = RegExp(r'^[\d.,+]{1,4}$');

  /// Insignias y contadores ("1", "12", "99+"): no nombran el botón.
  static bool _isCounter(String text) => _counter.hasMatch(text);

  /// Hasta [_maxAncestorHops] elementos hacia arriba, mientras la envoltura
  /// siga siendo del tamaño de un botón (no más de [_maxAncestorGrowth]
  /// veces el área del elemento): la etiqueta de un botón sin contenido
  /// suele estar en el `Semantics`/`Tooltip`/`Text` que lo rodea. Nunca
  /// sube a una página entera.
  static ({String text, bool copy})? _labelFromAncestors(Element element) {
    final render = element.renderObject;
    if (render is! RenderBox || !render.hasSize) return null;
    final area = render.size.width * render.size.height;
    if (area <= 0) return null;
    ({String text, bool copy})? result;
    var hops = 0;
    element.visitAncestorElements((ancestor) {
      if (++hops > _maxAncestorHops) return false;
      final box = ancestor.renderObject;
      if (box is! RenderBox || !box.hasSize) return true;
      if (box.size.width * box.size.height > area * _maxAncestorGrowth) {
        return false;
      }
      final w = ancestor.widget;
      if (w is Semantics) {
        final label = _semanticText(w);
        if (label != null) {
          result = (text: label, copy: true);
          return false;
        }
      }
      if (w is Tooltip && (w.message ?? '').trim().isNotEmpty) {
        result = (text: w.message!.trim(), copy: true);
        return false;
      }
      final inside = _searchLabel(ancestor, copyText: false);
      if (inside != null) {
        result = inside;
        return false;
      }
      return true;
    });
    return result;
  }

  static const int _maxAncestorHops = 10;
  static const double _maxAncestorGrowth = 6;
}

/// Observa los cambios de un campo mientras tiene el foco: cuántos, cuánto
/// creció el mayor de golpe y el largo de partida. Un listener por campo
/// enfocado (no por frame); solo compara largos, jamás copia el texto.
class _TextWatch {
  _TextWatch({
    required this.controller,
    required this.type,
    required this.label,
    required this.obscure,
  })  : startLength = controller.text.length,
        _lastLength = controller.text.length;

  final TextEditingController controller;
  final String type;
  final String? label;
  final bool obscure;
  final int startLength;
  int _lastLength;
  int edits = 0;
  int maxJump = 0;

  void onChange() {
    final length = controller.text.length;
    if (length == _lastLength) return; // selección/cursor, no edición.
    final grew = length - _lastLength;
    if (grew > maxJump) maxJump = grew;
    _lastLength = length;
    edits++;
  }

  void attach() => controller.addListener(onChange);
}

/// Descripción de un tap resuelta desde el árbol (visible para tests).
typedef HitDescription = _Hit;

/// Lo que hay bajo un punto de la pantalla (ver `InteractionCapture._probe`).
class _Probe {
  const _Probe({
    this.hit,
    this.scrollAxis,
    this.pageClass,
    this.thorUi = false,
  });

  final _Hit? hit;
  final Axis? scrollAxis;
  final String? pageClass;
  final bool thorUi;
}

class _Hit {
  const _Hit({
    required this.widgetType,
    required this.isTextInput,
    this.label,
    this.keyValue,
    this.pageClass,
    this.labelIsCopy = false,
    this.hidden = false,
    this.thorUi = false,
    this.disabled = false,
  });

  /// Botón de acción deshabilitado (`onPressed: null`).
  final bool disabled;

  final String widgetType;
  final String? label;
  final String? keyValue;
  final bool isTextInput;
  final String? pageClass;

  /// El label es copy de la interfaz: el replay lo puede mandar legible.
  final bool labelIsCopy;

  /// El tap cayó dentro de un [ThorReplayIgnore].
  final bool hidden;

  /// El tap cayó en la UI propia de Thor ([ThorOwnUi]).
  final bool thorUi;
}

/// Marca de privacidad heredada de los ancestros durante el recorrido.
/// `thor` (UI de Thor) gana sobre todo; `hidden` (ThorReplayIgnore) gana
/// sobre `show` (ThorReplayShowText).
enum _Mark { none, show, hidden, thor }
