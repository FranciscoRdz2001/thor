# Thor

SDK de diagnóstico para Flutter: captura navegación, red, errores,
interacciones y estado en **una línea de tiempo correlacionada**, genera
pasos de reproducción automáticos para QA y reportes con `archivo:línea`
para que el dev (o una IA) llegue del síntoma al código.

## Paquetes

| Paquete | Rol | Estado |
|---|---|---|
| `packages/thor` | Núcleo Dart puro: eventos, buffers por familia, redacción allowlist, journal resistente a crashes | ✅ |
| `packages/thor_flutter` | NavigatorObserver, errores de framework, interacciones, contexto de dispositivo | pendiente |
| `packages/thor_dio` / red global | Captura HTTP vía `HttpOverrides.global` + detalle dio | pendiente |
| `packages/thor_bloc` | Observer de blocs (tipos por defecto, valores por allowlist) | pendiente |

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
