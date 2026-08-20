import 'package:bloc/bloc.dart';
import 'package:thor/thor.dart';

/// Observer global de blocs para Thor.
///
/// Una línea captura TODOS los blocs y cubits de la app, presentes y
/// futuros:
///
/// ```dart
/// Bloc.observer = ThorBlocObserver(delegate: const AppBlocObserver());
/// ```
///
/// **Compone, no reemplaza**: `Bloc.observer` es uno solo, así que si la app
/// ya tenía observer (logging, Crashlytics) se pasa como [delegate] y sigue
/// recibiendo todo.
///
/// **PII**: por defecto se graban solo los TIPOS
/// (`PayPressed → CheckoutLoading → CheckoutError`) — esa línea da el 80%
/// del valor de debugging sin fugar nada. Los VALORES solo se capturan si
/// `RedactionPolicy.captureStateValues` es `true`, y aun así pasan por la
/// allowlist.
class ThorBlocObserver extends BlocObserver {
  /// Crea el observer. [delegate] es el observer previo de la app.
  const ThorBlocObserver({this.delegate});

  /// Observer de la app al que se le delega todo (puede ser `null`).
  final BlocObserver? delegate;

  ThorCore? get _core => ThorCore.instance;

  @override
  void onCreate(BlocBase<dynamic> bloc) {
    _record(bloc, 'create', {});
    delegate?.onCreate(bloc);
    super.onCreate(bloc);
  }

  @override
  void onEvent(Bloc<dynamic, dynamic> bloc, Object? event) {
    _record(bloc, 'event', {'event': _describe(event)});
    delegate?.onEvent(bloc, event);
    super.onEvent(bloc, event);
  }

  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    _record(bloc, 'change', {
      'from': _describe(change.currentState),
      'to': _describe(change.nextState),
    });
    delegate?.onChange(bloc, change);
    super.onChange(bloc, change);
  }

  @override
  void onTransition(
    Bloc<dynamic, dynamic> bloc,
    Transition<dynamic, dynamic> transition,
  ) {
    // onChange ya graba from→to; aquí solo se añade el evento disparador
    // cuando existe (solo Bloc, no Cubit).
    delegate?.onTransition(bloc, transition);
    super.onTransition(bloc, transition);
  }

  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    _core?.recorder.record(
      ThorEventKind.error,
      {
        'source': 'bloc',
        'bloc': bloc.runtimeType.toString(),
        'type': error.runtimeType.toString(),
        'message': error.toString(),
        'stack': stackTrace.toString(),
        'fatal': false,
      },
      origin: originFromStack(stackTrace),
    );
    delegate?.onError(bloc, error, stackTrace);
    super.onError(bloc, error, stackTrace);
  }

  @override
  void onClose(BlocBase<dynamic> bloc) {
    _record(bloc, 'close', {});
    delegate?.onClose(bloc);
    super.onClose(bloc);
  }

  void _record(
    BlocBase<dynamic> bloc,
    String action,
    Map<String, Object?> data,
  ) {
    final core = _core;
    if (core == null) return;
    core.recorder.record(ThorEventKind.state, {
      'bloc': bloc.runtimeType.toString(),
      'action': action,
      ...data,
    });
  }

  /// Tipo siempre; valor solo si la política lo permite (y redactado).
  Object? _describe(Object? value) {
    final core = _core;
    final type = value.runtimeType.toString();
    if (core == null || !core.redaction.captureStateValues) return type;
    return {
      'type': type,
      'value': core.redaction.redactValue(_toJsonish(value)),
    };
  }

  static Object? _toJsonish(Object? value) => switch (value) {
        null || bool() || num() || String() => value,
        final Map<Object?, Object?> m => m,
        final List<Object?> l => l,
        _ => value.toString(),
      };
}
