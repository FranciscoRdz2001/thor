import 'package:meta/meta.dart';

/// Cómo se originó un reporte/sesión — la dimensión por la que una futura
/// plataforma de pruebas filtra. Se graba desde el día uno para que el
/// histórico nazca clasificado.
enum ThorReportOrigin {
  /// QA (o un dev) pidió el reporte manualmente.
  manual,

  /// Recuperado al arrancar: la sesión anterior murió sin cerrar.
  crashRecovery,

  /// Generado por una corrida de pruebas automatizadas.
  automatedTest,
}

/// Identidad y contexto de una sesión de captura.
///
/// Los tres IDs son la base de la correlación futura entre dispositivos y
/// sesiones; agregarlos después implicaría migrar reportes viejos, por eso
/// existen desde el esquema 1.
@immutable
class ThorSession {
  /// Crea una sesión.
  const ThorSession({
    required this.sessionId,
    required this.installId,
    required this.startedAtUtc,
    required this.utcOffset,
    this.appInfo = const {},
    this.deviceInfo = const {},
  });

  /// Reconstruye desde el JSON de [toJson].
  factory ThorSession.fromJson(Map<String, Object?> json) => ThorSession(
        sessionId: json['sessionId']! as String,
        installId: json['installId']! as String,
        startedAtUtc: DateTime.parse(json['startedAtUtc']! as String),
        utcOffset: Duration(microseconds: json['utcOffsetUs'] as int? ?? 0),
        appInfo: _asStringMap(json['appInfo']),
        deviceInfo: _asStringMap(json['deviceInfo']),
      );

  /// Único por sesión (arranque de app).
  final String sessionId;

  /// Único por instalación, anónimo y persistente entre sesiones.
  final String installId;

  /// Arranque de la sesión en UTC.
  final DateTime startedAtUtc;

  /// Desfase de zona local al arrancar.
  final Duration utcOffset;

  /// Versión, build, flavor, commit… (lo llena el adaptador de Flutter).
  final Map<String, String> appInfo;

  /// Versión de la app (`appInfo['version']`), si la app la reportó.
  String? get appVersion => appInfo[appVersionKey];

  /// Build / número de compilación (`appInfo['build']`), si se reportó.
  String? get appBuild => appInfo[appBuildKey];

  /// Clave de [appInfo] para la versión (la que ve el dash en `meta.app`).
  static const appVersionKey = 'version';

  /// Clave de [appInfo] para el build (la que ve el dash en `meta.app`).
  static const appBuildKey = 'build';

  /// Combina [appInfo] con [version]/[build] explícitos (que ganan sobre
  /// las claves `version`/`build` del mapa). Valores vacíos se ignoran:
  /// "sin versión" es mejor que `version: ""`.
  static Map<String, String> mergeAppInfo(
    Map<String, String> appInfo, {
    String? version,
    String? build,
  }) =>
      {
        ...appInfo,
        if (version != null && version.trim().isNotEmpty)
          appVersionKey: version.trim(),
        if (build != null && build.trim().isNotEmpty) appBuildKey: build.trim(),
      };

  /// Modelo, OS, pantalla, escala de texto, locale… (ídem).
  final Map<String, String> deviceInfo;

  /// Serializa la sesión (cabecera del journal y del reporte).
  Map<String, Object?> toJson() => {
        'sessionId': sessionId,
        'installId': installId,
        'startedAtUtc': startedAtUtc.toIso8601String(),
        'utcOffsetUs': utcOffset.inMicroseconds,
        'appInfo': appInfo,
        'deviceInfo': deviceInfo,
      };

  static Map<String, String> _asStringMap(Object? raw) => switch (raw) {
        final Map<Object?, Object?> m => {
            for (final MapEntry(:key, :value) in m.entries)
              key.toString(): value.toString(),
          },
        _ => const {},
      };
}
