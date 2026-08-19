import 'package:meta/meta.dart';

/// Familia de un [ThorEvent].
///
/// Cada familia tiene su propio ring buffer con cuota independiente
/// (ver `EventStore`): el ruido de una familia charlatana (frames, estado)
/// nunca expulsa eventos escasos y valiosos (errores).
enum ThorEventKind {
  /// Cambio de pantalla (push/pop/replace de rutas, diálogos, sheets).
  navigation,

  /// Petición HTTP completada o fallida.
  network,

  /// Excepción, error de framework o desborde de layout.
  error,

  /// Interacción del usuario: tap, llenado de campo, gesto.
  interaction,

  /// Transición de estado (bloc/cubit/provider).
  state,

  /// Log manual de la app o marca (`Thor.mark`).
  log,

  /// Señal de entorno: conectividad, ciclo de vida, cambio de reloj.
  environment,

  /// Métrica de rendimiento (frames lentos, tormenta de rebuilds).
  performance,
}

/// Identidad de la pantalla activa en el momento de un evento.
///
/// Guarda las dos caras: el nombre de ruta que declaró el router (útil para
/// agrupar instancias parametrizadas de la misma pantalla) y la clase del
/// widget montado (grepeable — lleva directo al archivo). [display] prefiere
/// la clase porque es la que un dev o una IA puede buscar en el código.
@immutable
class ScreenId {
  /// Crea una identidad de pantalla. Al menos uno de los campos debería
  /// venir no-nulo; si todos son nulos, [display] cae a `'Desconocida'`.
  const ScreenId({this.routeName, this.widgetClass, this.routeType});

  /// Reconstruye desde el JSON producido por [toJson].
  factory ScreenId.fromJson(Map<String, Object?> json) => ScreenId(
        routeName: json['routeName'] as String?,
        widgetClass: json['widgetClass'] as String?,
        routeType: json['routeType'] as String?,
      );

  /// Nombre de ruta declarado por el router (`/checkout`), si existe.
  final String? routeName;

  /// Clase del widget de la pantalla (`CheckoutPage`), si se pudo resolver.
  final String? widgetClass;

  /// Tipo de la ruta (`MaterialPageRoute`, `DialogRoute`…), si se conoce.
  final String? routeType;

  /// Nombre presentable: clase > ruta > tipo de ruta > `'Desconocida'`.
  /// El tipo de ruta como último recurso hace legibles los diálogos y
  /// sheets sin nombre (`DialogRoute<void>`).
  String get display =>
      widgetClass ?? routeName ?? routeType ?? 'Desconocida';

  /// Serializa omitiendo campos nulos.
  Map<String, Object?> toJson() => {
        if (routeName != null) 'routeName': routeName,
        if (widgetClass != null) 'widgetClass': widgetClass,
        if (routeType != null) 'routeType': routeType,
      };

  @override
  bool operator ==(Object other) =>
      other is ScreenId &&
      other.routeName == routeName &&
      other.widgetClass == widgetClass &&
      other.routeType == routeType;

  @override
  int get hashCode => Object.hash(routeName, widgetClass, routeType);

  @override
  String toString() => 'ScreenId($display)';
}

/// Un evento inmutable de la línea de tiempo de Thor.
///
/// Todos los eventos —sin importar la familia— comparten la misma envoltura:
/// secuencia global, timestamps UTC + desfase local, pantalla activa y origen
/// en código. Esa envoltura común es lo que permite correlacionar familias
/// entre sí (¿qué peticiones salieron en esta pantalla antes del error?).
@immutable
class ThorEvent {
  /// Crea un evento. Producido normalmente por `ThorRecorder.record`,
  /// que asigna [seq] y estampa pantalla/tiempos automáticamente.
  const ThorEvent({
    required this.seq,
    required this.kind,
    required this.atUtc,
    required this.utcOffset,
    required this.payload,
    this.screen,
    this.origin,
  });

  /// Reconstruye desde el JSON producido por [toJson].
  ///
  /// Lanza [FormatException] si faltan campos obligatorios o `kind` es
  /// desconocido — un evento corrupto no debe pasar silenciosamente.
  factory ThorEvent.fromJson(Map<String, Object?> json) {
    final kindName = json['kind'] as String?;
    final kind = ThorEventKind.values.asNameMap()[kindName];
    if (kind == null) {
      throw FormatException('ThorEvent.kind desconocido: $kindName');
    }
    final atRaw = json['atUtc'] as String?;
    final at = atRaw == null ? null : DateTime.tryParse(atRaw);
    if (at == null) {
      throw FormatException('ThorEvent.atUtc inválido: $atRaw');
    }
    return ThorEvent(
      seq: json['seq'] as int? ??
          (throw const FormatException('ThorEvent.seq ausente')),
      kind: kind,
      atUtc: at,
      utcOffset: Duration(microseconds: json['utcOffsetUs'] as int? ?? 0),
      screen: switch (json['screen']) {
        final Map<String, Object?> s => ScreenId.fromJson(s),
        _ => null,
      },
      origin: json['origin'] as String?,
      payload: switch (json['payload']) {
        final Map<String, Object?> p => p,
        _ => const {},
      },
    );
  }

  /// Posición en la secuencia global de la sesión (monótona, sin huecos
  /// por familia). Ordena la línea de tiempo aunque dos eventos compartan
  /// milisegundo.
  final int seq;

  /// Familia del evento.
  final ThorEventKind kind;

  /// Momento del evento en UTC. Siempre UTC: correlacionar reportes de
  /// varios dispositivos con horas locales mezcladas no tiene arreglo
  /// retroactivo.
  final DateTime atUtc;

  /// Desfase de la zona local del dispositivo al momento del evento.
  /// Junto con [atUtc] reconstruye la hora local sin ambigüedad, y deja
  /// detectar relojes/zonas movidos (crítico en checador).
  final Duration utcOffset;

  /// Pantalla activa cuando ocurrió el evento — la llave de correlación.
  final ScreenId? screen;

  /// Primer frame de código de la app en el stack al disparar el evento
  /// (`package:mi_app/checkout/checkout_page.dart:142`). Es lo que lleva
  /// del síntoma al archivo.
  final String? origin;

  /// Datos específicos de la familia. Solo tipos JSON-compatibles; la
  /// redacción ya ocurrió antes de construir el evento.
  final Map<String, Object?> payload;

  /// Serializa el evento completo (una línea del JSONL persistido).
  Map<String, Object?> toJson() => {
        'seq': seq,
        'kind': kind.name,
        'atUtc': atUtc.toIso8601String(),
        'utcOffsetUs': utcOffset.inMicroseconds,
        if (screen != null) 'screen': screen!.toJson(),
        if (origin != null) 'origin': origin,
        'payload': payload,
      };

  @override
  String toString() => 'ThorEvent(#$seq ${kind.name} ${screen?.display})';
}
