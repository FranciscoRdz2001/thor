import 'package:flutter/material.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/replay/wireframe.dart';

/// Marca la UI PROPIA de Thor (burbuja, aviso de crash, inspector, reporte
/// de crash): no es la app que se diagnostica.
///
/// Lo que vive debajo:
/// - no entra al replay (es un [ThorReplayIgnore]);
/// - sus toques no se graban como `interaction` (ver `InteractionCapture`);
/// - no cuenta como pantalla: el observer ignora las rutas `thor/…` y el
///   detector de pantallas no la ve.
class ThorOwnUi extends StatelessWidget {
  /// Marca [child] como UI de Thor.
  const ThorOwnUi({required this.child, super.key});

  /// UI de Thor.
  final Widget child;

  @override
  Widget build(BuildContext context) => ThorReplayIgnore(child: child);
}

/// Páginas a pantalla completa de Thor: una sola puerta para abrirlas.
abstract final class ThorUi {
  /// Prefijo de los nombres de ruta de la UI de Thor.
  static const routePrefix = 'thor/';

  static int _pages = 0;

  /// Cuántas páginas de Thor están abiertas ahora. Mientras sea > 0 el
  /// replay no toma snapshots ni graba dedo (el video se queda en la
  /// última pantalla real de la app).
  static int get openPages => _pages;

  /// Si [route] es de la UI de Thor.
  static bool isThorRoute(Route<dynamic>? route) =>
      route?.settings.name?.startsWith(routePrefix) ?? false;

  /// Abre [builder] como página de Thor [name] (`thor/<name>`). Mientras
  /// está abierta, el grabador deja de registrar navegación e
  /// interacciones (la red, los errores y el entorno siguen).
  static Future<void> push(
    NavigatorState navigator, {
    required String name,
    required WidgetBuilder builder,
  }) async {
    final recorder = ThorCore.instance?.recorder;
    final wasMuted = recorder?.muted ?? false;
    _pages++;
    recorder?.muted = true;
    try {
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (context) => ThorOwnUi(child: builder(context)),
          settings: RouteSettings(name: '$routePrefix$name'),
        ),
      );
    } finally {
      _pages--;
      // Se restaura sobre el grabador VIGENTE (una renovación de sesión
      // pudo cambiarlo mientras la página estaba abierta).
      final current = ThorCore.instance?.recorder;
      if (current != null && _pages == 0) current.muted = wasMuted;
    }
  }

  /// Solo tests.
  static void debugReset() => _pages = 0;
}
