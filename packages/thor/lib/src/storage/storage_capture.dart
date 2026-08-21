import 'package:thor/src/model/event.dart';
import 'package:thor/src/thor_core.dart';
import 'package:thor/src/util/origin.dart';

/// Visibilidad de la capa de datos LOCAL: preferencias, base embebida y
/// colas de sincronización.
///
/// Por qué no es automático como red o navegación: no existe un seam
/// universal para el almacenamiento local (cada app usa un plugin
/// distinto, y `shared_preferences` no expone hooks). Lo que Thor da es
/// el registro barato y una regla de agregación que convierte esos
/// puntos en un diagnóstico — la clase de bug "la orden se guardó pero
/// nunca subió" es invisible en red y en logs, pero salta a la vista en
/// la profundidad de la cola.
///
/// Se llama desde el repositorio, no desde cada widget:
/// ```dart
/// await prefs.setString('pending_orders', json);
/// ThorStorage.wrote('prefs', 'pending_orders', sizeBytes: json.length);
/// ThorStorage.queueDepth('sync_ordenes', pending.length, op: 'encolar');
/// ```
class ThorStorage {
  const ThorStorage._();

  /// Registra una escritura local en [store] (`prefs`, `sqlite`, `hive`…).
  ///
  /// [value] pasa por la política de redacción — solo sale en claro si la
  /// app declaró [key] como segura. Para blobs grandes usa [sizeBytes] y
  /// omite el valor: el tamaño es el dato que importa.
  static void wrote(
    String store,
    String key, {
    Object? value,
    int? sizeBytes,
  }) =>
      _record('write', store, key, value: value, sizeBytes: sizeBytes);

  /// Registra una lectura. [hit] distingue "estaba" de "no estaba" — un
  /// miss inesperado explica media pantalla vacía.
  static void read(String store, String key, {required bool hit}) =>
      _record('read', store, key, extra: {'hit': hit});

  /// Registra un borrado.
  static void removed(String store, String key) =>
      _record('remove', store, key);

  /// Registra la profundidad de una cola de sincronización DESPUÉS de la
  /// operación [op]. Es la señal que delata una cola atorada.
  static void queueDepth(String queue, int depth, {String? op}) {
    final core = ThorCore.instance;
    if (core == null) return;
    core.recorder.record(
      ThorEventKind.storage,
      {
        'op': 'queue',
        'queue': queue,
        'depth': depth,
        if (op != null) 'action': op,
      },
      // Un solo salto hasta el llamador (el default); _record salta dos
      // porque tiene el wrapper público en medio.
      origin: currentOrigin(),
    );
  }

  static void _record(
    String op,
    String store,
    String key, {
    Object? value,
    int? sizeBytes,
    Map<String, Object?> extra = const {},
  }) {
    final core = ThorCore.instance;
    if (core == null) return;
    core.recorder.record(
      ThorEventKind.storage,
      {
        'op': op,
        'store': store,
        'key': key,
        // El TIPO siempre; el valor solo si la clave está permitida.
        if (value != null) 'valueType': value.runtimeType.toString(),
        if (value != null)
          'value': core.redaction.redactValue(
            value,
            keyAllowed: core.redaction.isKeyAllowed(key),
          ),
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        ...extra,
      },
      origin: currentOrigin(skipFrames: 2),
    );
  }
}
