import 'package:thor/src/model/event.dart';

/// Narrador: convierte la línea de tiempo en pasos de reproducción en
/// lenguaje natural — el bloque que QA pega en el ticket sin redactar nada.
///
/// Ejemplo de salida:
/// ```text
/// 1. Abrió CheckoutPage
/// 2. Tocó «Cobrar» (ElevatedButton)
///    → POST /orders  500  (2100 ms)
///    ✗ StateError en package:app/checkout.dart:142
/// ```
///
/// Reglas: navegación e interacción abren paso numerado; red y errores se
/// anidan bajo el paso activo (son consecuencia, no acción del usuario);
/// el estado (bloc) solo aparece cuando termina en error — el resto es
/// ruido para un humano y vive completo en el timeline JSON.
class ThorNarrator {
  const ThorNarrator._();

  /// Genera los pasos desde [timeline] (ya ordenada por seq).
  static String narrate(List<ThorEvent> timeline) {
    final lines = <String>[];
    var step = 0;

    void numbered(String text) {
      step++;
      lines.add('$step. $text');
    }

    void nested(String text) {
      // Sin paso previo (evento antes de la primera acción): se promueve.
      if (step == 0) {
        numbered(text);
      } else {
        lines.add('   $text');
      }
    }

    for (final event in timeline) {
      switch (event.kind) {
        case ThorEventKind.navigation:
          final action = event.payload['action'];
          final to = event.payload['to'] ?? event.screen?.display ?? '?';
          numbered(
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
              label == null ? 'Tocó un campo de texto' : 'Llenó «$label»',
            );
          } else {
            numbered(
              label == null ? 'Tocó $widget' : 'Tocó «$label» ($widget)',
            );
          }
        case ThorEventKind.network:
          final method = event.payload['method'] ?? '?';
          final path = _pathOf(event.payload['url']);
          final status = event.payload['statusCode'];
          final error = event.payload['error'];
          final ms = event.payload['durationMs'];
          final verdict = error != null
              ? '✗ $error'
              : (status is int && status >= 400 ? '$status ✗' : '$status');
          nested('→ $method $path  $verdict  (${ms}ms)');
        case ThorEventKind.error:
          final type = event.payload['type'] ?? 'Error';
          final origin = event.origin;
          nested('✗ $type${origin == null ? '' : ' en $origin'}');
        case ThorEventKind.state:
          // Solo transiciones HACIA estados con pinta de fallo.
          final to = event.payload['to'];
          if (to is String && _looksLikeFailure(to)) {
            nested('· ${event.payload['bloc']}: → $to');
          }
        case ThorEventKind.environment:
          final signal = event.payload['signal'];
          if (signal == 'lifecycle') {
            final state = event.payload['state'];
            if (state == 'paused') nested('· App al fondo');
            if (state == 'resumed') nested('· App de regreso');
          } else {
            nested('· ${event.payload}');
          }
        case ThorEventKind.log:
          final label = event.payload['label'];
          if (label != null) nested('· marca: $label');
        case ThorEventKind.performance:
          break; // agregados, no narrativa
      }
    }
    return lines.join('\n');
  }

  static bool _looksLikeFailure(String state) {
    final lower = state.toLowerCase();
    return lower.contains('error') ||
        lower.contains('failure') ||
        lower.contains('fail') ||
        lower.contains('fallo');
  }

  static String _pathOf(Object? url) {
    if (url is! String) return '?';
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    return uri.path.isEmpty ? '/' : uri.path;
  }
}
