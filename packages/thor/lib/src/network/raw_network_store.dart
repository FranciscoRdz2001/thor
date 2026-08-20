import 'dart:collection';

/// Almacén de cURLs CRUDOS (sin redactar) — SOLO memoria.
///
/// Existe para reproducir peticiones: un cURL redactado documenta pero no
/// se puede ejecutar. Reglas duras de este almacén:
///
/// - **Jamás se persiste**: no pasa por el journal, ni por los reportes,
///   ni por el share. Un token no debe tocar disco.
/// - Cuota chica ([capacity]): solo las peticiones recientes.
/// - Se lee bajo acción EXPLÍCITA (botón "copiar cURL real" del inspector,
///   `thor_event` con `raw=true`), nunca en volcados automáticos.
class RawNetworkStore {
  RawNetworkStore._();

  /// Máximo de cURLs crudos retenidos.
  static const int capacity = 50;

  static final LinkedHashMap<int, String> _bySeq = LinkedHashMap();

  /// Guarda el cURL crudo de la petición con secuencia [seq].
  static void put(int seq, String curl) {
    _bySeq[seq] = curl;
    if (_bySeq.length > capacity) {
      _bySeq.remove(_bySeq.keys.first);
    }
  }

  /// cURL crudo de [seq], o `null` si ya fue expulsado o nunca se capturó.
  static String? forSeq(int seq) => _bySeq[seq];

  /// Vacía el almacén (fin de sesión, tests).
  static void clear() => _bySeq.clear();

  /// Cuántos hay vivos.
  static int get length => _bySeq.length;
}
