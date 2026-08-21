# Thor

SDK de diagnóstico para Flutter: captura navegación, red, errores,
interacciones y estado en **una línea de tiempo correlacionada**, genera
pasos de reproducción automáticos para QA y reportes con `archivo:línea`
para que el dev (o una IA) llegue del síntoma al código.

## Paquetes

| Paquete | Rol | Estado |
|---|---|---|
| `packages/thor` | Núcleo Dart puro: eventos, buffers, redacción allowlist, journal anti-crash, red por HttpOverrides, narrador, agregados, reporte .gz | ✅ |
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
- **Test de reproducción**: `ThorReproTestBuilder.build(timeline)` emite el
  esqueleto del `integration_test` con los pasos exactos. Los valores de los
  campos y la aserción van marcados `TODO` — Thor sabe qué pasó, no qué
  DEBERÍA pasar, y no filtra contenido de campos al test.

## Principios

- **3 líneas de integración**, nada por ruta/bloc/petición.
- **Fail-closed en PII**: redacción por allowlist con hard-deny; los valores
  de estado no se capturan por defecto.
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
