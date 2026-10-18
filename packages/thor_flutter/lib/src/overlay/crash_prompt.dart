import 'dart:async';

import 'package:flutter/material.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/overlay/report_share.dart';
import 'package:thor_flutter/src/overlay/thor_ui.dart';

/// Aviso de sesión caída: si la sesión anterior REALMENTE se cayó, al
/// arrancar se ofrece su reporte — la evidencia del crash sin que nadie
/// haya apretado nada. Cierra el círculo del journal anti-crash.
///
/// "Se cayó" = [RecoveredSession.crashed]: un error fatal/no manejado
/// grabado, o la app muerta en primer plano sin cierre limpio. Una sesión
/// que el usuario o el SO mataron en segundo plano NO lo dispara.
///
/// Es una herramienta de QA, igual que la burbuja: solo existe con
/// `Thor.run(showOverlay: true)`. En producción dejar `showOverlay: false`.
///
/// Es chico, va ARRIBA (no tapa la barra de tabs ni los botones de
/// acción), se descarta solo a los [autoDismiss] y solo captura toques
/// dentro de su propio rectángulo.
class ThorCrashPrompt {
  ThorCrashPrompt._();

  static bool _shown = false;

  /// Cuánto se queda en pantalla antes de descartarse solo.
  static Duration autoDismiss = const Duration(seconds: 6);

  /// Muestra el aviso (una sola vez por proceso) si hay una sesión previa
  /// recuperada que se cayó de verdad.
  static void maybeShow(NavigatorState navigator) {
    if (_shown) return;
    final recovered = ThorCore.instance?.recoveredPrevious;
    if (recovered == null || !recovered.crashed) return;
    _shown = true;

    final overlay = navigator.overlay;
    if (overlay == null) return;
    OverlayEntry? entry;
    Timer? timer;
    void dismiss() {
      timer?.cancel();
      final e = entry;
      entry = null;
      if (e != null && e.mounted) e.remove();
    }

    entry = OverlayEntry(
      builder: (context) => ThorOwnUi(
        child: _CrashBanner(
          onDismiss: dismiss,
          onView: () {
            dismiss();
            unawaited(
              ThorUi.push(
                navigator,
                name: 'crash-report',
                builder: (_) => ThorCrashReportPage(recovered: recovered),
              ),
            );
          },
        ),
      ),
    );
    overlay.insert(entry!);
    timer = Timer(autoDismiss, dismiss);
  }

  /// Solo tests: permite volver a mostrar el aviso.
  @visibleForTesting
  static void debugReset() {
    _shown = false;
    autoDismiss = const Duration(seconds: 6);
  }
}

class _CrashBanner extends StatelessWidget {
  const _CrashBanner({required this.onDismiss, required this.onView});

  final VoidCallback onDismiss;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    // Arriba y compacto: abajo viven la barra de tabs y los botones de
    // acción de la app. Sin `left`/`right` y con `Align`, el Positioned
    // mide lo que mide su contenido: nada fuera de él recibe toques.
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 4,
      left: 0,
      right: 0,
      child: Align(
        alignment: Alignment.topCenter,
        child: Material(
          color: const Color(0xF2212121),
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 2, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('⚡', style: TextStyle(fontSize: 14)),
                const SizedBox(width: 6),
                const Text(
                  'La sesión anterior se cayó',
                  style: TextStyle(color: Colors.white, fontSize: 12),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: onView,
                  child: const Text('Ver', style: TextStyle(fontSize: 12)),
                ),
                IconButton(
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    Icons.close,
                    color: Colors.white54,
                    size: 16,
                  ),
                  onPressed: onDismiss,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Reporte de la sesión que murió: pasos narrados + compartir.
class ThorCrashReportPage extends StatelessWidget {
  /// Crea la página con la sesión recuperada.
  const ThorCrashReportPage({required this.recovered, super.key});

  /// Sesión previa recuperada del journal.
  final RecoveredSession recovered;

  @override
  Widget build(BuildContext context) {
    final report = ThorReport.fromRecovered(recovered);
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Sesión anterior (crash)'),
          actions: [
            IconButton(
              tooltip: 'Compartir reporte',
              icon: const Icon(Icons.ios_share),
              onPressed: () async {
                final outcome = await ThorReportSharer.share(report);
                if (context.mounted &&
                    outcome == ThorShareOutcome.copiedToClipboard) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Reporte copiado al portapapeles'),
                    ),
                  );
                }
              },
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: SingleChildScrollView(
            child: SelectableText(
              report.toMarkdown(),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
      ),
    );
  }
}
