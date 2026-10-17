import 'package:flutter/material.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/overlay/report_share.dart';
import 'package:thor_flutter/src/replay/wireframe.dart';

/// Aviso de sesión muerta: si la sesión anterior no cerró limpio, al
/// arrancar se ofrece su reporte — la evidencia del crash sin que nadie
/// haya apretado nada. Cierra el círculo del journal anti-crash.
class ThorCrashPrompt {
  ThorCrashPrompt._();

  static bool _shown = false;

  /// Muestra el aviso (una sola vez por proceso) si hay una sesión previa
  /// recuperada que terminó mal.
  static void maybeShow(NavigatorState navigator) {
    if (_shown) return;
    final recovered = ThorCore.instance?.recoveredPrevious;
    if (recovered == null || recovered.endedCleanly) return;
    _shown = true;

    final overlay = navigator.overlay;
    if (overlay == null) return;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => ThorReplayIgnore(
        child: _CrashBanner(
          recovered: recovered,
          onDismiss: entry.remove,
          onView: () {
            entry.remove();
            navigator.push(
              MaterialPageRoute<void>(
                builder: (_) => ThorCrashReportPage(recovered: recovered),
                settings: const RouteSettings(name: 'thor/crash-report'),
              ),
            );
          },
        ),
      ),
    );
    overlay.insert(entry);
  }

  /// Solo tests: permite volver a mostrar el aviso.
  @visibleForTesting
  static void debugReset() => _shown = false;
}

class _CrashBanner extends StatelessWidget {
  const _CrashBanner({
    required this.recovered,
    required this.onDismiss,
    required this.onView,
  });

  final RecoveredSession recovered;
  final VoidCallback onDismiss;
  final VoidCallback onView;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 12,
      right: 12,
      bottom: 24 + MediaQuery.paddingOf(context).bottom,
      child: Material(
        color: const Color(0xF2212121),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              const Text('⚡', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'La sesión anterior terminó de forma inesperada.',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: onView,
                child: const Text('Ver reporte'),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                onPressed: onDismiss,
              ),
            ],
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
