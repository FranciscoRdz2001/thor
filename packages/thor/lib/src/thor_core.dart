import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:meta/meta.dart';

import 'package:thor/src/model/event.dart';
import 'package:thor/src/model/session.dart';
import 'package:thor/src/network/raw_network_store.dart';
import 'package:thor/src/persistence/journal.dart';
import 'package:thor/src/recorder.dart';
import 'package:thor/src/redaction/redaction_policy.dart';
import 'package:thor/src/store/event_store.dart';

/// Proveedor de contexto de dominio: se llama al generar un reporte para
/// fotografiar estado de negocio (cola de sync, turno abierto…).
typedef ThorContextProvider = Map<String, Object?> Function();

/// Fachada del núcleo de Thor.
///
/// Dart puro: no sabe de Flutter, dio ni bloc. Los adaptadores se cuelgan de
/// [recorder] y de los hooks públicos. `thor_flutter` expone el `Thor.run`
/// de alto nivel; esta clase es el motor debajo.
class ThorCore {
  ThorCore._({
    required this.recorder,
    required this.store,
    required this.session,
    required this.redaction,
    this.journal,
  });

  /// Instancia activa. `null` hasta [init] — los adaptadores deben tratar
  /// ese caso como no-op, jamás como error (Thor apagado no puede romper
  /// la app que diagnostica).
  static ThorCore? get instance => _instance;
  static ThorCore? _instance;

  /// Grabador central (los adaptadores registran a través de él).
  final ThorRecorder recorder;

  /// Almacén en memoria.
  final EventStore store;

  /// Sesión actual.
  final ThorSession session;

  /// Política de redacción vigente.
  final RedactionPolicy redaction;

  /// Journal en disco; `null` si se inicializó sin persistencia (tests,
  /// plataformas sin FS).
  final SessionJournal? journal;

  final Map<String, ThorContextProvider> _contextProviders = {};
  void Function()? _unsubscribeJournal;

  /// Sesión previa recuperada en [init]; si `endedCleanly == false`, la app
  /// murió y este es el material del reporte de crash.
  RecoveredSession? recoveredPrevious;

  /// Inicializa Thor. Idempotente: llamadas repetidas devuelven la
  /// instancia existente.
  ///
  /// - [storageDirectory]: dónde persistir journals (privado de la app).
  ///   `null` = solo memoria.
  /// - [installId]: identificador de instalación persistente; el adaptador
  ///   de Flutter lo provee. Si falta, se genera uno efímero.
  static Future<ThorCore> init({
    Directory? storageDirectory,
    RedactionPolicy redaction = const RedactionPolicy.strict(),
    BufferQuotas? quotas,
    String? installId,
    Map<String, String> appInfo = const {},
    Map<String, String> deviceInfo = const {},
  }) async {
    final existing = _instance;
    if (existing != null) return existing;

    final now = clock.now();
    final session = ThorSession(
      sessionId: generateThorId(),
      installId: installId ?? generateThorId(),
      startedAtUtc: now.toUtc(),
      utcOffset: now.timeZoneOffset,
      appInfo: appInfo,
      deviceInfo: deviceInfo,
    );
    final store = EventStore(quotas: quotas);
    final recorder = ThorRecorder(store: store);

    SessionJournal? journal;
    RecoveredSession? recovered;
    if (storageDirectory != null) {
      // Primero mirar si la sesión anterior murió sin cerrar…
      recovered = await SessionJournal.recoverPrevious(storageDirectory);
      // …y luego abrir el journal propio.
      journal = SessionJournal(directory: storageDirectory, session: session);
      await journal.start();
    }

    final core = ThorCore._(
      recorder: recorder,
      store: store,
      session: session,
      redaction: redaction,
      journal: journal,
    )..recoveredPrevious = recovered;

    if (journal != null) {
      // Los errores van a disco de inmediato: si la app está por morir,
      // la causa ya tiene que estar escrita.
      core._unsubscribeJournal = recorder.addListener(
        (event) =>
            journal!.append(event, urgent: event.kind == ThorEventKind.error),
      );
    }

    return _instance = core;
  }

  /// Marca libre en la línea de tiempo (`Thor.mark('cobro_iniciado')`).
  void mark(String label, [Map<String, Object?> data = const {}]) {
    recorder.record(ThorEventKind.log, {
      'label': label,
      if (data.isNotEmpty) 'data': redaction.redactValue(data),
    });
  }

  /// Fija la pantalla activa manualmente — para navegación que el Navigator
  /// no ve (tabs, PageView, wizards internos).
  void setScreen(String name) {
    recorder.currentScreen = ScreenId(widgetClass: name);
    recorder.record(ThorEventKind.navigation, {
      'action': 'manual',
      'to': name,
    });
  }

  /// Registra un proveedor de contexto de dominio bajo [key].
  void addContext(String key, ThorContextProvider provider) {
    _contextProviders[key] = provider;
  }

  /// Fotografía todos los contextos registrados (redactados). Un proveedor
  /// que lanza no tumba a los demás: su error queda como su propio valor.
  Map<String, Object?> snapshotContext() => {
        for (final MapEntry(:key, value: provider) in _contextProviders.entries)
          key: _safeContext(provider),
      };

  Object? _safeContext(ThorContextProvider provider) {
    try {
      return redaction.redactValue(provider());
    } on Object catch (e) {
      return {'error': 'proveedor de contexto lanzó: $e'};
    }
  }

  /// Cierre limpio (sesión terminó bien). Tras esto, [instance] es `null`.
  Future<void> dispose() async {
    // Los cURLs crudos son de ESTA sesión: mueren con ella.
    RawNetworkStore.clear();
    _unsubscribeJournal?.call();
    await journal?.close();
    if (identical(_instance, this)) _instance = null;
  }

  /// Solo tests: resetea el singleton sin cierre limpio (simula crash).
  @visibleForTesting
  static void debugReset() => _instance = null;
}
