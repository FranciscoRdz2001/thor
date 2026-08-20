import 'dart:math';

import 'package:clock/clock.dart';

import 'package:thor/src/model/event.dart';
import 'package:thor/src/store/event_store.dart';

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
  ThorRecorder({required this.store});

  /// Almacén en memoria de la sesión.
  final EventStore store;

  final List<ThorEventListener> _listeners = [];
  int _seq = 0;

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
  /// grabador está silenciado ([muted]) y la familia es silenciable.
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
    final event = ThorEvent(
      seq: _seq++,
      kind: kind,
      atUtc: now.toUtc(),
      utcOffset: now.timeZoneOffset,
      screen: screenOverride ?? currentScreen,
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
