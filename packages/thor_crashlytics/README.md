# thor_crashlytics

Puente **opcional** entre Thor y Firebase Crashlytics: cada crash (nativo o
no) lleva el id y el link de la sesión de Thor en la que ocurrió, así que del
reporte de Crashlytics se salta directo al replay de lo que hizo el usuario.

Thor core (`thor`, `thor_flutter`, `thor_bloc`) **no** depende de Firebase;
solo este paquete lo hace. Si no lo agregas, nada cambia.

## Uso

```yaml
dependencies:
  thor_crashlytics:
    path: ../thor/packages/thor_crashlytics   # o git
```

```dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  // Antes o después de Thor.run: da igual.
  ThorCrashlytics.link(dashboardUrl: 'https://thor.miempresa.com');

  await Thor.run(
    () => runApp(const MyApp()),
    enabled: const bool.fromEnvironment('THOR', defaultValue: kDebugMode),
  );
}
```

Al arrancar la sesión, y cada vez que `Thor.setUser` cambia el usuario, fija
estas custom keys y escribe una línea de log:

| Key                | Valor                                        |
| ------------------ | -------------------------------------------- |
| `thor_session_id`  | `Thor.sessionId`                             |
| `thor_session_url` | `<dashboardUrl>/sessions/<id>` (si hay base) |
| `thor_user_id`     | id de `Thor.setUser` (`''` si es anónimo)    |

Si no pasas `dashboardUrl`, usa `Thor.dashboardBaseUrl`.

### Por qué custom keys (y por qué no hace falta más)

Un crash **nativo** mata el proceso: Dart ya no puede reportar nada.
Crashlytics guarda las custom keys en disco y las adjunta al reporte en el
siguiente arranque, así que el id de sesión sobrevive al crash. Por lo mismo
los errores **no fatales** que Thor captura ya llevan las keys vigentes en
cualquier `recordError`; no se toca nada extra.

### Sesiones con muestreo

Si el replay usa `sampleRate < 1`, una sesión no muestreada no se sube y el
link llevará a una página sin datos (salvo que ocurra un error con
`uploadOnError`, o se pida subirla bajo demanda). Es lo esperado: el link se
arma siempre, la sesión existe en el dashboard solo si se subió.

### Apagado = inofensivo

Con Thor apagado (`enabled: false`) el listener nunca se dispara: cero
llamadas a Crashlytics. Si Crashlytics falla (no inicializado, canal caído),
el error se traga: nunca afecta a la app.

## Si no puedes usar este paquete (conflicto de versiones)

Implementa la interfaz de una línea por método y pásala como `client`:

```dart
class MiCrashlytics implements ThorCrashlyticsClient {
  @override
  Future<void> setCustomKey(String k, Object v) =>
      FirebaseCrashlytics.instance.setCustomKey(k, v);
  @override
  Future<void> log(String m) => FirebaseCrashlytics.instance.log(m);
}
```

O, sin el paquete, directamente la API de `thor_flutter`:

```dart
Thor.dashboardBaseUrl = 'https://thor.miempresa.com';
Thor.addSessionListener((info) {
  FirebaseCrashlytics.instance
    ..setCustomKey('thor_session_id', info.sessionId)
    ..setCustomKey('thor_session_url', info.sessionUrl ?? '')
    ..setCustomKey('thor_user_id', info.userId ?? '');
});
```

## Mismo patrón con Sentry (solo snippet, sin dependencia)

```dart
Thor.dashboardBaseUrl = 'https://thor.miempresa.com';
Thor.addSessionListener((info) {
  Sentry.configureScope((scope) {
    scope.setTag('thor_session_id', info.sessionId);
    if (info.sessionUrl != null) {
      scope.setContexts('thor', {'session_url': info.sessionUrl});
    }
    scope.setUser(SentryUser(id: info.userId));
  });
});
```

`Thor.addSessionListener` llama de inmediato con el estado actual si Thor ya
corre, y de nuevo en cada cambio de usuario; con Thor apagado nunca se llama.
