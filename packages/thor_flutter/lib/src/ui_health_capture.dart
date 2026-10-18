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
/// - **Excepción cruda en pantalla** → `error` con `source: ui_error`, `type:
///   RawExceptionText`: un `Text` visible cuyo contenido es una excepción
///   (`(error) FormatException: Unexpected end of input`, `Null check
///   operator…`): el usuario ve un mensaje de desarrollador porque la app
///   puso `e.toString()` en la UI.
/// - **Respuesta 200 vacía** → `error` con `source: empty_response`: un GET
///   que contestó 200 sin cuerpo (la pantalla se queda vacía o revienta al
///   decodificar). Una vez por ruta y con tope por sesión.
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
    _imageErrorsInWindow = 0;
    _imageWindowStart = 0;
    _rawShown.clear();
    _permShown.clear();
    _emptyReported.clear();
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
    _checkRawErrors(walk);
    _checkInlinePermission(walk);

    _watching = walk.loading ||
        (_blankSince != null && !_blankReported) ||
        walk.messages.isNotEmpty ||
        walk.rawErrors.isNotEmpty ||
        walk.permissionTexts.isNotEmpty;
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

  /// Textos de excepción visibles en el último recorrido: se reporta uno al
  /// aparecer; si se va y vuelve, otra vez.
  static final Set<String> _rawShown = {};

  static void _checkRawErrors(_Walk walk) {
    final now = <String>{};
    for (final text in walk.rawErrors) {
      now.add(text);
      if (_rawShown.contains(text)) continue;
      final core = ThorCore.instance;
      if (core == null) continue;
      try {
        final clean = core.redaction.scrub(text);
        ErrorCapture.recordSignal(
          source: 'ui_error',
          type: 'RawExceptionText',
          message: 'Texto de excepción visible en pantalla: «$clean»',
          extra: {'text': clean, 'kind': 'raw_exception'},
        );
      } on Object {
        // Observar jamás debe tumbar a la app.
      }
    }
    _rawShown
      ..clear()
      ..addAll(now);
  }

  /// ¿[text] es una excepción cruda (lo que sale de `e.toString()`) y no
  /// copy escrito para el usuario? Visible para tests.
  @visibleForTesting
  static bool looksLikeRawException(String text) =>
      _rawException.hasMatch(text);

  static final _rawException = RegExp(
    r'^\s*\(error\)|'
    r'\b[A-Z][A-Za-z]*(Exception|Error)\b(?!\w)|'
    r'\bException:\s|'
    "type '[^']+' is not a subtype of type|"
    'Null check operator used on a null value|'
    r"\bInstance of '|"
    'Unexpected end of input|'
    'Unhandled Exception',
  );

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
      // Un diálogo/snackbar que dice que falta un permiso («Permite el
      // micrófono…») deja además su evento `permission`.
      _notePermission(core, text);
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
          // Una pista del sistema («Espera la señal para hablar») no es un
          // problema de pantalla: el dash puede no listarla como tal.
          if (looksTransient(text)) 'transient': true,
        });
      }
    } on Object {
      // Observar jamás debe tumbar a la app.
    }
  }

  static final _transientWords = RegExp(
    'espera la se[ñn]al|escuchando|habla ahora|di algo|listening|speak now|'
    'tap to speak|grabando|recording',
    caseSensitive: false,
  );

  /// Si el texto es una pista pasajera del sistema (escuchando, grabando),
  /// no un problema. Un texto que además parece fallo nunca es pasajero.
  @visibleForTesting
  static bool looksTransient(String text) =>
      _transientWords.hasMatch(text) && !looksLikeError(text);

  static final _deniedUi = RegExp(
    'denegad|denied|rechaz|sin permiso|no (tienes|hay|se tiene) permiso|'
    'permite |habilita |not allowed|enable |allow ',
    caseSensitive: false,
  );

  /// Si [text] —un mensaje o un `Text` suelto en pantalla— dice que falta
  /// un permiso de un recurso concreto: lo anota como `permission` denegado
  /// con `source: ui`. Devuelve el recurso o `null`.
  static String? _notePermission(ThorCore core, String text) {
    if (!_deniedUi.hasMatch(text)) return null;
    final kind = ThorCore.permissionKindFromText(text);
    if (kind != null) core.permission(kind, after: 'denied', source: 'ui');
    return kind;
  }

  /// Texto suelto que dice «Permiso de cámara denegado»: la app lo pinta
  /// en línea (sin diálogo), así que solo el árbol lo ve.
  static final Set<String> _permShown = {};

  static void _checkInlinePermission(_Walk walk) {
    final now = <String>{};
    for (final text in walk.permissionTexts) {
      now.add(text);
      if (_permShown.contains(text)) continue;
      final core = ThorCore.instance;
      if (core == null) continue;
      try {
        final clean = core.redaction.scrub(text);
        if (_notePermission(core, clean) == null) continue;
        core.recorder.record(ThorEventKind.environment, {
          'signal': 'ui_message',
          'widget': 'Text',
          'text': clean,
        });
      } on Object {
        // Observar jamás debe tumbar a la app.
      }
    }
    _permShown
      ..clear()
      ..addAll(now);
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

  /// GET → 200 sin cuerpo ya reportados (host+ruta), y tope por sesión.
  static final Set<String> _emptyReported = {};
  static const _maxEmptyReports = 5;

  static void _checkEmptyResponse(Map<String, Object?> p) {
    if (p['method'] != 'GET' || p['statusCode'] != 200) return;
    if (p['error'] != null || p.containsKey('responseBody')) return;
    final bytes = p['responseBytes'];
    if (bytes is int && bytes > 0) return;
    final url = p['url'];
    final uri = url is String ? Uri.tryParse(url) : null;
    if (uri == null) return;
    // Una imagen o un asset vacío ya sale por `image_error`/no importa aquí.
    if (_imagePath.hasMatch(uri.path)) return;
    if (_mimeOf(p['responseHeaders'])?.startsWith('image/') ?? false) return;
    final key = '${uri.host}${uri.path}';
    if (_emptyReported.length >= _maxEmptyReports ||
        !_emptyReported.add(key)) {
      return;
    }
    ErrorCapture.recordSignal(
      source: 'empty_response',
      type: 'EmptyResponse',
      message: 'GET $key respondió 200 sin cuerpo',
      extra: {'url': url, 'statusCode': 200},
    );
  }

  static void _onEvent(ThorEvent event) {
    if (event.kind != ThorEventKind.network) return;
    try {
      final p = event.payload;
      _checkEmptyResponse(p);
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

  static int _imageErrorsInWindow = 0;
  static int _imageWindowStart = 0;

  /// Tope de imágenes rotas distintas grabadas por ventana de
  /// [_imageDedupeMs]: una cuadrícula con el CDN caído no debe volverse
  /// cientos de errores.
  static const _maxImageErrorsPerWindow = 10;

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
    if (now - _imageWindowStart >= _imageDedupeMs) {
      _imageWindowStart = now;
      _imageErrorsInWindow = 0;
    }
    if (_imageErrorsInWindow >= _maxImageErrorsPerWindow) return;
    if (key != null) {
      final last = _recentImages[key];
      if (last != null && now - last < _imageDedupeMs) return;
      _recentImages[key] = now;
      _imageErrorsInWindow++;
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
        if (ro is RenderParagraph && walk.permissionTexts.length < 3) {
          final text =
              ro.text.toPlainText(includeSemanticsLabels: false).trim();
          if (text.length >= 8 &&
              text.length <= 200 &&
              _deniedUi.hasMatch(text) &&
              ThorCore.permissionKindFromText(text) != null &&
              !walk.permissionTexts.contains(text)) {
            walk.permissionTexts.add(text);
          }
        }
        if (ro is RenderParagraph && walk.rawErrors.length < 3) {
          final text = ro.text.toPlainText(includeSemanticsLabels: false);
          if (text.length >= 8 &&
              text.length <= 600 &&
              looksLikeRawException(text) &&
              !walk.rawErrors.contains(text.trim())) {
            walk.rawErrors.add(text.trim());
          }
        }
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
        name.contains('AppKitView') ||
        // Cámara / escáner (`Texture`): el contenido vive en la GPU, no en
        // el árbol de Flutter; con solo un título encima no es «en blanco».
        name.contains('TextureBox');
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
  final List<String> rawErrors = [];
  final List<String> permissionTexts = [];
}

class _Msg {
  const _Msg(this.widget, this.text);
  final String widget;
  final String text;
}
