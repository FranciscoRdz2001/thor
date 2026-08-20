import 'package:thor/src/model/event.dart';

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
      final screen = event.screen?.display ?? '(sin pantalla)';
      final bucket = result.putIfAbsent(
        screen,
        () => {'slowFrames': 0, 'worstMs': 0},
      );
      bucket['slowFrames'] = (bucket['slowFrames']! as int) +
          (event.payload['slowFrames'] as int? ?? 0);
      final worst = event.payload['worstMs'] as int? ?? 0;
      if (worst > (bucket['worstMs']! as int)) bucket['worstMs'] = worst;
    }
    return result;
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
}
