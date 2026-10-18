import 'dart:convert';

import 'package:thor/src/model/event.dart';
import 'package:thor/src/model/gesture.dart';
import 'package:thor/src/model/log_level.dart';
import 'package:thor/src/util/failure_name.dart';

/// Narrador: convierte la línea de tiempo en pasos de reproducción en
/// lenguaje natural — el bloque que QA pega en el ticket sin redactar nada.
///
/// Ejemplo de salida:
/// ```text
/// 1. [+0.0s] Abrió CheckoutPage
/// 2. [+3.2s] Tocó «Cobrar» (ElevatedButton)
///    → POST /orders  500 ✗  (2100ms)
///      body: {"message":"turno cerrado"}
///      desde package:app/checkout.dart:142
///    ✗ StateError en package:app/checkout.dart:142
/// ```
///
/// Reglas: navegación e interacción abren paso numerado con su tiempo
/// relativo al inicio (el ritmo importa: "tocó dos veces en 1 s" ES el
/// bug); red y errores se anidan bajo el paso activo; las peticiones
/// FALLIDAS muestran el cuerpo de la respuesta (ya redactado) y el
/// `archivo:línea` que las disparó; el estado (bloc) solo aparece cuando
/// termina en fallo.
class ThorNarrator {
  const ThorNarrator._();

  static String _dirName(Object? dir) => switch (dir) {
        'up' => 'hacia arriba',
        'down' => 'hacia abajo',
        'left' => 'hacia la izquierda',
        'right' => 'hacia la derecha',
        _ => '',
      };

  /// Genera los pasos desde [timeline] (ya ordenada por seq).
  static String narrate(List<ThorEvent> timeline) {
    final lines = <String>[];
    var step = 0;
    final t0 = timeline.isEmpty ? null : timeline.first.atUtc;

    String rel(ThorEvent e) {
      final seconds = e.atUtc.difference(t0!).inMilliseconds / 1000;
      return '[+${seconds.toStringAsFixed(1)}s]';
    }

    void numbered(ThorEvent e, String text) {
      step++;
      lines.add('$step. ${rel(e)} $text');
    }

    void nested(ThorEvent e, String text) {
      // Sin paso previo (evento antes de la primera acción): se promueve.
      if (step == 0) {
        numbered(e, text);
      } else {
        lines.add('   $text');
      }
    }

    void detail(String text) => lines.add('     $text');

    for (final event in timeline) {
      switch (event.kind) {
        case ThorEventKind.navigation:
          final action = event.payload['action'];
          final to = event.payload['to'] ?? event.screen?.display ?? '?';
          numbered(
            event,
            switch (action) {
              'pop' => 'Regresó a $to',
              'replace' => 'Cambió a $to',
              _ => 'Abrió $to',
            },
          );
        case ThorEventKind.interaction:
          final label = event.payload['label'];
          final widget = event.payload['widget'] ?? '?';
          final isInput = event.payload['isTextInput'] == true;
          final gesture = event.payload['gesture'];
          final dir = _dirName(event.payload['dir']);
          final dist = event.payload['distance'];
          final far = dist is int ? ' $dist px' : '';
          if (gesture == ThorGesture.scroll) {
            numbered(event, 'Desplazó la pantalla $dir$far');
          } else if (gesture == ThorGesture.swipe) {
            numbered(event, 'Deslizó $dir$far');
          } else if (gesture == ThorGesture.edgeSwipe) {
            numbered(event, 'Deslizó desde el borde (gesto de atrás)');
          } else if (gesture == ThorGesture.textFocus) {
            nested(
              event,
              label == null
                  ? '· Teclado abierto en un campo de texto'
                  : '· Teclado abierto en «$label»',
            );
          } else if (gesture == ThorGesture.longPress) {
            numbered(
              event,
              label == null
                  ? 'Mantuvo presionado $widget'
                  : 'Mantuvo presionado «$label» ($widget)',
            );
          } else if (isInput) {
            numbered(
              event,
              label == null ? 'Tocó un campo de texto' : 'Llenó «$label»',
            );
          } else {
            numbered(
              event,
              label == null ? 'Tocó $widget' : 'Tocó «$label» ($widget)',
            );
          }
        case ThorEventKind.network:
          final method = event.payload['method'] ?? '?';
          final path = _pathOf(event.payload['url']);
          final status = event.payload['statusCode'];
          final error = event.payload['error'];
          final ms = event.payload['durationMs'];
          final failed = error != null || (status is int && status >= 400);
          final verdict =
              error != null ? '✗ $error' : (failed ? '$status ✗' : '$status');
          nested(event, '→ $method $path  $verdict  (${ms}ms)');
          if (failed) {
            // En un fallo, el cuerpo (ya redactado) suele traer el "por qué"
            // del backend, y el origin dice QUIÉN disparó la petición.
            final body = _bodySnippet(event.payload['responseBody']);
            if (body != null) detail('body: $body');
            if (event.origin != null) detail('desde ${event.origin}');
          }
        case ThorEventKind.error:
          final type = event.payload['type'] ?? 'Error';
          final origin = event.origin;
          final source = event.payload['source'];
          if (source == 'ui_error' || source == 'image_error') {
            // Lo que el USUARIO vio (diálogo, snackbar, imagen rota): el
            // mensaje es el dato, no el tipo.
            nested(event, '✗ ${_short('${event.payload['message'] ?? type}')}');
          } else {
            nested(event, '✗ $type${origin == null ? '' : ' en $origin'}');
          }
          final last = event.payload['lastAction'];
          if (last != null) detail('última acción: $last');
        case ThorEventKind.state:
          // Solo transiciones HACIA estados con pinta de fallo.
          final to = event.payload['to'];
          if (to is String && looksLikeFailureName(to)) {
            nested(event, '· ${event.payload['bloc']}: → $to');
          }
        case ThorEventKind.environment:
          switch (event.payload['signal']) {
            case 'lifecycle':
              final state = event.payload['state'];
              if (state == 'paused') nested(event, '· App al fondo');
              if (state == 'resumed') nested(event, '· App de regreso');
            case 'memory_pressure' || 'memoryPressure':
              // Al irse a segundo plano iOS lo avisa siempre: no es presión
              // real (ver EnvironmentCapture).
              if (event.payload['transition'] != true) {
                nested(event, '⚠ Presión de memoria del sistema');
              }
            case 'screen_context':
              final value = event.payload['value'];
              if (value != null) {
                nested(event, '· Contexto de pantalla: $value');
              }
            case 'brightness':
              nested(event, '· Tema del sistema: ${event.payload['value']}');
            case 'user':
              final id = event.payload['id'];
              nested(
                event,
                id == null ? '· Sesión sin usuario' : '· Usuario: $id',
              );
            case 'text_scale' || 'textScale':
              nested(event, '· Escala de texto: ${event.payload['value']}');
            case 'locale':
              nested(event, '· Idioma del sistema: ${event.payload['value']}');
            case 'ui_message':
              nested(
                event,
                '· ${event.payload['widget']}: '
                '«${_short('${event.payload['text'] ?? ''}')}»',
              );
            case 'connectivity':
              nested(
                event,
                event.payload['online'] == false
                    ? '⚠ Sin conexión (inferido de las peticiones)'
                    : '· Conexión restablecida',
              );
            default:
              nested(event, '· ${event.payload}');
          }
        case ThorEventKind.log:
          final label = event.payload['label'];
          if (label != null) {
            nested(event, '· marca: $label');
            break;
          }
          // Líneas de consola: las de debug son charla de desarrollo y
          // ahogarían los pasos; info/warn/error sí cuentan la historia.
          final level = ThorLogLevel.tryParse(event.payload['level']);
          if (level == null || level == ThorLogLevel.debug) break;
          final icon = switch (level) {
            ThorLogLevel.error => '✗',
            ThorLogLevel.warn => '⚠',
            _ => '·',
          };
          final message = '${event.payload['message'] ?? ''}';
          final short =
              message.length <= 160 ? message : '${message.substring(0, 160)}…';
          nested(event, '$icon log ${event.payload['source']}: $short');
          final error = event.payload['error'];
          if (error != null) detail('error: $error');
          final data = event.payload['data'];
          if (data != null) detail('data: ${_short(jsonEncode(data))}');
        case ThorEventKind.performance:
          final p = event.payload;
          switch (p['kind']) {
            case 'startup':
              nested(event, '· Arranque: ${p['ms']}ms hasta ${p['until']}');
            case 'screen_load':
              nested(
                event,
                p['interrupted'] == true
                    ? '· Carga de ${p['screen']}: ${p['ms']}ms '
                        '(interrumpida por el usuario)'
                    : '· Carga de ${p['screen']}: ${p['ms']}ms',
              );
            case 'anr':
              nested(
                event,
                '✗ ANR: la app no respondió ${p['ms']}ms en ${p['screen']}',
              );
            case 'freeze':
              nested(
                event,
                '✗ Congelada: un frame tardó ${p['ms']}ms en ${p['screen']}',
              );
            case 'custom':
              nested(event, '· ${p['name']}: ${p['ms']}ms');
            case 'stuck_loading':
              nested(
                event,
                '⚠ Cargando sin terminar ${p['ms']}ms en ${p['screen']}',
              );
            case 'blank_screen':
              nested(
                event,
                '⚠ Pantalla casi vacía ${p['ms']}ms en ${p['screen']}',
              );
            default:
              final slow = p['slow'] ?? p['slowFrames'];
              final worst = p['worstMs'];
              nested(event, '⚠ Jank: $slow frames lentos (peor ${worst}ms)');
          }
        case ThorEventKind.track:
          final props = event.payload['props'];
          final shown = props == null ? '' : ' ${_short(jsonEncode(props))}';
          numbered(event, '★ ${event.payload['name']}$shown');
        case ThorEventKind.storage:
          // Solo la cola entra en la narrativa: las escrituras sueltas son
          // ruido, la profundidad es la que cuenta la historia.
          if (event.payload['op'] == 'queue') {
            final action = event.payload['action'];
            nested(
              event,
              '· cola ${event.payload['queue']}: '
              '${event.payload['depth']} pendientes'
              '${action == null ? '' : ' ($action)'}',
            );
          }
      }
    }
    return lines.join('\n');
  }

  static String _short(String s) =>
      s.length <= 200 ? s : '${s.substring(0, 200)}…';

  static String _pathOf(Object? url) {
    if (url is! String) return '?';
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return uri.path.isEmpty ? '/' : uri.path;
  }

  /// Resumen de un cuerpo de respuesta ya redactado, apto para una línea.
  static String? _bodySnippet(Object? body) {
    if (body == null) return null;
    final text = body is String ? body : jsonEncode(body);
    if (text.isEmpty || text == '{}' || text == 'null') return null;
    return text.length <= 160 ? text : '${text.substring(0, 160)}…';
  }
}
