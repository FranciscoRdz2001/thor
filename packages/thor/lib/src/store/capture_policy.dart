/// Límites de captura: cuánto ruido se deja entrar a la línea de tiempo y
/// cuánto detalle se escribe al journal.
///
/// Existe porque en una app real (3 min) el 88% del journal eran
/// eventos de estado — un solo bloc emitió 828, uno por scroll — y cada
/// petición de red pesaba ~2.7 KB (headers, bodies, cURL) aunque hubiera
/// salido bien. Ese volumen expulsaba lo valioso de los buffers y engordaba
/// el disco sin aportar nada a la depuración.
class ThorCapturePolicy {
  /// Crea una política. Los defaults son los recomendados.
  ///
  /// - [stateBurstLimit]: máximo de eventos de estado por bloc+acción dentro
  ///   de [stateBurstWindow]. El excedente se descarta y se CUENTA: un
  ///   evento resumen (`action: 'burst'`) declara cuántos se recortaron.
  ///   `0` desactiva el tope.
  /// - [burstSummaryEvery]: en una ráfaga larga (scroll sostenido) el
  ///   resumen se emite al menos con esta frecuencia, sin esperar a que la
  ///   ráfaga termine.
  /// - [fullNetworkInJournal]: si `false` (default), las peticiones
  ///   EXITOSAS van al journal solo con lo esencial (método, URL, status,
  ///   duración, bytes); las fallidas conservan todo el detalle. En memoria
  ///   (inspector, cURL, reporte manual) el detalle completo se conserva
  ///   siempre.
  /// - [logBurstLimit]: máximo de líneas de log (`print`, `debugPrint`,
  ///   `Thor.log`) por origen dentro de [logBurstWindow]. Un `print` en un
  ///   `build` o en un stream de scroll escribe cientos por segundo; el
  ///   excedente se descarta y se CUENTA en un resumen. Las de nivel
  ///   warn/error llevan su propio cupo: el ruido de debug no las ahoga.
  ///   `0` desactiva el tope.
  /// - [maxLogLength]: largo máximo del mensaje de un log (ya limpio de
  ///   datos personales); lo demás se trunca con `…(+N)`.
  const ThorCapturePolicy({
    this.stateBurstLimit = 3,
    this.stateBurstWindow = const Duration(seconds: 1),
    this.burstSummaryEvery = const Duration(seconds: 10),
    this.fullNetworkInJournal = false,
    this.logBurstLimit = 20,
    this.logBurstWindow = const Duration(seconds: 1),
    this.maxLogLength = 500,
  });

  /// Sin topes ni aligerado: todo como antes (depurar el propio Thor,
  /// tests que cuentan eventos exactos).
  const ThorCapturePolicy.unlimited()
      : this(stateBurstLimit: 0, fullNetworkInJournal: true, logBurstLimit: 0);

  /// Máximo de eventos de estado por bloc+acción por ventana (`0` = sin
  /// tope).
  final int stateBurstLimit;

  /// Ventana del tope de ráfagas de estado.
  final Duration stateBurstWindow;

  /// Frecuencia mínima del resumen en ráfagas sostenidas.
  final Duration burstSummaryEvery;

  /// Si las peticiones exitosas van completas al journal.
  final bool fullNetworkInJournal;

  /// Máximo de líneas de log por origen y nivel por ventana (`0` = sin
  /// tope).
  final int logBurstLimit;

  /// Ventana del tope de ráfagas de log.
  final Duration logBurstWindow;

  /// Largo máximo del mensaje de un log.
  final int maxLogLength;
}

/// Resumen de una ráfaga recortada por [BurstLimiter].
class BurstSummary {
  /// Crea un resumen.
  const BurstSummary({
    required this.key,
    required this.dropped,
    required this.firstDropAt,
    required this.lastDropAt,
  });

  /// Llave de la ráfaga (`bloc|acción`).
  final String key;

  /// Eventos descartados.
  final int dropped;

  /// Primer y último descarte de la ráfaga.
  final DateTime firstDropAt;

  /// Último descarte de la ráfaga.
  final DateTime lastDropAt;
}

class _BurstState {
  _BurstState(this.windowStart);

  DateTime windowStart;
  int count = 0;
  int dropped = 0;
  DateTime? firstDropAt;
  DateTime? lastDropAt;
}

/// Tope de ráfagas por llave con conteo de lo descartado.
///
/// Recortar en silencio borraría justo el hallazgo ("este bloc emite 5
/// estados por scroll" ES un problema de rendimiento que hay que mostrar),
/// así que cada descarte se cuenta y [due] entrega los resúmenes cuando la
/// ráfaga termina (una ventana completa sin descartes) o cada
/// [summaryEvery] si no termina nunca. Sin timers a propósito: se evalúa
/// en el siguiente evento grabado o al cerrar — un `Timer` colgado rompe
/// los tests de widgets de la app y no aporta nada que el próximo evento
/// no traiga.
class BurstLimiter {
  /// Crea un limitador de [limit] eventos por [window] y llave.
  BurstLimiter({
    required this.limit,
    required this.window,
    required this.summaryEvery,
  });

  /// Máximo por ventana.
  final int limit;

  /// Duración de la ventana.
  final Duration window;

  /// Frecuencia mínima de resumen en ráfagas largas.
  final Duration summaryEvery;

  final Map<String, _BurstState> _states = {};
  final Set<String> _pending = {};

  /// Tope de llaves vivas: un nombre de bloc por llave es acotado, pero
  /// el mapa no debe crecer sin límite si alguien mete ids en el nombre.
  static const _maxKeys = 256;

  /// ¿Hay descartes sin resumir?
  bool get hasPending => _pending.isNotEmpty;

  /// Registra un evento de [key] en [now]; `false` = descartarlo.
  bool allow(String key, DateTime now) {
    var state = _states[key];
    if (state == null) {
      if (_states.length >= _maxKeys) _prune();
      state = _states[key] = _BurstState(now);
    }
    if (now.difference(state.windowStart) >= window) {
      state
        ..windowStart = now
        ..count = 0;
    }
    state.count++;
    if (state.count <= limit) return true;
    state
      ..dropped += 1
      ..firstDropAt ??= now
      ..lastDropAt = now;
    _pending.add(key);
    return false;
  }

  /// Resúmenes listos en [now] (o todos si [all]): ráfagas terminadas o
  /// que ya llevan [summaryEvery] acumulando. Cada resumen se entrega una
  /// sola vez.
  List<BurstSummary> due(DateTime now, {bool all = false}) {
    if (_pending.isEmpty) return const [];
    final result = <BurstSummary>[];
    for (final key in _pending.toList()) {
      final s = _states[key]!;
      final ended = now.difference(s.lastDropAt!) >= window;
      final longRunning = now.difference(s.firstDropAt!) >= summaryEvery;
      if (!all && !ended && !longRunning) continue;
      result.add(
        BurstSummary(
          key: key,
          dropped: s.dropped,
          firstDropAt: s.firstDropAt!,
          lastDropAt: s.lastDropAt!,
        ),
      );
      s
        ..dropped = 0
        ..firstDropAt = null
        ..lastDropAt = null;
      _pending.remove(key);
    }
    return result;
  }

  /// Suelta las llaves sin descartes pendientes (las ráfagas abiertas se
  /// conservan: su conteo es evidencia).
  void _prune() => _states.removeWhere((key, _) => !_pending.contains(key));
}
