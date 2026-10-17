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
  contraseña visible) ni nada dentro de `ThorReplayIgnore`.
  `ThorReplayConfig(maskText: true)` enmascara el texto (largos de
  palabra) sin tocar el resto.
- **Test de reproducción**: `ThorReproTestBuilder.build(timeline)` emite el
  esqueleto del `integration_test` con los pasos exactos. Los valores de los
  campos y la aserción van marcados `TODO` — Thor sabe qué pasó, no qué
  DEBERÍA pasar, y no filtra contenido de campos al test.

## Principios

- **3 líneas de integración**, nada por ruta/bloc/petición.
- **Solo secretos por defecto**: `Authorization`, cookies, tokens
  (access/refresh/id/jwt/bearer), API keys, contraseñas, client secrets,
  tarjeta/CVV/PIN se tapan en headers, query, cuerpos JSON a cualquier
  profundidad y texto libre (`RedactionPolicy.secretsOnly()`, default de
  `Thor.run`). Emails, ids, nombres, direcciones, teléfonos, rutas y
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
