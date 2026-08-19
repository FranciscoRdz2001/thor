import 'dart:collection';

import 'package:thor/src/model/event.dart';

/// Cuotas por familia de evento.
///
/// El problema que resuelve: un buffer único se llena con la familia más
/// charlatana (estado, frames) y expulsa justo lo escaso y valioso (errores).
/// Cada familia tiene su propio ring buffer; el ruido de una jamás desplaza
/// a otra.
class BufferQuotas {
  /// Crea cuotas explícitas por familia. Cualquier familia ausente usa
  /// [defaultQuota].
  const BufferQuotas({this.defaultQuota = 200, this.perKind = const {}});

  /// Cuotas por defecto pensadas para una sesión de QA larga: generoso en
  /// red/interacción (la narrativa), acotado en estado/frames (el ruido),
  /// y errores con espacio de sobra porque son los que importan.
  const BufferQuotas.standard()
      : this(
          perKind: const {
            ThorEventKind.navigation: 300,
            ThorEventKind.network: 400,
            ThorEventKind.error: 300,
            ThorEventKind.interaction: 400,
            ThorEventKind.state: 300,
            ThorEventKind.log: 200,
            ThorEventKind.environment: 100,
            ThorEventKind.performance: 100,
          },
        );

  /// Cuota para familias no listadas en [perKind].
  final int defaultQuota;

  /// Cuota específica por familia.
  final Map<ThorEventKind, int> perKind;

  /// Cuota efectiva de [kind].
  int of(ThorEventKind kind) => perKind[kind] ?? defaultQuota;
}

/// Almacén en memoria de la línea de tiempo: un ring buffer por familia.
///
/// La secuencia global ([ThorEvent.seq], asignada por el grabador) permite
/// reconstruir el orden total al leer con [timeline] aunque el almacenamiento
/// esté particionado por familia.
class EventStore {
  /// Crea el almacén con [quotas] (por defecto [BufferQuotas.standard]).
  EventStore({BufferQuotas? quotas})
      : _quotas = quotas ?? const BufferQuotas.standard();

  final BufferQuotas _quotas;
  final Map<ThorEventKind, Queue<ThorEvent>> _buffers = {
    for (final k in ThorEventKind.values) k: Queue<ThorEvent>(),
  };

  /// Eventos expulsados por familia desde el inicio de la sesión.
  /// El reporte lo declara ("se descartaron N eventos de estado") para que
  /// una línea de tiempo truncada nunca se lea como completa.
  final Map<ThorEventKind, int> evictedCounts = {
    for (final k in ThorEventKind.values) k: 0,
  };

  /// Agrega [event] a su buffer, expulsando el más viejo si la familia
  /// alcanzó su cuota.
  void add(ThorEvent event) {
    final buffer = _buffers[event.kind]!..addLast(event);
    if (buffer.length > _quotas.of(event.kind)) {
      buffer.removeFirst();
      evictedCounts[event.kind] = evictedCounts[event.kind]! + 1;
    }
  }

  /// Eventos vivos de una familia, en orden de llegada.
  List<ThorEvent> ofKind(ThorEventKind kind) =>
      List.unmodifiable(_buffers[kind]!);

  /// Línea de tiempo total (todas las familias) ordenada por [ThorEvent.seq].
  ///
  /// Filtros opcionales: [kinds] restringe familias, [screen] restringe a la
  /// pantalla cuyo `display` coincide, [sinceSeq] corta el pasado.
  List<ThorEvent> timeline({
    Set<ThorEventKind>? kinds,
    String? screen,
    int? sinceSeq,
  }) {
    final all = <ThorEvent>[
      for (final k in kinds ?? ThorEventKind.values.toSet())
        ..._buffers[k]!,
    ]..sort((a, b) => a.seq.compareTo(b.seq));
    return [
      for (final e in all)
        if ((screen == null || e.screen?.display == screen) &&
            (sinceSeq == null || e.seq >= sinceSeq))
          e,
    ];
  }

  /// Total de eventos vivos en todos los buffers.
  int get length =>
      _buffers.values.fold(0, (sum, buffer) => sum + buffer.length);

  /// Vacía todos los buffers y contadores (nueva sesión).
  void clear() {
    for (final buffer in _buffers.values) {
      buffer.clear();
    }
    evictedCounts.updateAll((_, __) => 0);
  }
}
