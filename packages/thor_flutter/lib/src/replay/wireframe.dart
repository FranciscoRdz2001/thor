import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoTextField;
import 'package:flutter/material.dart' show TextField;
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
///   `+ [elevación, degradado]` solo si hay sombra o degradado (ver abajo)
/// - texto:    `['t', x, y, w, h, vp, color, tamaño, peso, alineación, texto]`
///   (enmascarado: `texto` es la lista de largos de palabra)
/// - ícono:    `['i', x, y, w, h, vp, color, tamaño, codepoint, fuente]`
/// - imagen:   `['m', x, y, w, h, vp]` (+ `url` solo con `imageUrls`;
///   `+ [url|null, radio]` si un recorte redondea la imagen)
/// - campo:    `['f', x, y, w, h, vp, largoDelTexto]` (contenido jamás;
///   `+ [largoDelHint]` solo vacío y con hint)
/// - gráfico:  `['g', x, y, w, h, vp, tipo]` (0 = CustomPaint, 1 = vector
///   tipo SVG/Lottie, 2 = vista nativa: mapa, webview) `+ [radio]`
/// - viewport: `['v', x, y, w, h, vpPadre, id, eje]`
///
/// Los campos nuevos van SIEMPRE al final y solo cuando aportan algo: un
/// widget sin sombra/degradado/recorte serializa exactamente igual que
/// antes, así su bloque conserva el hash y no se vuelve a subir. Un visor
/// viejo ignora lo que no conoce (y `g` no lo dibuja).
///
/// Degradado: `[0, colores, stops|null, bx, by, ex, ey]` (lineal, en
/// Alignment), `[1, colores, stops|null, cx, cy, radio]` (radial),
/// `[2, colores, stops|null, cx, cy]` (sweep). El color de la posición 6
/// sigue siendo el primero, para visores que no lo entienden.
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
    _visit(root, const _Ctx(vp: 0, shift: Offset.zero));
    return Wireframe(_ops, _viewports, _offsets);
  }

  void _visit(Element element, _Ctx ctx) {
    var next = ctx;
    final widget = element.widget;
    if (widget is ThorReplayIgnore) return;
    if (widget is Image) next = next.copyWith(url: _imageUrl(widget.image));
    // El hint lo escribe la app, no el usuario: su LARGO dibuja el campo
    // vacío como en el dispositivo. El texto tecleado jamás viaja.
    if (widget is TextField) {
      next = next.copyWith(hint: widget.decoration?.hintText?.length ?? 0);
    } else if (widget is CupertinoTextField) {
      next = next.copyWith(hint: widget.placeholder?.length ?? 0);
    }

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
        } else {
          next = _enterClip(ro, content, next);
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
    return _Ctx(vp: id, shift: shift, url: ctx.url, hint: ctx.hint);
  }

  /// ClipRRect/ClipOval no pintan nada, pero dan la forma: una tarjeta o
  /// un avatar es un rect/imagen recortado. Se recuerda el recorte para
  /// redondear al descendiente que lo cubre exactamente.
  _Ctx _enterClip(RenderBox ro, Rect content, _Ctx ctx) {
    double? radius;
    if (ro is RenderClipRRect && ro.clipBehavior != Clip.none) {
      radius = ro.borderRadius.resolve(TextDirection.ltr).topLeft.x;
    } else if (ro is RenderClipOval && ro.clipBehavior != Clip.none) {
      radius = content.shortestSide / 2;
    }
    if (radius == null || radius <= 0) return ctx;
    return ctx.copyWith(clip: _Clip(content, radius, ctx.vp));
  }

  /// Radio del recorte ancestro si [r] lo cubre exactamente (a la
  /// cuantización de 0.5 px); `null` si no hay o no coincide.
  static num? _clipRadius(Rect r, _Ctx ctx) {
    final c = ctx.clip;
    if (c == null || c.vp != ctx.vp) return null;
    bool near(double a, double b) => (a - b).abs() <= 0.5;
    if (near(r.left, c.rect.left) &&
        near(r.top, c.rect.top) &&
        near(r.right, c.rect.right) &&
        near(r.bottom, c.rect.bottom)) {
      return _q(c.radius);
    }
    return null;
  }

  void _emit(RenderBox ro, Element element, Rect r, _Ctx ctx) {
    final vp = ctx.vp;
    if (ro is RenderDecoratedBox) {
      final d = ro.decoration;
      if (d is BoxDecoration) _decoration(d, r, ctx);
    } else if (ro is RenderPhysicalModel) {
      final circle = ro.shape == BoxShape.circle;
      _rect(
        circle ? _square(r) : r,
        vp,
        ro.color.toARGB32(),
        circle
            ? _q(r.shortestSide / 2)
            : _radius(ro.borderRadius) ?? _clipRadius(r, ctx),
        elevation: ro.elevation,
      );
    } else if (ro is RenderPhysicalShape) {
      // Material (Card, botones, sheets) pinta con PhysicalShape: la forma
      // viene en el clipper. Radio 0 → null, como antes de leerlo.
      final shape = ro.clipper;
      final radius = shape is ShapeBorderClipper
          ? _shapeRadius(shape.shape, r.size)
          : null;
      _rect(
        r,
        vp,
        ro.color.toARGB32(),
        radius ?? _clipRadius(r, ctx),
        elevation: ro.elevation,
      );
    } else if (ro is RenderParagraph) {
      _paragraph(ro, r, vp);
    } else if (ro is RenderImage) {
      _image(r, ctx, ctx.url, _clipRadius(r, ctx));
    } else if (ro is RenderEditable) {
      final len = ro.text?.toPlainText().length ?? 0;
      final hint = ctx.hint ?? 0;
      _ops.add(['f', ..._box(r), vp, len, if (len == 0 && hint > 0) hint]);
    } else if (ro is RenderCustomPaint) {
      // Solo el painter de FONDO (o el de frente de una hoja): el de frente
      // con hijo es casi siempre adorno del framework (scrollbar, brillo
      // de overscroll, banner de debug) y taparía la pantalla entera.
      final painter =
          ro.painter ?? (ro.child == null ? ro.foregroundPainter : null);
      if (painter != null &&
          !_framePainters.contains(VisibleTree.runtimeName(painter))) {
        _graphic(r, ctx, 0);
      }
    } else if (ro is PlatformViewRenderBox || ro is RenderDarwinPlatformView) {
      // Mapa, webview: sus píxeles viven fuera de Flutter. Una caja basta.
      _graphic(r, ctx, 2);
    } else {
      final name = VisibleTree.runtimeName(ro);
      if (name == '_RenderColoredBox') {
        try {
          final color = (ro as dynamic).color as Color;
          _rect(r, vp, color.toARGB32(), _clipRadius(r, ctx));
        } on Object {
          // Forma interna cambió: se omite, no se rompe.
        }
      } else if (_vectorRenders.contains(name)) {
        _graphic(r, ctx, 1);
      }
    }
  }

  /// Render objects de paquetes de gráficos vectoriales (flutter_svg 2 vía
  /// vector_graphics, flutter_svg 1, lottie). Por nombre: el SDK no depende
  /// de esos paquetes.
  static const _vectorRenders = {
    'RenderVectorGraphic',
    'RenderPictureVectorGraphic',
    'RenderPicture',
    'RenderLottie',
  };

  /// Painters internos del framework que no son contenido (indicador de
  /// tabs, bordes de Material, efecto de estirar, manijas de selección).
  /// Con `--obfuscate` el nombre cambia y se dibujan como gráfico: falla
  /// hacia mostrar de más una caja, nunca hacia romper.
  static const _framePainters = {
    '_IndicatorPainter',
    '_DividerPainter',
    '_ShapeBorderPainter',
    '_StretchEffectPainter',
    '_RadialPainter',
    '_ShadowPainter',
    '_TextSelectionHandlePainter',
    '_CupertinoTextSelectionHandlePainter',
    '_CupertinoDividerPainter',
    '_InputBorderPainter',
    '_GridPaperPainter',
    '_SemanticsDebuggerPainter',
    '_ExitWidgetSelectionTooltipPainter',
  };

  void _decoration(BoxDecoration d, Rect r, _Ctx ctx) {
    final circle = d.shape == BoxShape.circle;
    // Un círculo se pinta inscrito en el lado corto: se manda su cuadrado.
    final box = circle ? _square(r) : r;
    final radius = circle
        ? _q(box.width / 2)
        : _radius(d.borderRadius) ?? _clipRadius(r, ctx);
    final color = d.color ?? d.gradient?.colors.first;
    final border = d.border is Border ? d.border! as Border : null;
    final side = border?.top;
    if (color != null || (side != null && side.width > 0)) {
      var shadow = 0.0;
      for (final s in d.boxShadow ?? const <BoxShadow>[]) {
        // La elevación de Material proyecta ~2× su valor de desenfoque.
        if (s.blurRadius / 2 > shadow) shadow = s.blurRadius / 2;
      }
      _rect(
        box,
        ctx.vp,
        color?.toARGB32(),
        radius,
        borderColor: side?.color.toARGB32(),
        borderWidth: side?.width,
        elevation: shadow,
        gradient: _gradient(d.gradient),
      );
    }
    // Imagen de fondo (CircleAvatar.backgroundImage, banners): caja de
    // imagen, sin URL salvo `imageUrls`.
    final image = d.image;
    if (image != null) {
      _image(box, ctx, _imageUrl(image.image), radius);
    }
  }

  /// Emite un rect. Las posiciones 10 y 11 (elevación, degradado) solo
  /// aparecen si hay algo que decir: sin ellas el op es idéntico al de
  /// siempre (mismo hash de bloque).
  void _rect(
    Rect r,
    int vp,
    int? color,
    num? radius, {
    int? borderColor,
    double? borderWidth,
    double elevation = 0,
    List<Object?>? gradient,
  }) {
    final hasElevation = elevation > 0;
    _ops.add([
      'r',
      ..._box(r),
      vp,
      color,
      radius,
      borderColor,
      borderWidth,
      if (hasElevation) _q(elevation) else if (gradient != null) null,
      if (gradient != null) gradient,
    ]);
  }

  void _image(Rect r, _Ctx ctx, String? url, num? radius) {
    _ops.add([
      'm',
      ..._box(r),
      ctx.vp,
      if (imageUrls) url ?? '' else if (radius != null) null,
      if (radius != null) radius,
    ]);
  }

  void _graphic(Rect r, _Ctx ctx, int kind) {
    final radius = _clipRadius(r, ctx);
    _ops.add(['g', ..._box(r), ctx.vp, kind, if (radius != null) radius]);
  }

  static Rect _square(Rect r) => Rect.fromCenter(
        center: r.center,
        width: r.shortestSide,
        height: r.shortestSide,
      );

  /// Radio de una forma de Material, o `null` si es recta o no se conoce.
  static num? _shapeRadius(ShapeBorder shape, Size size) {
    double? radius;
    if (shape is RoundedRectangleBorder) {
      radius = shape.borderRadius.resolve(TextDirection.ltr).topLeft.x;
    } else if (shape is RoundedSuperellipseBorder) {
      radius = shape.borderRadius.resolve(TextDirection.ltr).topLeft.x;
    } else if (shape is CircleBorder || shape is StadiumBorder) {
      radius = size.shortestSide / 2;
    }
    return radius == null || radius <= 0 ? null : _q(radius);
  }

  /// Degradado compacto (ver formato arriba) o `null`. Unas decenas de
  /// bytes y solo en los widgets que lo tienen.
  static List<Object?>? _gradient(Gradient? g) {
    if (g == null) return null;
    final colors = [for (final c in g.colors) c.toARGB32()];
    final stops = g.stops == null ? null : [for (final s in g.stops!) _r2(s)];
    if (g is LinearGradient) {
      final b = g.begin.resolve(TextDirection.ltr);
      final e = g.end.resolve(TextDirection.ltr);
      return [0, colors, stops, _r2(b.x), _r2(b.y), _r2(e.x), _r2(e.y)];
    }
    if (g is RadialGradient) {
      final c = g.center.resolve(TextDirection.ltr);
      return [1, colors, stops, _r2(c.x), _r2(c.y), _r2(g.radius)];
    }
    if (g is SweepGradient) {
      final c = g.center.resolve(TextDirection.ltr);
      return [2, colors, stops, _r2(c.x), _r2(c.y)];
    }
    return null;
  }

  static num _r2(double v) {
    final h = (v * 100).round();
    return h % 100 == 0 ? h ~/ 100 : h / 100;
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
      final box = Offset.zero & ro.size;
      // Rotado (Transform.rotate, RotationTransition, un spinner): la caja
      // envolvente crece y encoge con el ángulo — basura que además cambia
      // el hash en cada cuadro. Se aproxima con la caja SIN rotar,
      // escalada y centrada donde cae su centro: estable y del tamaño real.
      // Sin rotación estas entradas son 0 exacto y el cálculo es el de
      // siempre (mismos doubles, mismos hashes).
      final skewX = m.entry(0, 1);
      final skewY = m.entry(1, 0);
      if (skewX != 0 || skewY != 0) {
        final sx = m.entry(0, 0);
        final sy = m.entry(1, 1);
        // Múltiplos de 90°: la envolvente ya es exacta.
        if (sx.abs() > 1e-6 || sy.abs() > 1e-6) {
          final center = MatrixUtils.transformPoint(m, box.center);
          final scaleX = math.sqrt(sx * sx + skewY * skewY);
          final scaleY = math.sqrt(skewX * skewX + sy * sy);
          return Rect.fromCenter(
            center: center,
            width: box.width * scaleX,
            height: box.height * scaleY,
          );
        }
      }
      return MatrixUtils.transformRect(m, box);
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
  const _Ctx({
    required this.vp,
    required this.shift,
    this.url,
    this.clip,
    this.hint,
  });

  final int vp;
  final Offset shift;
  final String? url;

  /// Recorte redondeado ancestro más cercano.
  final _Clip? clip;

  /// Largo del hint del campo de texto ancestro.
  final int? hint;

  _Ctx copyWith({String? url, _Clip? clip, int? hint}) => _Ctx(
        vp: vp,
        shift: shift,
        url: url ?? this.url,
        clip: clip ?? this.clip,
        hint: hint ?? this.hint,
      );
}

class _Clip {
  const _Clip(this.rect, this.radius, this.vp);

  /// En coordenadas de contenido del viewport [vp].
  final Rect rect;
  final double radius;
  final int vp;
}
