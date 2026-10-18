import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/performance_capture.dart';
import 'package:thor_flutter/src/replay/replay_capture.dart';
import 'package:thor_flutter/src/ui_health_capture.dart';

/// Vida de la sesión en segundo plano.
///
/// Una app que se queda horas en background no es UNA sesión larga: es la
/// sesión que se fue y otra que empieza al volver (la duración y los
/// promedios de la anterior quedaban inflados). Si la app pasa en segundo
/// plano [timeout] o más, al volver (`resumed`) se cierra la sesión
/// (ráfagas, flush, marca de fin en el journal, última subida del replay)
/// y arranca una nueva con el mismo dispositivo, usuario y contexto.
///
/// Se evalúa al volver y no con un timer: en segundo plano los timers no
/// son confiables y no hay nada que cerrar que no pueda cerrarse al
/// regresar. Si el SO mata la app ahí, el journal queda sin cierre pero con
/// `paused` como último estado: se lee como "matada", no como crash.
class SessionLifetime with WidgetsBindingObserver {
  SessionLifetime._(this.timeout, this._onRenewed);

  static SessionLifetime? _instance;

  /// Reloj de pared. Sustituible en tests.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// Tiempo en segundo plano a partir del cual la sesión se renueva.
  final Duration timeout;

  final void Function() _onRenewed;

  DateTime? _backgroundAt;
  bool _renewing = false;

  /// Instala la vigilancia. Idempotente. [onRenewed] corre tras arrancar la
  /// sesión nueva (avisa a los listeners de sesión).
  static void install(Duration timeout, {required void Function() onRenewed}) {
    if (_instance != null) return;
    final lifetime = SessionLifetime._(timeout, onRenewed);
    _instance = lifetime;
    WidgetsBinding.instance.addObserver(lifetime);
  }

  /// Solo tests.
  @visibleForTesting
  static void uninstall() {
    final lifetime = _instance;
    if (lifetime == null) return;
    WidgetsBinding.instance.removeObserver(lifetime);
    _instance = null;
    now = DateTime.now;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _backgroundAt ??= now();
      case AppLifecycleState.resumed:
        final since = _backgroundAt;
        _backgroundAt = null;
        if (since != null && now().difference(since) >= timeout) {
          unawaited(renew());
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Cierra la sesión vigente y arranca una nueva. Visible para tests.
  @visibleForTesting
  Future<void> renew() async {
    if (_renewing) return;
    _renewing = true;
    try {
      final core = ThorCore.instance;
      if (core == null) return;
      await ThorReplay.renewAround(() async {
        await core.renewSession(reason: 'background_timeout');
        // Los capturadores que escuchan al grabador viejo pasan al nuevo.
        PerformanceCapture.attach();
        UiHealthCapture.attach();
      });
      _onRenewed();
    } on Object {
      // Renovar la sesión jamás debe tumbar a la app.
    } finally {
      _renewing = false;
    }
  }
}
