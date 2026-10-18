import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:thor_flutter/thor_flutter.dart';

/// Lo mínimo de Crashlytics que usa el puente.
///
/// Es una interfaz propia (y no `FirebaseCrashlytics` directo) para poder
/// probar sin un proyecto Firebase y para que, si una app no puede usar
/// esta versión del plugin, escriba un adaptador de una línea por método.
abstract interface class ThorCrashlyticsClient {
  /// Fija una custom key (se persiste a disco y viaja con el siguiente
  /// reporte, nativo o no).
  Future<void> setCustomKey(String key, Object value);

  /// Añade una línea al log breadcrumb del reporte.
  Future<void> log(String message);
}

/// Implementación real sobre `FirebaseCrashlytics.instance`.
///
/// La instancia se toca de forma perezosa (en la primera llamada): si Thor
/// está apagado nunca hay llamadas y Firebase ni se menciona.
class FirebaseThorCrashlyticsClient implements ThorCrashlyticsClient {
  /// Crea el cliente real.
  const FirebaseThorCrashlyticsClient();

  @override
  Future<void> setCustomKey(String key, Object value) =>
      FirebaseCrashlytics.instance.setCustomKey(key, value);

  @override
  Future<void> log(String message) => FirebaseCrashlytics.instance.log(message);
}

/// Enlaza cada crash de Crashlytics con la sesión de Thor que lo vivió.
///
/// Por qué custom keys: un crash NATIVO mata el proceso y Dart ya no puede
/// reportar nada, pero Crashlytics guarda las custom keys en disco y las
/// adjunta al reporte en el siguiente arranque. Con `thor_session_url` el
/// equipo salta del crash al replay de lo que el usuario hizo antes. Por la
/// misma razón NO hace falta tocar los errores no fatales que Thor captura:
/// cualquier `recordError` ya lleva las keys vigentes.
///
/// Apagado = inofensivo: se registra un listener en `Thor`, que solo se
/// llama si Thor está encendido. Con Thor apagado no hay ninguna llamada a
/// Crashlytics.
class ThorCrashlytics {
  ThorCrashlytics._();

  static void Function()? _cancel;

  /// Clave con el id de la sesión de Thor.
  static const sessionIdKey = 'thor_session_id';

  /// Clave con el link al dashboard (solo si hay [link] `dashboardUrl` o
  /// `Thor.dashboardBaseUrl`).
  static const sessionUrlKey = 'thor_session_url';

  /// Clave con el usuario de `Thor.setUser` (`''` si es anónimo:
  /// Crashlytics no permite borrar keys).
  static const userIdKey = 'thor_user_id';

  /// Empieza a reflejar la sesión de Thor en Crashlytics: al arrancar y en
  /// cada cambio de usuario fija las keys y escribe una línea de log.
  ///
  /// Se puede llamar antes o después de `Thor.run`. [dashboardUrl] es la
  /// base del dashboard (se arma `<base>/sessions/<id>`); si es `null` usa
  /// `Thor.dashboardBaseUrl`. [client] es solo para pruebas o adaptadores
  /// propios. Llamarlo otra vez reemplaza el enlace anterior.
  ///
  /// Devuelve la función que lo desactiva.
  static void Function() link({
    String? dashboardUrl,
    ThorCrashlyticsClient? client,
  }) {
    _cancel?.call();
    final target = client ?? const FirebaseThorCrashlyticsClient();
    final cancel = Thor.addSessionListener((info) {
      final url = Thor.sessionUrlFor(info.sessionId, baseUrl: dashboardUrl) ??
          info.sessionUrl;
      _push(target, info.sessionId, url, info.userId);
    });
    _cancel = cancel;
    return () {
      cancel();
      if (identical(_cancel, cancel)) _cancel = null;
    };
  }

  static void _push(
    ThorCrashlyticsClient c,
    String sessionId,
    String? url,
    String? userId,
  ) {
    // Fire-and-forget: Crashlytics sin inicializar o un canal caído nunca
    // debe afectar a la app (ni dejar un error async sin manejar).
    Future<void> safe(Future<void> Function() f) async {
      try {
        await f();
      } on Object catch (_) {}
    }

    safe(() => c.setCustomKey(sessionIdKey, sessionId));
    if (url != null) safe(() => c.setCustomKey(sessionUrlKey, url));
    safe(() => c.setCustomKey(userIdKey, userId ?? ''));
    safe(
      () => c.log(
        'Thor session $sessionId'
        '${userId == null ? '' : ' user=$userId'}'
        '${url == null ? '' : ' $url'}',
      ),
    );
  }
}
