import 'package:thor/src/model/event.dart';
import 'package:thor/src/model/gesture.dart';

/// Agregados calculados sobre la línea de tiempo — las vistas que responden
/// preguntas sin volcar el crudo (un dump de 4000 líneas quema el contexto
/// de una IA y la paciencia de un dev).
class ThorAggregates {
  const ThorAggregates._();

  /// Peticiones por pantalla: conteo, fallidas y duración total.
  static Map<String, Map<String, Object?>> networkByScreen(
    List<ThorEvent> timeline,
  ) {
    final result = <String, Map<String, Object?>>{};
    for (final event in timeline) {
      if (event.kind != ThorEventKind.network) continue;
      final screen = event.screen?.display ?? '(sin pantalla)';
      final bucket = result.putIfAbsent(
        screen,
        () => {'count': 0, 'failed': 0, 'totalMs': 0},
      );
      bucket['count'] = (bucket['count']! as int) + 1;
      final status = event.payload['statusCode'];
      final failed =
          event.payload['error'] != null || (status is int && status >= 400);
      if (failed) bucket['failed'] = (bucket['failed']! as int) + 1;
      bucket['totalMs'] = (bucket['totalMs']! as int) +
          (event.payload['durationMs'] as int? ?? 0);
    }
    return result;
  }

  /// Duplicados sospechosos: misma método+URL disparada 2+ veces en la
  /// misma pantalla dentro de [window]. Es la firma del fetch dentro de
  /// `build()` — el bug que solo se cacha mirando el Network tab con lupa.
  static List<Map<String, Object?>> suspiciousDuplicates(
    List<ThorEvent> timeline, {
    Duration window = const Duration(seconds: 5),
  }) {
    final byKey = <String, List<ThorEvent>>{};
    for (final event in timeline) {
      if (event.kind != ThorEventKind.network) continue;
      final key = '${event.screen?.display}|${event.payload['method']} '
          '${event.payload['url']}';
      byKey.putIfAbsent(key, () => []).add(event);
    }
    final result = <Map<String, Object?>>[];
    for (final MapEntry(:key, value: events) in byKey.entries) {
      if (events.length < 2) continue;
      var burst = 1;
      var maxBurst = 1;
      for (var i = 1; i < events.length; i++) {
        final gap = events[i].atUtc.difference(events[i - 1].atUtc);
        burst = gap <= window ? burst + 1 : 1;
        if (burst > maxBurst) maxBurst = burst;
      }
      if (maxBurst >= 2) {
        result.add({
          'key': key,
          'total': events.length,
          'maxBurst': maxBurst,
          'screen': events.first.screen?.display,
          'origin': events.first.origin,
        });
      }
    }
    return result;
  }

  /// Jank por pantalla: frames lentos acumulados y el peor frame. QA
  /// reporta "va lento" sin evidencia; esto lo deja medido y ubicado.
  static Map<String, Map<String, Object?>> slowFramesByScreen(
    List<ThorEvent> timeline,
  ) {
    final result = <String, Map<String, Object?>>{};
    for (final event in timeline) {
      if (event.kind != ThorEventKind.performance) continue;
      // Solo jank: startup/screen_load/anr/custom no traen frames lentos.
      final kind = event.payload['kind'];
      if (kind != null && kind != 'jank') continue;
      final slowFrames = (event.payload['slow'] ?? event.payload['slowFrames'])
          as int?;
      final screen = event.screen?.display ?? '(sin pantalla)';
      final bucket = result.putIfAbsent(
        screen,
        () => {'slowFrames': 0, 'worstMs': 0},
      );
      bucket['slowFrames'] = (bucket['slowFrames']! as int) + (slowFrames ?? 0);
      final worst = event.payload['worstMs'] as int? ?? 0;
      if (worst > (bucket['worstMs']! as int)) bucket['worstMs'] = worst;
    }
    return result;
  }

  /// Toques repetidos al mismo objetivo en ráfaga: señal de frustración
  /// del usuario ("no responde") y casi siempre un bug — el botón no dio
  /// feedback, o disparó doble. Sale gratis de los datos que ya hay.
  static List<Map<String, Object?>> rageTaps(
    List<ThorEvent> timeline, {
    Duration window = const Duration(seconds: 2),
    int minTaps = 3,
  }) {
    final result = <Map<String, Object?>>[];
    final buffer = <ThorEvent>[];

    void flush() {
      if (buffer.length >= minTaps) {
        result.add({
          'target':
              buffer.first.payload['label'] ?? buffer.first.payload['widget'],
          'screen': buffer.first.screen?.display,
          'taps': buffer.length,
          'withinMs':
              buffer.last.atUtc.difference(buffer.first.atUtc).inMilliseconds,
          'firstSeq': buffer.first.seq,
        });
      }
      buffer.clear();
    }

    for (final event in timeline) {
      if (event.kind != ThorEventKind.interaction) continue;
      // Solo toques: tres desplazamientos seguidos no son frustración.
      if (!ThorGesture.isPress(event.payload['gesture'])) continue;
      final sameTarget = buffer.isNotEmpty &&
          buffer.last.payload['label'] == event.payload['label'] &&
          buffer.last.payload['widget'] == event.payload['widget'] &&
          event.atUtc.difference(buffer.last.atUtc) <= window;
      if (!sameTarget) flush();
      buffer.add(event);
    }
    flush();
    return result;
  }

  /// Blocs charlatanes: los que chocaron con el tope de ráfagas de estado
  /// (resúmenes `action: 'burst'` del grabador). Un bloc que emite un
  /// estado por scroll es un hallazgo de rendimiento — reconstruye y
  /// re-pinta de más — aunque nada falle.
  static List<Map<String, Object?>> noisyBlocs(List<ThorEvent> timeline) {
    final byKey = <String, Map<String, Object?>>{};
    final kept = <String, int>{};
    for (final event in timeline) {
      if (event.kind != ThorEventKind.state) continue;
      final bloc = event.payload['bloc'];
      final action = event.payload['action'];
      if (action != 'burst') {
        kept['$bloc|$action'] = (kept['$bloc|$action'] ?? 0) + 1;
        continue;
      }
      final of = event.payload['burstOf'];
      final entry = byKey.putIfAbsent(
        '$bloc|$of',
        () => {
          'bloc': bloc,
          'action': of,
          'dropped': 0,
          'screen': event.screen?.display,
        },
      );
      entry['dropped'] =
          (entry['dropped']! as int) + (event.payload['dropped'] as int? ?? 0);
      // Estado final que la ráfaga recortó (el resumen más reciente manda).
      final lastTo = event.payload['lastTo'];
      if (lastTo != null) entry['lastTo'] = lastTo;
    }
    return [
      for (final MapEntry(:key, :value) in byKey.entries)
        {...value, 'kept': kept[key] ?? 0},
    ]..sort(
        (a, b) => (b['dropped']! as int).compareTo(a['dropped']! as int),
      );
  }

  /// Usuario vigente al final de [timeline] (último `signal: 'user'`), o
  /// `null` si nunca se fijó o se limpió.
  static String? lastUserId(List<ThorEvent> timeline) {
    for (final event in timeline.reversed) {
      if (event.kind == ThorEventKind.environment &&
          event.payload['signal'] == 'user') {
        return event.payload['id'] as String?;
      }
    }
    return null;
  }

  /// Veredicto de una línea para encabezar el reporte: la conclusión
  /// primero, para que un dev (o una IA) no tenga que deducirla leyendo
  /// todos los pasos.
  static String verdict(List<ThorEvent> timeline) {
    if (timeline.isEmpty) return 'Sesión sin eventos.';
    var errors = 0;
    var failedRequests = 0;
    var requests = 0;
    final screens = <String>{};
    for (final e in timeline) {
      switch (e.kind) {
        case ThorEventKind.error:
          errors++;
        case ThorEventKind.network:
          requests++;
          final status = e.payload['statusCode'];
          if (e.payload['error'] != null || (status is int && status >= 400)) {
            failedRequests++;
          }
        case ThorEventKind.navigation:
          if (e.screen?.display != null) screens.add(e.screen!.display);
        // ignore: no_default_cases — el resto no aporta al veredicto.
        default:
          break;
      }
    }
    final duration = timeline.last.atUtc.difference(timeline.first.atUtc);
    // Una cola sin vaciar no es "sin errores": nada falló, pero el trabajo
    // del usuario tampoco salió del dispositivo.
    final stuck = stuckQueues(timeline);
    final pending = stuck.fold<int>(
      0,
      (sum, q) => sum + (q['finalDepth']! as int),
    );
    final parts = <String>[
      if (errors > 0) '$errors ${errors == 1 ? 'error' : 'errores'}',
      if (failedRequests > 0)
        '$failedRequests de $requests peticiones fallaron',
      if (pending > 0) '$pending sin sincronizar',
      if (errors == 0 && failedRequests == 0 && pending == 0) 'sin errores',
      '${screens.length} ${screens.length == 1 ? 'pantalla' : 'pantallas'}',
      _humanDuration(duration),
    ];
    return parts.join(' · ');
  }

  static String _humanDuration(Duration d) {
    if (d.inMinutes >= 1) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    }
    return '${d.inSeconds}s';
  }

  /// Errores agrupados por huella (tipo + origin + pantalla): el mismo bug
  /// no debe abrir cinco tickets.
  static List<Map<String, Object?>> errorGroups(List<ThorEvent> timeline) {
    final groups = <String, Map<String, Object?>>{};
    for (final event in timeline) {
      if (event.kind != ThorEventKind.error) continue;
      final fingerprint = [
        event.payload['type'],
        event.origin ?? event.payload['source'],
        event.screen?.display,
      ].join('|');
      final group = groups.putIfAbsent(
        fingerprint,
        () => {
          'fingerprint': fingerprint,
          'type': event.payload['type'],
          'screen': event.screen?.display,
          'origin': event.origin,
          'message': event.payload['message'],
          'count': 0,
          'firstSeq': event.seq,
        },
      );
      group['count'] = (group['count']! as int) + 1;
      group['lastSeq'] = event.seq;
    }
    return groups.values.toList()
      ..sort((a, b) => (b['count']! as int).compareTo(a['count']! as int));
  }

  /// Colas de sincronización que terminaron la sesión SIN vaciarse.
  ///
  /// Es la firma de "guardé la orden y nunca subió": la app no falla, la
  /// red no muestra error (nunca se intentó), y el usuario cree que ya
  /// quedó. Solo se ve mirando la profundidad final contra el máximo.
  /// Fail-closed: se reporta lo que NO llegó a cero, no se asume que
  /// drenó.
  static List<Map<String, Object?>> stuckQueues(List<ThorEvent> timeline) {
    final byQueue = <String, List<ThorEvent>>{};
    for (final event in timeline) {
      if (event.kind != ThorEventKind.storage) continue;
      if (event.payload['op'] != 'queue') continue;
      final name = event.payload['queue'] as String?;
      if (name == null) continue;
      byQueue.putIfAbsent(name, () => []).add(event);
    }

    final result = <Map<String, Object?>>[];
    for (final MapEntry(key: name, value: samples) in byQueue.entries) {
      final depths =
          samples.map((e) => e.payload['depth']).whereType<int>().toList();
      if (depths.isEmpty) continue;
      final finalDepth = depths.last;
      if (finalDepth == 0) continue; // Drenó: no hay nada que reportar.

      final maxDepth = depths.reduce((a, b) => a > b ? a : b);
      // Desde el último cero (o el arranque) mide cuánto lleva atorada.
      final lastDrainIndex = depths.lastIndexOf(0);
      final since = samples[lastDrainIndex + 1 < samples.length
              ? lastDrainIndex + 1
              : samples.length - 1]
          .atUtc;
      result.add({
        'queue': name,
        'finalDepth': finalDepth,
        'maxDepth': maxDepth,
        'everDrained': lastDrainIndex >= 0,
        'stuckForMs': samples.last.atUtc.difference(since).inMilliseconds,
        'origin': samples.last.origin,
      });
    }
    return result
      ..sort(
        (a, b) => (b['finalDepth']! as int).compareTo(a['finalDepth']! as int),
      );
  }
}
