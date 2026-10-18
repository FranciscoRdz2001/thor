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
- **Instalación y dispositivo**: `meta.iid` es el id de INSTALACIÓN: Thor lo
  guarda en `thor-install-id` dentro de `storageDirectory` y es el mismo en
  cada lanzamiento (sin directorio, en memoria: cambia por lanzamiento; o
  pasa el tuyo con `Thor.run(installId: …)`). `meta.device` trae
  `{os, osVersion, locale, model?, simulator?}`: `model` y `simulator` solo
  cuando se pudieron saber sin plugin (en el simulador de iOS salen de
  `SIMULATOR_*`; en Android se omiten). Para el modelo exacto, tres líneas
  con `device_info_plus` en la app (Thor no lo depende):

  ```dart
  final info = await DeviceInfoPlugin().deviceInfo;
  Thor.run(body, deviceInfo: {
    'model': info is IosDeviceInfo
        ? info.utsname.machine // iPhone16,1
        : (info as AndroidDeviceInfo).model,
    'simulator': '${info is IosDeviceInfo ? !info.isPhysicalDevice
        : !(info as AndroidDeviceInfo).isPhysicalDevice}',
  });
  ```
- **Pantalla y contexto**: la navegación se anota AL INICIO del cambio
  (push de ruta, toque en una tab: el árbol se mira ~50 ms después del
  toque) y no al terminar de cargar, así las peticiones y errores que le
  siguen ya llevan la pantalla nueva; "terminó de cargar" es el
  `screen_load`. Un `pop` nombra la pantalla que de verdad queda visible
  (la que el árbol había afinado, no la ruta raíz). Una clase que sirve a
  muchos contextos (un PLP/búsqueda) se distingue con
  `Thor.setScreenContext('Departamentos > Carnes > Res Selecta')` o, sin
  hacer nada, con el título del AppBar visible (leído en el mismo
  recorrido de quietud): va como `sd` en cada `ev` del replay y
  `screen.detail` en el journal; lo puesto por la app gana sobre el título.
  El `sd` NO se hereda: cambia con cada ruta, se quita si el AppBar que lo
  daba desaparece y, si lo puso la app, al enfocar un campo de texto (la
  consulta va a cambiar; la app lo vuelve a fijar al enviarla). Un diálogo
  o una hoja se nombran `Dialog (DialogRoute<void>)` / `BottomSheet (…)` y
  nunca `DisplayFeatureSubScreen`; la primera pantalla de la sesión
  reemplazada en < 50 ms (`Onboarding` → `Splash`) no queda en la línea de
  tiempo (`skipped` en la siguiente); un `push` de la pantalla que ya está
  encima lleva `duplicate: true`.
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
  `Thor.run(captureLogs: false)` lo apaga. Niveles: `[PERF] …` es info
  (warn solo con `result=error`/`(error)`); `… error 404` y `ERROR RESPONSE
  [4xx]` son warn, solo un 5xx o un fallo real es error, y `ERROR RESPONSE
  [200]` es info. El mismo texto por `print` Y `debugPrint` (< 500 ms) se
  graba una vez.
- **Entrada de texto**: `interaction` `text_focus` trae `length`/`empty` al
  enfocar y, al salir de un campo que cambió, `text_edit {length,
  startLength, empty, edits, source?}` (`source`: `typed` o
  `pasted_or_scanned`, solo con texto de 50 caracteres o más). Jamás el
  contenido; en una contraseña ni el largo.
- **Cuerpos grandes por endpoint**: `Thor.run(bodyRules: [ThorBodyRule(
  pathPattern: r'/CategoryTree', extracts: {'quantity': r'$..quantity'},
  maxBytes: 65536)])` evalúa los JSONPath sobre el cuerpo COMPLETO (hasta
  2 MB, ya sin secretos) y deja `extracts {nombre: {n, sum, min, max,
  values}}` en el evento (`x` en el replay) sin retener el cuerpo; `maxBytes`
  sube el tope de 8 KB solo para esa ruta.
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
  - `startup {ms, until: first_frame|first_screen, screen?}`: de
    `Thor.run` al primer frame rasterizado / a la primera pantalla. Una
    primera ruta reemplazada en ~50 ms (`OnboardingScreen` →
    `SplashBrand`) no cuenta: se mide contra la que se queda.
  - `screen_load {screen, ms, from?, interrupted?, capped?}`: del cambio de
    pantalla a la PRIMERA quietud de su propia carga: UI quieta (reusa la
    detección de `ScreenCapture`; por frame solo se lee un reloj, ~45 ns) y
    red callada (sin peticiones en vuelo ni respuestas de los últimos
    300 ms). No incluye el tiempo del usuario: si toca o teclea antes de que
    termine, se corta ahí con `interrupted: true` (es una cota inferior, no
    una carga completa: los agregados de lentitud deben excluirla), y
    `capped: true` si pasaron 10 s sin quietud.
  - `jank {screen, slow, frozen, worstMs, frames, startAt?}`: por lote de
    frames y con la pantalla vigente al entregarse el lote (≤ ~1 s
    después); `startAt` (UTC) es el inicio del primer frame lento.
  - `freeze {ms, screen, startAt}`: UN frame de 1 s o más, de los mismos
    timings (sin costo extra por frame), en debug, profile y release. La
    pantalla es la vigente cuando EMPEZÓ el frame. Es lo que ve una
    congelada aunque el watchdog de ANR esté apagado. Además deja UN
    problema (`error` con `source: freeze`, uno cada 5 s como máximo) que
    entra a los issues, y, si el watchdog no corre (debug), un frame de 2 s
    o más también sale como `anr {via: 'frame'}` para que el panel de ANR
    no marque 0 con la app congelada.
  - `anr {ms, screen}`: la UI isolate bloqueada ≥ `anrThreshold` (2 s por
    defecto, `Thor.run(anrThreshold: ...)`, `null` lo apaga). Un isolate
    aparte hace ping cada ~umbral/4 (500 ms): sin trabajo por frame, un
    solo ping en vuelo, solo con la app en `resumed` (en segundo plano su
    timer se cancela: no despierta al proceso), no confunde una suspensión
    del SO con un bloqueo, no mantiene viva la app y está apagado en tests
    y con Thor apagado, y también en debug (`kDebugMode`: un breakpoint o
    un hot reload bloquean solo la UI isolate y serían ANR falsos);
    `Thor.run(anrInDebug: true)` lo enciende en debug para builds de QA
    (cada pausa del depurador contará como ANR; avisa por consola). Solo
    ve los ANR que terminan (si el SO mata la app a media espera no hubo
    quién grabarlo). Lleva `startAt`.
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
  - `error` con `source: ui_error`, `type: RawExceptionText`: un `Text`
    visible que ES una excepción (`(error) FormatException: …`, `Null check
    operator…`): la app puso `e.toString()` en la UI.
  - `error` con `source: empty_response {url}`: un GET que contestó 200
    sin cuerpo (una vez por ruta, hasta 5 por sesión).
  - `error` con `source: dead_tap {widget, label, disabled}`: un botón de
    acción tocado sin efecto — deshabilitado (`onPressed: null`) o tocado
    dos veces en 4 s sin navegación, petición, estado ni mensaje entre
    medias (1 s de espera; una vez por botón).
  - `error` con `source: silent_logout`: `setUser(null)` sin un toque del
    usuario en los 5 s previos (la sesión terminó sola).
  - `error` con `source: freeze` (ver `freeze` abajo).
  - `error` con `source: thor` e `internal: true`: un fallo del PROPIO SDK
    (el journal o el archivo del replay no se pueden escribir). Se
    recrea el directorio una vez; si persiste el journal se apaga y avisa
    UNA vez; como máximo 3 por componente y sesión, y no hacen subir la
    sesión del replay.
  - `layout_overflow` sigue viniendo de la aserción de Flutter, así que
    solo existe en debug/profile: en release el framework no avisa.
- **Sesión en segundo plano.** El tiempo fuera de primer plano no es parte
  de la sesión: el reloj del replay se detiene al irse a `paused`/`hidden` y
  al volver deja un registro `{"t":"gap","k":"background","ts","ms","from",
  "wall"}` (`from`/`wall`: hora real UTC de salida y regreso, porque los
  `ts` no cuentan ese tiempo; el
  dash lo excluye de la duración). Si la app pasa
  `Thor.run(sessionTimeout: …)` (30 min por defecto, `null` lo apaga) o más
  en segundo plano, al volver la sesión se cierra (flush, marca de fin,
  última subida del replay) y empieza OTRA con el mismo dispositivo, usuario
  y contexto (`environment session_end` / `session_start {previous}`;
  `Thor.addSessionListener` avisa del nuevo id).
- **Aviso de crash y burbuja (solo QA).** `Thor.run(showOverlay: true)` monta
  la burbuja del inspector y, al arrancar, el aviso "La sesión anterior se
  cayó". En producción dejar `showOverlay: false`. El aviso solo sale si la
  sesión anterior se cayó de verdad (`RecoveredSession.crashed`: un error
  fatal/no manejado, o muerta en primer plano sin cierre limpio; una app
  matada por el usuario o el SO en `paused`/`hidden`/`inactive` NO cuenta),
  es compacto, va arriba (no tapa tabs ni botones de acción), se descarta
  solo a los 6 s y solo captura toques dentro de su recuadro. La UI de Thor
  (burbuja, aviso, inspector, reporte de crash) no cuenta como app: ni
  `navigation`, `screen_load`, `interaction` ni replay.
- **Contexto del dispositivo** (eventos `environment`, `p.signal`; en
  journal, reporte, narrador y replay, sin plugins y sin trabajo por frame:
  son avisos que Flutter ya manda, y cada valor solo se graba si cambió):
  - `lifecycle {state, backgroundMs?}`: `resumed | inactive | paused |
    hidden | detached`. Al volver (`resumed`) trae `backgroundMs`, lo que
    estuvo en segundo plano. Al irse a `paused`/`hidden` el journal se
    escribe a disco (así una app matada ahí no se confunde con un crash).
  - `memory_pressure`: el sistema avisa que anda corto de memoria (espaciado
    a uno cada 5 s). Contexto oro cuando "la app se cerró sola". Los que
    llegan en la ventana de ida/vuelta a segundo plano (2 s tras `inactive`,
    `paused`, `hidden` o `resumed`; iOS lo manda ahí en CADA transición) no
    se graban: son ruido, no presión real.
  - `permission {kind, before?, after?, prompt, source}`: un permiso del
    sistema (cámara, micrófono, voz, ubicación…). La app lo reporta con
    `Thor.permission('camera', after: 'denied', prompt: true)`; además
    Thor lo infiere (`source: error`) de un error de permiso denegado.
  - `external_surface {host, mode, state, ms?}`: la app cedió la pantalla a
    Safari/Custom Tab/otra app/WebView (`Thor.externalSurface(url, mode:)`;
    solo viaja el host). `system_overlay {ms}`: algo del sistema (el
    diálogo de un permiso) estuvo encima ≥ 400 ms sin que la app pasara a
    segundo plano.
  - `previous_session {session, reason, state?, backgroundMs}`: al arrancar,
    cómo terminó la sesión anterior (`clean`, `renewed`, `killed`: la mató
    el usuario o el SO en segundo plano, o `crash`). El replay de esa
    sesión recibe un registro `{"t":"end",…}` con el mismo motivo y los
    segundos en segundo plano (`bg`); una sesión cerrada por la app lo
    escribe al cerrar.
  - `locale {value}` (`es_MX`), `text_scale {value}` (`1.3`) y
    `brightness {value}` (`light | dark`): cambios a media sesión (el par
    dark/light del selector de apps en esa misma ventana no se graba; un
    cambio real ahí se anota al cerrarla). Los
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
- **Sin duplicados en la subida del replay**: cada registro (salvo `blk`,
  que se direcciona por contenido) lleva una secuencia `q` monótona por
  sesión —clave `"q"` en los mapas, ÚLTIMO elemento en los arreglos— para
  que el servidor descarte exacto lo que ya vio por `(sid, q)`. Un solo
  flush corre a la vez (antes dos subidas mandaban el mismo lote), la
  recuperación de sesiones viejas no toca una sesión cuyo dueño sigue
  subiendo (tras renovar la sesión re-subía el tramo en vuelo) y `.sent`
  guarda la última `q` confirmada (`q:N`) con escritura serializada.
  `meta` y `user` se escriben una vez por sesión (`user` solo si la
  identidad cambió); una copia reenviada lleva el mismo `q`.
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
  y números de tarjeta (Luhn). Los códigos de pago (QR/token de cobro:
  claves `qr`, `qrCode`, `codigoPago`, `paymentCode`, `otp`…) son
  secretos, y `RedactionPolicy.secretEndpoints` añade reglas por endpoint
  para los que viajan en un genérico (por defecto, el `data` de
  `monedero/pagar`; `SecretEndpointRule(r'/mi/ruta', keys: {'data'})`,
  sin `keys` oculta el cuerpo entero). Emails, ids, nombres, direcciones, teléfonos, rutas y
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
