/// Tipos de interacción (`payload.gesture` de `ThorEventKind.interaction`).
///
/// Los de PUNTERO los graba `InteractionCapture`; `scrollUp`, `increase`…
/// vienen de acciones semánticas (lector de pantalla, arneses).
abstract final class ThorGesture {
  /// Toque corto.
  static const tap = 'tap';

  /// Toque sostenido (≥ 500 ms sin moverse).
  static const longPress = 'long_press';

  /// Arrastre que empezó sobre una lista/página desplazable (`axis`,
  /// `dir`, `distance`, `start`, `end`, `durationMs`).
  static const scroll = 'scroll';

  /// Arrastre que NO empezó sobre algo desplazable (descartar, carrusel
  /// propio, gesto del dibujo…).
  static const swipe = 'swipe';

  /// Arrastre horizontal desde el borde de la pantalla: el gesto de
  /// "atrás" de iOS (`edge`: `left`/`right`).
  static const edgeSwipe = 'edge_swipe';

  /// Un campo de texto recibió el foco (se abre el teclado). Lleva la
  /// etiqueta del campo; el texto escrito JAMÁS se captura.
  static const textFocus = 'text_focus';

  /// Se terminó de editar un campo de texto (perdió el foco tras cambiar):
  /// `length` final, `startLength`, `empty`, `edits` (cambios), y `source`
  /// (`typed` / `pasted_or_scanned`) si el texto es largo. NUNCA el
  /// contenido.
  static const textEdit = 'text_edit';

  /// ¿Es un toque (corto o sostenido)? Lo que cuenta para "qué tocó",
  /// ráfagas de frustración y la receta de reproducción. `null` (eventos
  /// de versiones anteriores) y los semánticos equivalentes también.
  static bool isPress(Object? gesture) =>
      gesture == null ||
      gesture == tap ||
      gesture == longPress ||
      gesture == 'longPress';
}
