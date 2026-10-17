import 'dart:math';

import 'package:clock/clock.dart';

import 'package:thor/src/model/event.dart';
import 'package:thor/src/model/log_level.dart';
import 'package:thor/src/store/capture_policy.dart';
import 'package:thor/src/store/event_store.dart';
import 'package:thor/src/util/failure_name.dart';

/// Firma de un listener de eventos recién grabados (persistencia, overlay,
/// MCP se cuelgan aquí).
typedef ThorEventListener = void Function(ThorEvent event);

/// El grabador central: asigna secuencia, estampa tiempo/pantalla y reparte
/// el evento al almacén y a los listeners.
///
/// Los adaptadores (navegación, red, bloc…) NUNCA construyen [ThorEvent]
/// directamente — pasan por [record] para que la envoltura común (seq,
/// pantalla activa, UTC+offset) sea consistente en toda la línea de tiempo.
class ThorRecorder {
  /// Crea un grabador sobre [store].
  ///
  /// [policy] fija el tope de ráfagas de estado; el default es el
  /// recomendado ([ThorCapturePolicy]).
  ThorRecorder({
    required this.store,
    ThorCapturePolicy policy = const ThorCapturePolicy(),
  })  : _stateBursts = policy.stateBurstLimit <= 0
            ? null
            : BurstLimiter(
                limit: policy.stateBurstLimit,
                window: policy.stateBurstWindow,
                summaryEvery: policy.burstSummaryEvery,
              ),
        _logBursts = policy.logBurstLimit <= 0
            ? null
            : BurstLimiter(
                limit: policy.logBurstLimit,
                window: policy.logBurstWindow,
                summaryEvery: policy.burstSummaryEvery,
              );

  /// Almacén en memoria de la sesión.
  final EventStore store;

  final List<ThorEventListener> _listeners = [];
  int _seq = 0;

  /// Tope de ráfagas de estado por bloc+acción; `null` = sin tope.
  final BurstLimiter? _stateBursts;

  /// Último estado descartado de cada ráfaga abierta y la pantalla donde
  /// pasó: el resumen sale después (quizá en otra pantalla) y sin esto la
  /// línea de tiempo callaría el estado FINAL del bloc.
  final Map<String, ({Object? to, ScreenId? screen})> _lastDropped = {};

  /// Tope de ráfagas de log por origen+cupo; `null` = sin tope.
  final BurstLimiter? _logBursts;

  /// Nivel más alto descartado de cada ráfaga de log abierta: el resumen
  /// declara si lo recortado incluía warnings.
  final Map<String, ThorLogLevel> _logDroppedLevel = {};

  /// Pantalla activa. La mantienen los adaptadores de navegación
  /// (o `Thor.setScreen` para navegación que el Navigator no ve).
  ScreenId? currentScreen;

  /// Silencio SELECTIVO: mientras es `true` no se graban navegación ni
  /// interacciones — lo que el inspector en pantalla genera al usarse y
  /// que contaminaría la línea de tiempo que muestra. Red, errores, estado
  /// y entorno SIGUEN grabándose: la app de fondo (sync, sockets) no deja
  /// de trabajar porque QA esté mirando el panel, y perder ESO sí sería
  /// perder evidencia.
  bool muted = false;

  static const _mutedKinds = {
    ThorEventKind.navigation,
    ThorEventKind.interaction,
  };

  /// Graba un evento de [kind] con [payload]. Devuelve `null` si el
  /// grabador está silenciado ([muted]) y la familia es silenciable, o si
  /// es un evento de estado recortado por el tope de ráfagas (queda
  /// contado en un resumen `action: 'burst'`).
  ///
  /// [origin] es el `archivo:línea` de la app que disparó el evento;
  /// [screenOverride] fuerza la pantalla (para eventos retro-corregidos).
  ThorEvent? record(
    ThorEventKind kind,
    Map<String, Object?> payload, {
    String? origin,
    ScreenId? screenOverride,
  }) {
    if (muted && _mutedKinds.contains(kind)) return null;
    final now = clock.now();
    final bursts = _stateBursts;
    if (bursts != null) {
      // Los resúmenes vencidos salen ANTES del evento que los destapa:
      // así la línea de tiempo queda en orden.
      if (bursts.hasPending) _emitBurstSummaries(bursts.due(now), now);
      if (kind == ThorEventKind.state && !_exemptFromBurst(payload)) {
        final key = '${payload['bloc']}|${payload['action']}';
        if (!bursts.allow(key, now)) {
          _lastDropped[key] = (to: payload['to'], screen: currentScreen);
          return null;
        }
      }
    }
    final logs = _logBursts;
    if (logs != null) {
      if (logs.hasPending) _emitLogSummaries(logs.due(now), now);
      // Solo las líneas de log (con `level`); las marcas de `Thor.mark`
      // las pone la app a mano y nunca se recortan.
      final level = kind == ThorEventKind.log
          ? ThorLogLevel.tryParse(payload['level'])
          : null;
      if (level != null && payload['burst'] != true) {
        // Cupo aparte para warn/error: mil `print` de debug no deben
        // tapar el único warning que explica el bug.
        final key = '${payload['source']}|${level.isHigh ? 'high' : 'low'}';
        if (!logs.allow(key, now)) {
          final prev = _logDroppedLevel[key];
          if (prev == null || level.index > prev.index) {
            _logDroppedLevel[key] = level;
          }
          return null;
        }
      }
    }
    return _emit(kind, payload, now, origin: origin, screen: screenOverride);
  }

  ThorEvent _emit(
    ThorEventKind kind,
    Map<String, Object?> payload,
    DateTime now, {
    String? origin,
    ScreenId? screen,
  }) {
    final event = ThorEvent(
      seq: _seq++,
      kind: kind,
      atUtc: now.toUtc(),
      utcOffset: now.timeZoneOffset,
      screen: screen ?? currentScreen,
      origin: origin,
      payload: payload,
    );
    store.add(event);
    // Copia defensiva: un listener puede (des)suscribirse durante el reparto.
    for (final listener in List<ThorEventListener>.of(_listeners)) {
      listener(event);
    }
    return event;
  }

  /// Una transición HACIA un estado de fallo nunca se recorta: es la línea
  /// de estado que explica el bug, aunque el bloc sea charlatán.
  static bool _exemptFromBurst(Map<String, Object?> payload) {
    final to = switch (payload['to']) {
      final String s => s,
      final Map<Object?, Object?> m => m['type'],
      _ => null,
    };
    return to is String && looksLikeFailureName(to);
  }

  void _emitBurstSummaries(List<BurstSummary> summaries, DateTime now) {
    final limiter = _stateBursts!;
    for (final s in summaries) {
      final sep = s.key.lastIndexOf('|');
      final last = _lastDropped.remove(s.key);
      _emit(
        ThorEventKind.state,
        {
          'bloc': s.key.substring(0, sep),
          'action': 'burst',
          'burstOf': s.key.substring(sep + 1),
          'dropped': s.dropped,
          'limit': limiter.limit,
          'windowMs': limiter.window.inMilliseconds,
          'spanMs': s.lastDropAt.difference(s.firstDropAt).inMilliseconds,
          if (last?.to != null) 'lastTo': last!.to,
        },
        now,
        screen: last?.screen,
      );
    }
  }

  /// Resumen de líneas de log recortadas: un evento de log más (con
  /// `burst: true`) para que el journal, el narrador y el replay lo traten
  /// como cualquier línea de su nivel.
  void _emitLogSummaries(List<BurstSummary> summaries, DateTime now) {
    final limiter = _logBursts!;
    for (final s in summaries) {
      final source = s.key.substring(0, s.key.lastIndexOf('|'));
      final level = _logDroppedLevel.remove(s.key) ?? ThorLogLevel.debug;
      _emit(
        ThorEventKind.log,
        {
          'level': level.name,
          'source': source,
          'message': '${s.dropped} líneas de $source recortadas '
              '(más de ${limiter.limit} en '
              '${limiter.window.inMilliseconds}ms)',
          'burst': true,
          'dropped': s.dropped,
          'limit': limiter.limit,
          'windowMs': limiter.window.inMilliseconds,
          'spanMs': s.lastDropAt.difference(s.firstDropAt).inMilliseconds,
        },
        now,
      );
    }
  }

  /// Emite ya los resúmenes de ráfagas pendientes (aunque la ráfaga siga
  /// abierta). Se llama antes de un reporte y al cerrar la sesión: un
  /// conteo de descartes que nunca se escribe es un hallazgo perdido.
  void flushBursts() {
    final now = clock.now();
    final bursts = _stateBursts;
    if (bursts != null && bursts.hasPending) {
      _emitBurstSummaries(bursts.due(now, all: true), now);
    }
    final logs = _logBursts;
    if (logs != null && logs.hasPending) {
      _emitLogSummaries(logs.due(now, all: true), now);
    }
  }

  /// Suscribe un [listener] a todo evento grabado. Devuelve la función que
  /// cancela la suscripción.
  void Function() addListener(ThorEventListener listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Última secuencia asignada (para `sinceSeq` en consultas).
  int get lastSeq => _seq - 1;
}

/// Genera IDs cortos, únicos y sin dependencias (no es UUID a propósito:
/// legible en logs y suficiente como llave de correlación).
String generateThorId() {
  final random = Random.secure();
  const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final body =
      List.generate(10, (_) => alphabet[random.nextInt(alphabet.length)])
          .join();
  final ts = clock.now().toUtc().millisecondsSinceEpoch.toRadixString(36);
  return '$ts-$body';
}
