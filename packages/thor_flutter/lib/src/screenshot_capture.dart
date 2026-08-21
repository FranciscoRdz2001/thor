import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Captura de pantalla para los reportes.
///
/// Para la familia de bugs que QA reporta como "se ve mal" (desbordes,
/// texto cortado, overlay encimado) una imagen del instante vale más que
/// toda la línea de tiempo.
///
/// Sin plugins: se pinta el `RenderRepaintBoundary` raíz que Flutter ya
/// mantiene. Escala reducida a propósito — el reporte tiene tope de tamaño
/// y una captura de 3x no aporta nada al diagnóstico.
class ThorScreenshot {
  ThorScreenshot._();

  /// Escala respecto al tamaño lógico. 1.0 basta para ver un desborde.
  static double pixelRatio = 1;

  /// Última captura tomada (PNG). La consume el reporte.
  static Uint8List? latest;

  /// Momento de [latest], para saber si corresponde al fallo.
  static DateTime? latestAtUtc;

  /// Captura la pantalla actual. Devuelve `null` si no hay árbol montado o
  /// el pipeline no está listo — jamás lanza: una captura fallida no puede
  /// tumbar la app que se está diagnosticando.
  static Future<Uint8List?> capture() async {
    try {
      final boundary = _rootBoundary();
      if (boundary == null) return null;
      // Si el layout aún no corrió, pintar revienta; se salta.
      if (boundary.debugNeedsPaint) return null;
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final bytes = data?.buffer.asUint8List();
      if (bytes != null) {
        latest = bytes;
        latestAtUtc = DateTime.now().toUtc();
      }
      return bytes;
    } on Object {
      return null;
    }
  }

  /// Captura y la deja lista para el próximo reporte, sin esperar.
  static void captureInBackground() => unawaited(capture());

  /// Olvida la captura retenida (fin de sesión, privacidad).
  static void clear() {
    latest = null;
    latestAtUtc = null;
  }

  static RenderRepaintBoundary? _rootBoundary() {
    final renderView = WidgetsBinding.instance.rootElement?.renderObject;
    if (renderView == null) return null;
    // El árbol de render arranca en un RenderView; el boundary que
    // Flutter mantiene para composición es su primer hijo.
    RenderRepaintBoundary? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is RenderRepaintBoundary) {
        found = node;
        return;
      }
      node.visitChildren(visit);
    }

    visit(renderView);
    return found;
  }
}

/// Widget opcional que garantiza un boundary propio para la captura.
///
/// No hace falta en apps normales (Flutter ya mantiene uno en la raíz),
/// pero sirve si la app envuelve su árbol de forma que no lo expone.
class ThorScreenshotBoundary extends StatelessWidget {
  /// Envuelve [child] en un `RepaintBoundary`.
  const ThorScreenshotBoundary({required this.child, super.key});

  /// Árbol de la app.
  final Widget child;

  @override
  Widget build(BuildContext context) => RepaintBoundary(child: child);
}
