import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/error_capture.dart';
import 'package:thor_flutter/src/visible_tree.dart';

/// Salud visible de la UI: lo que el usuario VE mal aunque no haya
/// excepción. Un solo recorrido del árbol pintado cada [tick] (nada por
/// frame: `onFrame` solo suma un entero) detecta:
///
/// - **Pantalla atascada** → `performance {kind: stuck_loading, screen, ms}`:
///   un indicador de carga (spinner, barra, esqueleto/shimmer) lleva
///   [stuckAfter] o más visible en la misma pantalla.
/// - **Pantalla en blanco** → `performance {kind: blank_screen, screen, ms,
///   nodes}`: hay pantalla, nada cargando y casi nada pintado (≤
///   [blankMaxNodes] textos/imágenes/campos) durante [blankAfter].
///   Las pantallas con vista nativa (cámara, mapa, webview) se excluyen:
///   su contenido no está en el árbol de Flutter.
/// - **Mensajes de la app** → un `AlertDialog`/`SnackBar`/`MaterialBanner`/
///   `*Toast`/`*Dialog` que APARECE: si el texto parece un fallo, `error`
///   con `source: ui_error` (cuenta como error, se agrupa en Issues); si no,
///   `environment {signal: ui_message, widget, text}`. Texto sin secretos
///   (y sin datos personales con la política estricta).
/// - **Imágenes que no cargaron** → `error` con `source: image_error` y la
///   URL; incluso cuando la app puso un `errorBuilder` (que se traga la
///   excepción) porque la petición fallida se ve en la capa de red.
///
/// Costo: el recorrido corre una vez por [tick] y SOLO si hubo frames desde
/// el anterior o hay algo en observación (carga, blanco, mensaje visible);
/// en segundo plano no corre.
class UiHealthCapture {
  UiHealthCapture._();

  static bool _installed = false;
  static Timer? _timer;
  static void Function()? _unsubscribe;

  /// Cada cuánto se mira el árbol.
  static Duration tick = const Duration(seconds: 1);

  /// Carga visible esta duración o más → `stuck_loading`.
  static Duration stuckAfter = const Duration(seconds: 8);

  /// Pantalla casi vacía esta duración o más → `blank_screen`.
  static Duration blankAfter = const Duration(seconds: 5);

  /// Cuántos nodos con contenido (texto, imagen, campo) como máximo
  /// todavía cuentan como «casi vacía». Un título de AppBar ya es uno.
  static int blankMaxNodes = 3;

  /// Reloj monotónico en ms. Sustituible en tests.
  @visibleForTesting
  static int Function() nowMs = _defaultNow;
  static final Stopwatch _watch = Stopwatch()..start();
  static int _defaultNow() => _watch.elapsedMilliseconds;

  /// Si la app está al frente. Sustituible en tests.
  @visibleForTesting
  static bool Function() isForeground = _defaultForeground;
  static bool _defaultForeground() {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// Instala el temporizador y la escucha de red. Idempotente.
  static void install() {
    if (_installed) return;
    _installed = true;
    _timer = Timer.periodic(tick, (_) => _onTick());
    attach();
  }

  /// Desinstala (tests).
  static void uninstall() {
    _installed = false;
    _timer?.cancel();
    _timer = null;
    _unsubscribe?.call();
    _unsubscribe = null;
    _attachedTo = null;
    _resetEpisodes();
    _shown.clear();
    _recentImages.clear();
    _frames = 0;
    _scannedFrames = -1;
  }

  static Object? _attachedTo;

  /// Suscribe la escucha de peticiones al núcleo vigente (re-engancha si el
  /// núcleo cambió: tests, hot restart, renovación de sesión).
  static void attach() {
    final core = ThorCore.instance;
    if (core == null || identical(_attachedTo, core.recorder)) return;
    _unsubscribe?.call();
    _attachedTo = core.recorder;
    _unsubscribe = core.recorder.addListener(_onEvent);
  }

  // ── Frames ──

  static int _frames = 0;
  static int _scannedFrames = -1;
  static bool _watching = false;

  /// Un frame se dibujó (lo llama `ScreenCapture`, ya por frame): solo
  /// suma un entero.
  static void onFrame() => _frames++;

  static void _onTick() {
    if (!_installed) return;
    if (!isForeground()) {
      // Lo que pasó con la app en segundo plano no es «atascado».
      _resetEpisodes();
      return;
    }
    if (_frames == _scannedFrames && !_watching) return;
    scan();
  }

  // ── Episodios ──

  static int? _loadingSince;
  static String? _loadingScreen;
  static bool _loadingReported = false;

  static int? _blankSince;
  static String? _blankScreen;
  static bool _blankReported = false;

  /// Mensajes visibles en el último recorrido (`widget|texto`): uno se
  /// reporta al aparecer y puede volver a reportarse si se va y regresa.
  static final Set<String> _shown = {};

  static void _resetEpisodes() {
    _loadingSince = _loadingScreen = null;
    _loadingReported = false;
    _blankSince = _blankScreen = null;
    _blankReported = false;
    _watching = false;
  }

  /// Mira el árbol ahora y emite lo que corresponda.
  @visibleForTesting
  static void scan() {
    final core = ThorCore.instance;
    if (core == null) return;
    final _Walk walk;
    try {
      walk = _walk();
    } on Object {
      return; // Un árbol a medio construir no debe tumbar nada.
    }
    _scannedFrames = _frames;
    final now = nowMs();
    final screen = core.recorder.currentScreen?.display;

    _checkLoading(walk, screen, now);
    _checkBlank(walk, screen, now);
    _checkMessages(walk);

    _watching = walk.loading ||
        (_blankSince != null && !_blankReported) ||
        walk.messages.isNotEmpty;
  }

  static void _checkLoading(_Walk walk, String? screen, int now) {
    if (!walk.loading) {
      _loadingSince = _loadingScreen = null;
      _loadingReported = false;
      return;
    }
    // Otra pantalla = otro episodio.
    if (_loadingSince == null || _loadingScreen != screen) {
      _loadingSince = now;
      _loadingScreen = screen;
      _loadingReported = false;
      return;
    }
    final elapsed = now - _loadingSince!;
    if (_loadingReported || elapsed < stuckAfter.inMilliseconds) return;
    _loadingReported = true;
    _recordPerf({
      'kind': 'stuck_loading',
      'screen': screen,
      'ms': elapsed,
    });
  }

  static void _checkBlank(_Walk walk, String? screen, int now) {
    final blank = screen != null &&
        !walk.loading &&
        !walk.platformView &&
        walk.content <= blankMaxNodes;
    if (!blank) {
      _blankSince = _blankScreen = null;
      _blankReported = false;
      return;
    }
    if (_blankSince == null || _blankScreen != screen) {
      _blankSince = now;
      _blankScreen = screen;
      _blankReported = false;
      return;
    }
    final elapsed = now - _blankSince!;
    if (_blankReported || elapsed < blankAfter.inMilliseconds) return;
    _blankReported = true;
    _recordPerf({
      'kind': 'blank_screen',
      'screen': screen,
      'ms': elapsed,
      'nodes': walk.content,
    });
  }

  static void _checkMessages(_Walk walk) {
    final now = <String>{};
    for (final m in walk.messages) {
      final key = '${m.widget}|${m.text}';
      now.add(key);
      if (_shown.contains(key)) continue;
      _recordMessage(m);
    }
    _shown
      ..clear()
      ..addAll(now);
  }

  static void _recordPerf(Map<String, Object?> payload) {
    try {
      ThorCore.instance?.recorder.record(ThorEventKind.performance, payload);
    } on Object {
      // Observar jamás debe tumbar a la app.
    }
  }

  static void _recordMessage(_Msg m) {
    final core = ThorCore.instance;
    if (core == null) return;
    try {
      final text = core.redaction.scrub(m.text);
      if (looksLikeError(text)) {
        ErrorCapture.recordSignal(
          source: 'ui_error',
          type: 'UiError',
          message: '${m.widget}: «$text»',
          extra: {'widget': m.widget, 'text': text},
        );
      } else {
        core.recorder.record(ThorEventKind.environment, {
          'signal': 'ui_message',
          'widget': m.widget,
          'text': text,
        });
      }
    } on Object {
      // Observar jamás debe tumbar a la app.
    }
  }

  static final _errorWords = RegExp(
    'error|fall[óo]|falla|no se pudo|no pudimos|no fue posible|'
    'int[ée]nta(lo)? (de nuevo|otra vez|m[áa]s tarde)|vuelve a intentar|'
    'ocurri[óo]|problema|inv[áa]lid|incorrect|no encontr|sin conexi[óo]n|'
    'tiempo de espera|timeout|timed out|failed|failure|unable|'
    "couldn'?t|could not|try again|something went wrong|denied|denegad|"
    'no autorizad|no tienes permiso|expir',
    caseSensitive: false,
  );

  /// Si el texto de un mensaje de la app habla de un fallo.
  @visibleForTesting
  static bool looksLikeError(String text) => _errorWords.hasMatch(text);

  // ── Imágenes ──

  /// URL (host+ruta) → cuándo se reportó, para no grabar dos veces la
  /// misma falla (red + excepción de imagen).
  static final Map<String, int> _recentImages = {};
  static const _imageDedupeMs = 5000;

  static final _imagePath = RegExp(
    r'\.(png|jpe?g|gif|webp|bmp|svg|avif|heic)$',
    caseSensitive: false,
  );

  static void _onEvent(ThorEvent event) {
    if (event.kind != ThorEventKind.network) return;
    try {
      final p = event.payload;
      final status = p['statusCode'];
      final failed = p['error'] != null || (status is int && status >= 400);
      if (!failed) return;
      final url = p['url'];
      if (url is! String) return;
      final uri = Uri.tryParse(url);
      if (uri == null) return;
      final looksImage = _imagePath.hasMatch(uri.path) ||
          (_mimeOf(p['responseHeaders'])?.startsWith('image/') ?? false);
      if (!looksImage) return;
      recordImageFailure(
        uri,
        statusCode: status is int ? status : null,
        detail: p['error'] is String ? p['error']! as String : null,
      );
    } on Object {
      // Observar jamás debe tumbar a la app.
    }
  }

  static String? _mimeOf(Object? headers) {
    if (headers is! Map) return null;
    for (final MapEntry(:key, :value) in headers.entries) {
      if ('$key'.toLowerCase() == 'content-type') {
        return '$value'.toLowerCase();
      }
    }
    return null;
  }

  /// Una imagen no cargó. Se llama desde la excepción de imagen
  /// (`ErrorCapture`) y desde la capa de red; la misma URL se graba una
  /// sola vez en [_imageDedupeMs].
  static void recordImageFailure(
    Uri? uri, {
    int? statusCode,
    String? detail,
    StackTrace? stack,
  }) {
    final core = ThorCore.instance;
    if (core == null) return;
    final key = uri == null ? null : '${uri.host}${uri.path}';
    final now = nowMs();
    if (key != null) {
      final last = _recentImages[key];
      if (last != null && now - last < _imageDedupeMs) return;
      _recentImages[key] = now;
      if (_recentImages.length > 50) {
        _recentImages.removeWhere((_, at) => now - at >= _imageDedupeMs);
      }
    }
    final url = uri == null ? null : core.redaction.scrub(uri.toString());
    final why = statusCode != null
        ? 'HTTP $statusCode'
        : (detail == null || detail.isEmpty ? 'sin respuesta' : detail);
    ErrorCapture.recordSignal(
      source: 'image_error',
      type: 'ImageLoadError',
      message: 'Imagen no cargó ($why)${url == null ? '' : ': $url'}',
      extra: {
        if (url != null) 'url': url,
        if (statusCode != null) 'statusCode': statusCode,
      },
      stack: stack,
    );
  }

  // ── Recorrido ──

  static const _messageNames = {
    'AlertDialog',
    'SimpleDialog',
    'CupertinoAlertDialog',
    'CupertinoActionSheet',
    'SnackBar',
    'MaterialBanner',
  };

  /// Diálogos del framework que MATCHEAN `*Dialog` pero son selectores, no
  /// mensajes (su texto son los días del calendario).
  static const _messageDenylist = {
    'DatePickerDialog',
    'DateRangePickerDialog',
    'TimePickerDialog',
    'AboutDialog',
    'CalendarDatePicker',
  };

  static const _buttonNames = {
    'TextButton',
    'ElevatedButton',
    'OutlinedButton',
    'FilledButton',
    'IconButton',
    'CupertinoButton',
    'CupertinoDialogAction',
    'CupertinoActionSheetAction',
    'SnackBarAction',
    'InkWell',
    'ListTile',
  };

  static bool _isMessage(String name) =>
      _messageNames.contains(name) ||
      (!_messageDenylist.contains(name) &&
          (name.endsWith('Toast') ||
              name.endsWith('Dialog') ||
              name.endsWith('Snackbar')));

  static _Walk _walk() {
    final walk = _Walk();
    final root = WidgetsBinding.instance.rootElement;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (root == null || views.isEmpty) return walk;
    final view = views.first;
    final screenRect =
        Offset.zero & (view.physicalSize / view.devicePixelRatio);

    void visit(Element element) {
      final ro = element.renderObject;
      if (ro != null && VisibleTree.isHidden(ro)) return;
      final widget = element.widget;
      final name = VisibleTree.typeName(widget);
      // La propia UI de Thor (burbuja, toast) no es de la app.
      if (name.startsWith('Thor')) return;

      if (!walk.loading && _isLoadingWidget(widget, name)) {
        if (ro is RenderBox && ro.hasSize && ro.attached) {
          final rect = MatrixUtils.transformRect(
            ro.getTransformTo(null),
            Offset.zero & ro.size,
          );
          if (rect.overlaps(screenRect)) walk.loading = true;
        } else {
          // Un esqueleto sin caja propia: cuenta si está en el árbol pintado.
          walk.loading = true;
        }
      }
      if (ro is RenderParagraph || ro is RenderImage || ro is RenderEditable) {
        walk.content++;
      } else if (ro != null && _isPlatformView(ro)) {
        walk.platformView = true;
      }

      if (_isMessage(name)) {
        final text = _textOf(element);
        if (text.isNotEmpty) walk.messages.add(_Msg(name, text));
        // Lo de adentro ya se leyó; sigue contando como contenido.
        element.visitChildElements(
          (child) => _count(child, walk),
        );
        return;
      }
      VisibleTree.visitChildren(element, visit);
    }

    root.visitChildElements(visit);
    return walk;
  }

  /// Cuenta contenido y vistas nativas bajo un mensaje, sin buscar más
  /// mensajes (el más externo gana: un `AlertDialog` contiene un `Dialog`).
  static void _count(Element element, _Walk walk) {
    final ro = element.renderObject;
    if (ro != null && VisibleTree.isHidden(ro)) return;
    if (ro is RenderParagraph || ro is RenderImage || ro is RenderEditable) {
      walk.content++;
    }
    element.visitChildElements((child) => _count(child, walk));
  }

  static bool _isLoadingWidget(Widget widget, String name) {
    if (widget is CircularProgressIndicator) return widget.value == null;
    if (widget is LinearProgressIndicator) return widget.value == null;
    if (widget is CupertinoActivityIndicator) return widget.animating;
    return name.contains('Shimmer') || name.contains('Skeleton');
  }

  static bool _isPlatformView(RenderObject ro) {
    final name = VisibleTree.runtimeName(ro);
    return name.contains('PlatformView') ||
        name.contains('UiKitView') ||
        name.contains('AndroidView') ||
        name.contains('AppKitView');
  }

  /// Los textos del mensaje (título y cuerpo; sin las etiquetas de sus
  /// botones), unidos con « · » y recortados.
  static String _textOf(Element root) {
    final parts = <String>[];
    void find(Element e) {
      if (parts.length >= 5) return;
      final w = e.widget;
      final name = VisibleTree.typeName(w);
      if (_buttonNames.contains(name)) return;
      if (w is Text) {
        final t = (w.data ?? w.textSpan?.toPlainText())?.trim() ?? '';
        if (t.isNotEmpty && !parts.contains(t)) parts.add(t);
        return;
      }
      e.visitChildElements(find);
    }

    root.visitChildElements(find);
    final text = parts.join(' · ').replaceAll(RegExp(r'\s+'), ' ');
    return text.length <= 300 ? text : '${text.substring(0, 300)}…';
  }
}

class _Walk {
  bool loading = false;
  bool platformView = false;
  int content = 0;
  final List<_Msg> messages = [];
}

class _Msg {
  const _Msg(this.widget, this.text);
  final String widget;
  final String text;
}
