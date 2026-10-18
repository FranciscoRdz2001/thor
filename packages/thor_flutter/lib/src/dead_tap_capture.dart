import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:thor/thor.dart';

/// Toque sin efecto: el usuario tocó un botón y no pasó NADA.
///
/// Es el reporte de QA más difícil de tipificar ("le piqué y no hizo
/// nada"): no hay excepción, ni petición, ni navegación. Tras un toque en un
/// botón, [wait] después se mira la línea de tiempo: si no hubo navegación,
/// petición, cambio de estado, error ni mensaje, el toque no hizo nada.
///
/// Anti-ruido (un botón puede hacer solo un `setState` visual y eso Thor no
/// lo ve): solo se reporta con evidencia de que el usuario lo notó —
/// el botón está DESHABILITADO (`onPressed: null`) o el usuario lo volvió a
/// tocar ([retapWithin]) sin efecto en medio. Una vez por botón y con tope
/// por sesión ([maxPerSession]). Sin trabajo por frame: un `Timer` por
/// toque a botón.
class DeadTapCapture {
  DeadTapCapture._();

  /// Apagado en las pruebas de widgets de la app (`FLUTTER_TEST`): el
  /// `Timer` de espera dejaría "timers pendientes" en tests que solo
  /// tocaron un botón. Las pruebas de Thor lo encienden a propósito.
  @visibleForTesting
  static bool enabled = !Platform.environment.containsKey('FLUTTER_TEST');

  /// Cuánto se espera un efecto tras el toque.
  static Duration wait = const Duration(seconds: 1);

  /// Segundo toque al mismo botón dentro de este plazo = "no me hizo caso".
  static Duration retapWithin = const Duration(seconds: 4);

  /// Tope de toques muertos reportados por sesión.
  static const maxPerSession = 10;

  /// Botones de acción: una acción esperada, no un interruptor visual.
  static const buttonTypes = {
    'ElevatedButton',
    'TextButton',
    'OutlinedButton',
    'FilledButton',
    'IconButton',
    'FloatingActionButton',
    'CupertinoButton',
  };

  static final Expando<_State> _state = Expando();

  /// Qué eventos cuentan como "algo pasó" tras el toque.
  static bool _isEffect(ThorEvent e) {
    switch (e.kind) {
      case ThorEventKind.navigation:
      case ThorEventKind.network:
      case ThorEventKind.state:
      case ThorEventKind.error:
      case ThorEventKind.storage:
      case ThorEventKind.track:
        return true;
      case ThorEventKind.environment:
        final signal = e.payload['signal'];
        return signal == 'ui_message' ||
            signal == 'screen_context' ||
            signal == 'permission' ||
            signal == 'system_overlay' ||
            signal == 'external_surface' ||
            signal == 'lifecycle';
      case ThorEventKind.interaction:
        // Otro toque o el foco de un campo no es el efecto del primero.
        return false;
      case ThorEventKind.performance:
        return e.payload['kind'] == 'screen_load';
      case ThorEventKind.log:
        return false;
    }
  }

  /// Un toque a [widgetType] con [label] quedó grabado como [tap]. Llamado
  /// por `InteractionCapture`; no hace nada si no es un botón de acción.
  static void onTap(
    ThorCore core,
    ThorEvent tap, {
    required String widgetType,
    String? label,
    bool disabled = false,
  }) {
    if (!enabled || !buttonTypes.contains(widgetType)) return;
    final st = _state[core] ??= _State();
    final screen = core.recorder.currentScreen?.display;
    final key = '$widgetType|${label ?? ''}|$screen';
    final now = tap.atUtc;
    final prev = st.lastTap[key];
    st.lastTap[key] = (seq: tap.seq, at: now);
    if (st.lastTap.length > 64) st.lastTap.clear();
    // Reintento: el toque ANTERIOR al mismo botón ya es sospechoso si
    // tampoco hubo efecto entre los dos.
    final retap = prev != null &&
        now.difference(prev.at) <= retapWithin &&
        !_effectBetween(core, prev.seq, tap.seq);
    Timer(wait, () {
      try {
        _check(
          core,
          tap,
          key,
          widgetType,
          label,
          disabled: disabled,
          retap: retap,
        );
      } on Object {
        // Observar jamás debe tumbar a la app.
      }
    });
  }

  static bool _effectBetween(ThorCore core, int fromSeq, int toSeq) {
    for (final kind in ThorEventKind.values) {
      for (final e in core.store.ofKind(kind)) {
        if (e.seq > fromSeq && e.seq < toSeq && _isEffect(e)) return true;
      }
    }
    return false;
  }

  static void _check(
    ThorCore core,
    ThorEvent tap,
    String key,
    String widgetType,
    String? label, {
    required bool disabled,
    required bool retap,
  }) {
    // La sesión se renovó o Thor se apagó: ya no hay a quién avisarle.
    if (!identical(ThorCore.instance, core)) return;
    if (!disabled && !retap) return;
    if (_effectBetween(core, tap.seq, 1 << 40)) return;
    final st = _state[core];
    if (st == null) return;
    if (st.reported.length >= maxPerSession || !st.reported.add(key)) return;
    final name = label == null ? widgetType : '«$label» ($widgetType)';
    core.problem(
      'dead_tap',
      'DeadTap',
      disabled
          ? 'Toque en $name deshabilitado: no hizo nada'
          : 'Toque en $name sin efecto (repetido, sin navegación, '
              'petición ni cambio)',
      extra: {
        'widget': widgetType,
        if (label != null) 'label': label,
        'disabled': disabled,
        'waitMs': wait.inMilliseconds,
      },
    );
  }
}

class _State {
  final Map<String, ({int seq, DateTime at})> lastTap = {};
  final Set<String> reported = {};
}
