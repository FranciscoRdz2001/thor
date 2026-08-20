import 'package:flutter/material.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/overlay/inspector_page.dart';

/// Burbuja flotante de Thor — el punto de entrada de QA en el dispositivo.
///
/// Integración CERO: se inyecta en el `Overlay` del Navigator que ya conoce
/// el `ThorNavigatorObserver` registrado en el router; la app no agrega
/// ningún widget. Arrastrable; tap abre el inspector.
///
/// Mientras el inspector está abierto el grabador queda silenciado
/// ([ThorRecorder.muted]): navegar el inspector no contamina la línea de
/// tiempo que está mostrando.
class ThorOverlayManager {
  ThorOverlayManager._();

  static OverlayEntry? _entry;
  static Offset _position = const Offset(12, 260);
  static bool _open = false;

  /// ¿La burbuja está montada?
  static bool get attached => _entry != null;

  /// Monta la burbuja en el overlay de [navigator] si aún no está.
  /// La llama el observer en el primer push — idempotente y barata.
  ///
  /// En el push INICIAL el Overlay del Navigator todavía no se construyó
  /// (didPush corre en su initState): si aún no hay overlay, se reintenta
  /// al final del frame.
  static void ensureAttached(NavigatorState navigator) {
    if (_entry != null) return;
    final overlay = navigator.overlay;
    if (overlay == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_entry == null && navigator.mounted) {
          ensureAttached(navigator);
        }
      });
      return;
    }
    _entry = OverlayEntry(builder: (context) => const _ThorBubble());
    overlay.insert(_entry!);
  }

  /// Desmonta la burbuja (tests / apagado) y resetea el estado del
  /// inspector — el flag `_open` puede quedar colgado si el route del
  /// inspector nunca hizo pop (p. ej. el test terminó con él abierto).
  static void detach() {
    _entry?.remove();
    _entry = null;
    _open = false;
  }

  static Future<void> _openInspector(BuildContext context) async {
    if (_open) return;
    final core = ThorCore.instance;
    if (core == null) return;
    _open = true;
    // Silencio: lo que QA haga DENTRO del inspector no es parte del bug.
    core.recorder.muted = true;
    try {
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => const ThorInspectorPage(),
          settings: const RouteSettings(name: 'thor/inspector'),
        ),
      );
    } finally {
      core.recorder.muted = false;
      _open = false;
    }
  }
}

class _ThorBubble extends StatefulWidget {
  const _ThorBubble();

  @override
  State<_ThorBubble> createState() => _ThorBubbleState();
}

class _ThorBubbleState extends State<_ThorBubble> {
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Positioned(
      left: ThorOverlayManager._position.dx,
      top: ThorOverlayManager._position.dy,
      child: GestureDetector(
        onPanUpdate: (details) => setState(() {
          final next = ThorOverlayManager._position + details.delta;
          ThorOverlayManager._position = Offset(
            next.dx.clamp(0, size.width - 48),
            next.dy.clamp(0, size.height - 48),
          );
        }),
        onTap: () => ThorOverlayManager._openInspector(context),
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xE6212121),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0x33FFFFFF)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 8,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: const Text(
              '⚡',
              style: TextStyle(fontSize: 22),
            ),
          ),
        ),
      ),
    );
  }
}
