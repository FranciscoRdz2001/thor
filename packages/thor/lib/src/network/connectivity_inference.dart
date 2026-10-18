import 'package:clock/clock.dart';

import 'package:thor/src/model/event.dart';
import 'package:thor/src/recorder.dart';

/// Infiere "sin conexión" desde las propias peticiones capturadas, sin
/// plugin (`connectivity_plus` queda como adaptador opcional: ver README).
///
/// Heurística deliberadamente conservadora (un host caído o un typo en una
/// URL NO es "sin red"):
/// - Solo cuentan fallos de red de verdad: `SocketException` con mensaje de
///   DNS/ruta (`Failed host lookup`, `Network is unreachable`, `No route to
///   host`…). `Connection refused` y los timeouts no cuentan: el servidor
///   puede estar caído con el teléfono perfectamente conectado.
/// - Se declara offline con 2 fallos de hosts DISTINTOS, o 3 del mismo host,
///   dentro de `window`.
/// - Se vuelve a online con la primera respuesta HTTP recibida (cualquier
///   código: llegó al servidor).
///
/// Emite `environment {signal: 'connectivity', online: bool}` solo en los
/// cambios, y arranca asumiendo online (sin evento inicial). Costo: una
/// comparación por evento de red; nada por frame ni por timer.
class ConnectivityInference {
  ConnectivityInference._(this._recorder);

  /// Engancha la inferencia a `recorder`. Devuelve la función que la quita.
  static void Function() install(
    ThorRecorder recorder, {
    Duration window = const Duration(seconds: 15),
  }) {
    final inference = ConnectivityInference._(recorder).._window = window;
    return recorder.addListener(inference._onEvent);
  }

  final ThorRecorder _recorder;
  Duration _window = const Duration(seconds: 15);
  bool _online = true;
  final List<({DateTime at, String host})> _failures = [];

  static final _offlineMessage = RegExp(
    'failed host lookup|network is unreachable|no route to host|'
    'nodename nor servname|no address associated|internet connection',
    caseSensitive: false,
  );

  void _onEvent(ThorEvent event) {
    if (event.kind != ThorEventKind.network) return;
    final p = event.payload;
    if (p['statusCode'] != null) {
      _failures.clear();
      _set(online: true);
      return;
    }
    final error = '${p['error'] ?? ''}';
    if (!error.contains('SocketException')) return;
    if (!_offlineMessage.hasMatch('${p['errorMessage'] ?? ''}')) return;
    final now = clock.now();
    _failures
      ..removeWhere((f) => now.difference(f.at) > _window)
      ..add((at: now, host: Uri.tryParse('${p['url'] ?? ''}')?.host ?? ''));
    final hosts = {for (final f in _failures) f.host};
    if (hosts.length >= 2 || _failures.length >= 3) _set(online: false);
  }

  void _set({required bool online}) {
    if (_online == online) return;
    _online = online;
    _recorder.record(ThorEventKind.environment, {
      'signal': 'connectivity',
      'online': online,
    });
  }
}
