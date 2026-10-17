import 'dart:collection';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:thor_flutter/src/visible_tree.dart';

/// Excluye su subárbol del replay: no se dibuja ni se recorre. Para zonas
/// sensibles de la app (datos de tarjeta, documentos) y para la UI propia
/// de Thor (burbuja, avisos).
class ThorReplayIgnore extends StatelessWidget {
  /// Oculta [child] en el replay.
  const ThorReplayIgnore({required this.child, super.key});

  /// Lo que se muestra en la app pero no en el replay.
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Viewport (zona con scroll) visto en el último recorrido. El replay mueve
/// el contenido de cada viewport con su offset en vez de re-capturarlo.
class WireViewport {
  /// Crea la referencia a un viewport.
  WireViewport(this.id, this.axis, this.render);

  /// Id estable dentro de la sesión (mismo RenderObject → mismo id).
  final int id;

  /// 0 = vertical, 1 = horizontal.
  final int axis;

  /// Render del viewport (para leer su offset en cada frame).
  final RenderObject render;

  /// Offset actual en píxeles lógicos, o `null` si ya no es legible.
  double? get pixels {
    try {
      final offset = (render as dynamic).offset as ViewportOffset;
      return offset.hasPixels ? offset.pixels : null;
    } on Object {
      return null;
    }
  }
}

/// Resultado de un recorrido: la lista de primitivas de dibujo (en orden de
/// pintado) y los viewports encontrados con su offset al momento.
class Wireframe {
  /// Crea el resultado.
  Wireframe(this.ops, this.viewports, this.offsets);

  /// Primitivas en coordenadas de CONTENIDO (como si cada viewport tuviera
  /// offset 0). Así un scroll no cambia la lista: solo el offset.
  final List<List<Object?>> ops;

  /// Viewports encontrados, para muestrear su scroll.
  final List<WireViewport> viewports;

  /// Offset de cada viewport al capturar (id → píxeles).
  final Map<int, double> offsets;
}

/// Convierte el árbol montado en un wireframe — la "reconstrucción" que
/// usa el replay en lugar de video.
///
/// Recorre ELEMENTOS (no solo render objects) porque el widget da contexto
/// que el render pierde en release: la URL de una imagen vive en su
/// `ImageProvider`, no en el `RenderImage`.
///
/// Formato de cada primitiva (arreglo compacto, posición 0 = tipo):
/// - rect:     `['r', x, y, w, h, vp, color, radio, colorBorde, anchoBorde]`
/// - texto:    `['t', x, y, w, h, vp, color, tamaño, peso, alineación, texto]`
///   (enmascarado: `texto` es la lista de largos de palabra)
/// - ícono:    `['i', x, y, w, h, vp, color, tamaño, codepoint, fuente]`
/// - imagen:   `['m', x, y, w, h, vp]` (+ `url` solo con `imageUrls`)
/// - campo:    `['f', x, y, w, h, vp, largoDelTexto]` (contenido jamás)
/// - viewport: `['v', x, y, w, h, vpPadre, id, eje]`
class WireframeBuilder {
  /// Crea un recorrido de una sola vez.
  WireframeBuilder({required this.maskText, this.imageUrls = false});

  /// Texto enmascarado: conserva espacios y largo, cambia todo lo demás por
  /// `•`. La forma del texto basta para reconocer la pantalla.
  final bool maskText;

  /// Incluye la URL de cada imagen. Apagado por defecto: una imagen viaja
  /// como un rectángulo — nada pesado sale del dispositivo.
  final bool imageUrls;

  /// Usa `getTransformTo` por nodo (la versión lenta de referencia). Solo
  /// para que los tests comprueben que la caché da lo mismo.
  @visibleForTesting
  static bool debugExactTransforms = false;

  static final Expando<int> _viewportIds = Expando('thorViewportId');
  static int _nextViewportId = 1;

  late Size _screen;
  final List<List<Object?>> _ops = [];
  final List<WireViewport> _viewports = [];
  final Map<int, double> _offsets = {};

  /// Transform de pintado acumulado por render object en este recorrido.
  final Map<RenderObject, Matrix4> _transforms = HashMap.identity();

  /// Recorre desde la raíz. Devuelve `null` si el árbol no está listo
  /// (layout pendiente): mejor perder un snapshot que leer basura.
  Wireframe? build() {
    final root = WidgetsBinding.instance.rootElement;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (root == null || views.isEmpty) return null;
    final view = views.first;
    _screen = view.physicalSize / view.devicePixelRatio;
    _visit(root, const _Ctx(vp: 0, shift: Offset.zero, url: null));
    return Wireframe(_ops, _viewports, _offsets);
  }

  void _visit(Element element, _Ctx ctx) {
    var next = ctx;
    final widget = element.widget;
    if (widget is ThorReplayIgnore) return;
    if (widget is Image) next = next.withUrl(_imageUrl(widget.image));

    if (element is RenderObjectElement) {
      final ro = element.renderObject;
      if (VisibleTree.isHidden(ro)) return;
      if (ro is RenderBox && ro.hasSize && ro.attached) {
        final rect = _globalRect(ro);
        if (rect == null) return;
        // Fuera de pantalla (más el cache extent): no se dibuja ni se
        // recorre — una lista larga no debe costar O(items).
        if (!_onScreen(rect)) return;
        final content = rect.shift(next.shift);
        _emit(ro, element, content, next);
        if (ro is RenderAbstractViewport) {
          next = _enterViewport(ro, content, next);
        }
      }
    }
    VisibleTree.visitChildren(element, (child) => _visit(child, next));
  }

  _Ctx _enterViewport(RenderObject ro, Rect content, _Ctx ctx) {
    final id = _viewportIds[ro] ??= _nextViewportId++;
    final axis = _axisOf(ro);
    final vp = WireViewport(id, axis, ro);
    final px = vp.pixels ?? 0;
    _viewports.add(vp);
    _offsets[id] = px;
    _ops.add(['v', ..._box(content), ctx.vp, id, axis]);
    // Los hijos se guardan en coordenadas de contenido: se les suma el
    // offset actual en su eje.
    final shift = ctx.shift + (axis == 0 ? Offset(0, px) : Offset(px, 0));
    return _Ctx(vp: id, shift: shift, url: ctx.url);
  }

  void _emit(RenderBox ro, Element element, Rect r, _Ctx ctx) {
    final vp = ctx.vp;
    if (ro is RenderDecoratedBox) {
      final d = ro.decoration;
      if (d is BoxDecoration) {
        final color = d.color ?? d.gradient?.colors.first;
        final border = d.border is Border ? d.border! as Border : null;
        final side = border?.top;
        if (color != null || (side != null && side.width > 0)) {
          _ops.add([
            'r',
            ..._box(r),
            vp,
            color?.toARGB32(),
            _radius(d.borderRadius),
            side?.color.toARGB32(),
            side?.width,
          ]);
        }
      }
    } else if (ro is RenderPhysicalModel) {
      _ops.add([
        'r',
        ..._box(r),
        vp,
        ro.color.toARGB32(),
        _radius(ro.borderRadius),
        null,
        null,
      ]);
    } else if (ro is RenderPhysicalShape) {
      _ops.add(['r', ..._box(r), vp, ro.color.toARGB32(), null, null, null]);
    } else if (ro is RenderParagraph) {
      _paragraph(ro, r, vp);
    } else if (ro is RenderImage) {
      _ops.add(['m', ..._box(r), vp, if (imageUrls) ctx.url ?? '']);
    } else if (ro is RenderEditable) {
      _ops.add(['f', ..._box(r), vp, ro.text?.toPlainText().length ?? 0]);
    } else if (VisibleTree.runtimeName(ro) == '_RenderColoredBox') {
      try {
        final color = (ro as dynamic).color as Color;
        _ops.add(['r', ..._box(r), vp, color.toARGB32(), null, null, null]);
      } on Object {
        // Forma interna cambió: se omite, no se rompe.
      }
    }
  }

  void _paragraph(RenderParagraph ro, Rect r, int vp) {
    final span = ro.text;
    final text = span.toPlainText();
    if (text.trim().isEmpty) return;
    final style = span.style ??
        (span is TextSpan && (span.children?.isNotEmpty ?? false)
            ? span.children!.first.style
            : null);
    final family = style?.fontFamily ?? '';
    final color = style?.color?.toARGB32();
    final size = style?.fontSize ?? 14;
    // Los íconos de Flutter son texto con una fuente de íconos: se mandan
    // como codepoint para que el visor los dibuje con la misma fuente.
    if (family.contains('MaterialIcons') ||
        family.contains('CupertinoIcons') ||
        family.contains('Icons')) {
      _ops.add(['i', ..._box(r), vp, color, size, text.runes.first, family]);
      return;
    }
    _ops.add([
      't',
      ..._box(r),
      vp,
      color,
      size,
      (style?.fontWeight ?? FontWeight.w400).value,
      ro.textAlign.index,
      if (maskText) _mask(text) else text,
    ]);
  }

  /// Texto enmascarado = largo de cada palabra (`[10, 4, 8]`): conserva
  /// la forma para reconocer la pantalla sin un solo carácter real, y pesa
  /// menos que el texto mismo.
  static final _spaces = RegExp(r'\s+');

  static List<int> _mask(String text) => [
        for (final word in text.split(_spaces))
          if (word.isNotEmpty) word.runes.length,
      ];

  static String? _imageUrl(ImageProvider provider) {
    if (provider is NetworkImage) return provider.url;
    if (provider is AssetImage) return 'asset:${provider.assetName}';
    if (provider is ResizeImage) return _imageUrl(provider.imageProvider);
    // Proveedores de terceros (cached_network_image) exponen `url`.
    try {
      return (provider as dynamic).url as String?;
    } on Object {
      return null;
    }
  }

  static int _axisOf(RenderObject ro) {
    try {
      final axis = (ro as dynamic).axis as Axis;
      return axis == Axis.vertical ? 0 : 1;
    } on Object {
      return 0;
    }
  }

  static double? _radius(BorderRadiusGeometry? radius) {
    if (radius is BorderRadius) return radius.topLeft.x;
    return null;
  }

  Rect? _globalRect(RenderBox ro) {
    try {
      final m = debugExactTransforms ? ro.getTransformTo(null) : _transform(ro);
      return MatrixUtils.transformRect(m, Offset.zero & ro.size);
    } on Object {
      return null;
    }
  }

  /// Lo mismo que `ro.getTransformTo(null)` pero memorizado: aquella sube
  /// hasta la raíz en CADA nodo (O(n·profundidad), con árboles de 60+
  /// niveles); aquí cada nodo copia el de su padre y aplica un solo paso.
  /// Mismas operaciones en el mismo orden → los mismos doubles, bit a bit
  /// (los hashes de bloque no cambian). Como `getTransformTo(null)`, el
  /// transform de la raíz (`RenderView`, el devicePixelRatio) no se aplica.
  Matrix4 _transform(RenderObject ro) {
    final cached = _transforms[ro];
    if (cached != null) return cached;
    final parent = ro.parent;
    final Matrix4 m;
    if (parent == null || parent.parent == null) {
      m = Matrix4.identity();
    } else {
      m = _transform(parent).clone();
      parent.applyPaintTransform(ro, m);
    }
    return _transforms[ro] = m;
  }

  bool _onScreen(Rect r) =>
      r.right > -_screen.width &&
      r.left < _screen.width * 2 &&
      r.bottom > -_screen.height &&
      r.top < _screen.height * 2 &&
      r.width > 0 &&
      r.height > 0;

  static List<num> _box(Rect r) => [
        _q(r.left),
        _q(r.top),
        _q(r.width),
        _q(r.height),
      ];

  /// Cuantiza a 0.5 px: menos dígitos y diffs más estables.
  static num _q(double v) {
    final h = (v * 2).round();
    return h.isEven ? h ~/ 2 : h / 2;
  }
}

class _Ctx {
  const _Ctx({required this.vp, required this.shift, required this.url});

  final int vp;
  final Offset shift;
  final String? url;

  _Ctx withUrl(String? url) => _Ctx(vp: vp, shift: shift, url: url);
}
