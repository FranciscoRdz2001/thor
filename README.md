# Thor

SDK de diagnóstico para Flutter: captura navegación, red, errores,
interacciones y estado en **una línea de tiempo correlacionada**, genera
pasos de reproducción automáticos para QA y reportes con `archivo:línea`
para que el dev (o una IA) llegue del síntoma al código.

## Paquetes

| Paquete | Rol | Estado |
|---|---|---|
| `packages/thor` | Núcleo Dart puro: eventos, buffers, redacción de secretos (allowlist opt-in), journal anti-crash, red por HttpOverrides, narrador, agregados, reporte .gz | ✅ |
| `packages/thor_flutter` | Thor.run, observer universal, errores, interacciones, rendimiento, overlay/inspector en dispositivo, aviso de crash, share | ✅ |
| `packages/thor_bloc` | Observer de blocs con delegate (tipos por defecto) | ✅ |
| `packages/thor_test` | `thorAutoReport()`: cada test fallido genera su reporte (origen automatedTest) | ✅ |

Integrado en: `stelyt_pos_app` y `ssoma_checador_app` (gate `--dart-define=THOR=true`, default debug).

## Lo que hace con lo capturado

No solo guarda: concluye. El reporte abre con un **veredicto** de una línea
(`2 errores · 1 de 2 peticiones fallaron · 2 pantallas · 1m 40s`) y marca los
patrones que un humano tardaría en ver:

- **Toques repetidos** al mismo botón en ráfaga — frustración = casi siempre
  un bug (no dio feedback, o disparó doble).
- **Colas sin vaciar** (`ThorStorage.queueDepth`) — la firma de "la orden se
  guardó pero nunca subió": nada falla, la red no muestra error porque nunca
  se intentó, y el usuario cree que ya quedó. Rompe el "sin errores" del
  veredicto a propósito.
- **Captura de pantalla** automática al desbordarse un layout.
- **Interacciones por accesibilidad**: un usuario con VoiceOver/TalkBack
  activa botones por acción semántica, sin sintetizar toques — su sesión
  salía sin un solo paso. (Solo cubre el camino del engine; un arnés que
  llame `SemanticsOwner.performAction` en proceso queda fuera.)
- **Blocs ruidosos**: un bloc que emite un estado por scroll se recorta a
  `ThorCapturePolicy.stateBurstLimit` eventos/s por bloc+acción (default 3),
  pero lo descartado se cuenta en un evento `action: 'burst'` y el reporte
  lo lista — el spam ES el hallazgo. Una transición a un estado de fallo
  nunca se recorta.
- **Journal ligero**: las peticiones exitosas van a disco solo con método,
  URL, status, duración y bytes (`lite: true`); las fallidas conservan
  headers, cuerpos y cURL. En memoria (inspector, cURL, reporte manual) todo
  sigue completo. `fullNetworkInJournal: true` lo desactiva.
- **Identidad**: `Thor.setUser(id, props: {...})` deja el usuario en la
  línea de tiempo, el reporte y el replay, y el dashboard busca sesiones
  por él. El id se guarda tal cual (con `RedactionPolicy.strict()` uno con
  forma de email se redacta: ahí pasa uno opaco). `props` es JSON libre con lo que quieras ver al depurar a
  esa persona (email, nombre, tienda…): se guarda en claro porque la app
  lo manda a propósito, salvo claves de secreto (contraseña, token,
  tarjeta, CVV), y con tope de ~4 KB.
- **Logs de consola**: `print` y `debugPrint` se graban solos (la consola
  los sigue mostrando igual) con nivel deducido del texto, sin secretos
  (`Bearer …`, `password=…`, `token=…`; con `strict()` también sin
  emails, números largos ni tokens sueltos), recortados a 500 caracteres y con tope de ráfagas por segundo (lo
  descartado se cuenta). `dart:developer` `log()` no se puede interceptar:
  cambia `import 'dart:developer';` por
  `import 'package:thor_flutter/log.dart';` (misma firma) o usa `Thor.log`.
  El narrador omite los de debug; el replay lleva solo warn/error
  (todos los niveles en modo diagnóstico, que enciende el dashboard).
  `Thor.run(captureLogs: false)` lo apaga.
- **Logs estructurados**: `Thor.log('cobro', level: ThorLogLevel.warn,
  data: {'orderId': 42})` suma campos JSON libres al mensaje (replay
  `ev` `k: "log"`, `p: {m, lv, src, data?}`), sin secretos y con tope de
  ~2 KB; `Thor.log` sigue mandando también a `dart:developer`.
- **Eventos de negocio**: `Thor.track('add_to_cart', {'sku': 'A1'})` deja
  el evento en la línea de tiempo, el journal, el reporte y el replay
  (`k: "track"`, `p: {n, props?}`). `props` se guarda legible salvo
  secretos y se descarta si pesa más de ~2 KB. Con Thor apagado es no-op.
- **Rendimiento** (eventos `performance`, `p.kind`; en replay, narrador y
  reporte):
  - `startup {ms, until: first_frame|first_screen}`: de `Thor.run` al
    primer frame rasterizado / a la primera pantalla.
  - `screen_load {screen, ms, from?}`: del cambio de pantalla al último
    frame antes de que la UI se quede quieta (reusa la detección de
    quietud de `ScreenCapture`; por frame solo se lee un reloj, ~45 ns).
  - `jank {screen, slow, frozen, worstMs, frames}`: por lote de frames y
    con la pantalla vigente al entregarse el lote (≤ ~1 s después).
  - `anr {ms, screen}`: la UI isolate bloqueada ≥ `anrThreshold` (2 s por
    defecto, `Thor.run(anrThreshold: ...)`, `null` lo apaga). Un isolate
    aparte hace ping cada ~umbral/4 (500 ms): sin trabajo por frame, un
    solo ping en vuelo, solo con la app en `resumed` (en segundo plano su
    timer se cancela: no despierta al proceso), no confunde una suspensión
    del SO con un bloqueo, no mantiene viva la app y está apagado en tests
    y con Thor apagado, y también en debug (`kDebugMode`: un breakpoint o
    un hot reload bloquean solo la UI isolate y serían ANR falsos). Solo ve los ANR que terminan (si el SO mata la app
    a media espera no hubo quién grabarlo).
  - `custom {name, ms, data?}` con `Thor.measure(name, ms, data: {...})`.
    Si la app ya tiene su medidor (una app de producción: `PerformanceTracker`), lo
    reenvía con UNA línea donde cierra cada traza:
    `Thor.measure(trace.name, trace.elapsed.inMilliseconds);`
  Costo medido: `test/performance_overhead_test.dart` (≈45 ns por frame
  para `screen_load`, ≈2 ns/frame para evaluar un lote sano, y el
  watchdog cuesta <1-3 % de throughput en la UI isolate, dentro del ruido
  de medición).
- **Salud visible de la UI** (`UiHealthCapture`, instalada por `Thor.run`;
  lo que el usuario ve mal aunque no haya excepción). Un recorrido del
  árbol PINTADO cada segundo, solo si hubo frames desde el anterior o hay
  algo en observación, y nunca en segundo plano (por frame solo suma un
  entero):
  - `performance stuck_loading {screen, ms}`: un spinner, barra o
    esqueleto (`*Shimmer*`/`*Skeleton*`) visible 8 s o más en la misma
    pantalla (un progreso con `value` no cuenta).
  - `performance blank_screen {screen, ms, nodes}`: pantalla conocida, sin
    nada cargando y ≤ 3 textos/imágenes/campos pintados durante 5 s. Las
    pantallas con vista nativa (cámara, mapa, webview) se excluyen.
  - `error` con `source: ui_error`: un `AlertDialog`, `SnackBar`,
    `MaterialBanner`, `*Dialog` o `*Toast` que APARECE con texto de fallo
    ("no se pudo", "error", "intenta de nuevo"…). Si el texto es neutro es
    `environment ui_message {widget, text}`. Texto sin secretos (y sin
    datos personales con la política estricta).
  - `error` con `source: image_error {url, statusCode?}`: una imagen que no
    cargó, incluso con `errorBuilder` (que se traga la excepción: se ve en
    la capa de red). Misma URL: una vez cada 5 s.
  - `layout_overflow` sigue viniendo de la aserción de Flutter, así que
    solo existe en debug/profile: en release el framework no avisa.
- **Contexto del dispositivo** (eventos `environment`, `p.signal`; en
  journal, reporte, narrador y replay, sin plugins y sin trabajo por frame:
  son avisos que Flutter ya manda, y cada valor solo se graba si cambió):
  - `lifecycle {state}`: `resumed | inactive | paused | hidden | detached`.
  - `memory_pressure`: el sistema avisa que anda corto de memoria (espaciado
    a uno cada 5 s). Contexto oro cuando "la app se cerró sola".
  - `locale {value}` (`es_MX`), `text_scale {value}` (`1.3`) y
    `brightness {value}` (`light | dark`): cambios a media sesión. Los
    valores iniciales ya van en la cabecera de la sesión (`deviceInfo`).
  - `connectivity {online}`: **inferida**, sin `connectivity_plus`. Se
    declara offline con fallos de DNS/ruta (`SocketException` con `Failed
    host lookup`, `Network is unreachable`…) de 2 hosts distintos o 3 del
    mismo en 15 s, y vuelve a online con la primera respuesta HTTP (el
    estado inicial se asume online, sin evento). `Connection refused` y los
    timeouts NO cuentan: un servidor caído no es un teléfono sin red.
    Límite: solo ve la red que usa la app; sin tráfico no hay señal. Si
    necesitas el estado exacto del radio, adaptador opcional (la app
    depende de `connectivity_plus`, Thor no):

    ```dart
    Connectivity().onConnectivityChanged.listen((r) {
      ThorCore.instance?.recorder.record(ThorEventKind.environment, {
        'signal': 'connectivity',
        'online': !r.contains(ConnectivityResult.none),
      });
    });
    ```
- **Red completa para depurar servicios**: TODAS las peticiones (no solo
  las fallidas) con método, URL completa con query, status, duración,
  headers y cuerpos de petición y respuesta (JSON decodificado o texto;
  binarios solo por tamaño). En el replay cada cuerpo va hasta 4 KB
  (`ThorReplayConfig.maxBodyBytes`; 8 KB en modo diagnóstico) con
  `qbt`/`bt` si se cortó y el tamaño real en `qn`/`rn`. Imágenes, fuentes
  y assets estáticos nunca.
- **Replay como video**: el texto de la pantalla viaja visible (también lo
  escrito en campos normales). Jamás viaja el contenido de un campo
  sensible (`obscureText`, autofill de contraseña/tarjeta/OTP, teclado de
  contraseña visible, o etiqueta/hint de secreto: "Número de tarjeta",
  "CVV", "NIP", "Código de seguridad") ni nada dentro de
  `ThorReplayIgnore`. Un PIN dibujado con `Text` propios (cajitas de
  OTP) no es un campo: envuélvelo en `ThorReplayIgnore`.
  `ThorReplayConfig(maskText: true)` enmascara el texto (largos de
  palabra) sin tocar el resto.
- **Test de reproducción**: `ThorReproTestBuilder.build(timeline)` emite el
  esqueleto del `integration_test` con los pasos exactos. Los valores de los
  campos y la aserción van marcados `TODO` — Thor sabe qué pasó, no qué
  DEBERÍA pasar, y no filtra contenido de campos al test.

## Versiones y releases

Cada sesión lleva la versión y el build de la app: `meta.app.version` /
`meta.app.build` en el replay, `session.appInfo` en el journal y el
reporte (`- App: v1.4.2 build 87 · {flavor: qa}`). El replay también
graba `meta.redaction` (`secretsOnly` | `strict`) para que el dash sepa
qué política se aplicó.

```dart
Thor.run(
  body,
  appVersion: '1.4.2', // -> appInfo['version']
  appBuild: '87',      // -> appInfo['build']
  appInfo: {'flavor': 'qa'},
);
```

`appVersion`/`appBuild` ganan sobre las claves `version`/`build` de
`appInfo`; vacíos se ignoran. Thor **no** lee la versión solo: eso
exigiría `package_info_plus` (plugin nativo) en el núcleo y rompe
"apagado = inofensivo". Es un one-liner en la app, que ya tiene el
plugin o puede sumarlo:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final info = await PackageInfo.fromPlatform();
  await Thor.run(
    () async => runApp(const MyApp()),
    appVersion: info.version,
    appBuild: info.buildNumber,
  );
}
```

Para comparar releases: `ThorSession.appVersion` / `appBuild`, y el
diff de sesiones ya marca cambios en `app`.

## Principios

- **3 líneas de integración**, nada por ruta/bloc/petición.
- **Solo secretos por defecto**: `Authorization`, cookies, tokens
  (access/refresh/id/jwt/bearer), API keys, contraseñas, client secrets,
  tarjeta/CVV/PIN, firmas de URL y session ids se tapan en headers, query
  y fragmento (`#access_token=`), cuerpos JSON a cualquier profundidad y
  texto libre (`RedactionPolicy.secretsOnly()`, default de `Thor.run`).
  En texto libre (logs, errores, cuerpos cortados) también caen sin clave
  al lado: JWT sueltos, `Bearer …`, la contraseña de `https://u:pw@host`
  y números de tarjeta (Luhn). Emails, ids, nombres, direcciones, teléfonos, rutas y
  headers normales pasan tal cual: sin eso no se depura un servicio. Los
  valores de estado de blocs no se capturan por defecto.
- **Modo estricto opt-in** para apps sensibles: el comportamiento anterior
  (allowlist con hard-deny, rutas/logs/errores/labels sin `:email`, `:n`,
  `:token`, texto del replay enmascarado, red mínima en exitosas):

  ```dart
  Thor.run(body, redaction: const RedactionPolicy.strict());
  // El replay sigue a esa política (privacy: null); o explícito:
  ThorReplay.start(const ThorReplayConfig(privacy: ThorPrivacy.strict));
  ```
- **Sobrevive al crash**: journal JSONL append-only; sesión sin marca de
  cierre = evidencia del crash, ofrecida al siguiente arranque.
- **El ruido no expulsa lo valioso**: ring buffer por familia con cuota.
- **Apagado = inofensivo**: sin `init`, todos los capturadores son no-op.
- Tiempos siempre **UTC + offset**; IDs estables (sesión/instalación);
  `schemaVersion` en todo artefacto persistido.

## Desarrollo

```bash
dart pub get            # workspace raíz
cd packages/thor
dart analyze            # 0 issues
dart test               # failure-first
```
