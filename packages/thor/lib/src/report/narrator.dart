import 'dart:convert';

import 'package:thor/src/model/event.dart';
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
          if (isInput) {
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
          nested(event, '✗ $type${origin == null ? '' : ' en $origin'}');
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
            case 'memoryPressure':
              nested(event, '⚠ Presión de memoria del sistema');
            case 'brightness':
              nested(event, '· Tema del sistema: ${event.payload['value']}');
            case 'user':
              final id = event.payload['id'];
              nested(
                event,
                id == null ? '· Sesión sin usuario' : '· Usuario: $id',
              );
            case 'textScale':
              nested(event, '· Escala de texto: ${event.payload['value']}');
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
        case ThorEventKind.performance:
          final slow = event.payload['slowFrames'];
          final worst = event.payload['worstMs'];
          nested(event, '⚠ Jank: $slow frames lentos (peor ${worst}ms)');
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
