import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:test/test.dart';
import 'package:thor/thor.dart';
import 'package:thor_bloc/thor_bloc.dart';

sealed class CobroEvent {}

final class PayPressed extends CobroEvent {}

final class ExplotaPressed extends CobroEvent {}

sealed class CobroState {}

final class CobroIdle extends CobroState {}

final class CobroLoading extends CobroState {}

class CobroBloc extends Bloc<CobroEvent, CobroState> {
  CobroBloc() : super(CobroIdle()) {
    on<PayPressed>((event, emit) => emit(CobroLoading()));
    on<ExplotaPressed>((event, emit) => throw StateError('kaboom'));
  }
}

class _SpyObserver extends BlocObserver {
  final List<String> calls = [];
  @override
  void onCreate(BlocBase<dynamic> bloc) {
    calls.add('create');
    super.onCreate(bloc);
  }

  @override
  void onChange(BlocBase<dynamic> bloc, Change<dynamic> change) {
    calls.add('change');
    super.onChange(bloc, change);
  }

  @override
  void onError(BlocBase<dynamic> bloc, Object error, StackTrace stackTrace) {
    calls.add('error');
    super.onError(bloc, error, stackTrace);
  }
}

void main() {
  late _SpyObserver appObserver;

  setUp(() async {
    ThorCore.debugReset();
    await ThorCore.init();
    appObserver = _SpyObserver();
    Bloc.observer = ThorBlocObserver(delegate: appObserver);
  });

  tearDown(() {
    Bloc.observer = _SpyObserver(); // inerte: solo acumula en su instancia
    ThorCore.debugReset();
  });

  List<ThorEvent> stateEvents() =>
      ThorCore.instance!.store.ofKind(ThorEventKind.state);

  test('transición graba SOLO tipos por defecto (jamás valores)', () async {
    final bloc = CobroBloc()..add(PayPressed());
    await Future<void>.delayed(Duration.zero);

    final change = stateEvents().lastWhere(
      (e) => e.payload['action'] == 'change',
    );
    expect(change.payload['bloc'], 'CobroBloc');
    expect(change.payload['from'], 'CobroIdle');
    expect(change.payload['to'], 'CobroLoading');
    await bloc.close();
  });

  test('el observer de la app SIGUE recibiendo todo (delegación)', () async {
    final bloc = CobroBloc()..add(PayPressed());
    await Future<void>.delayed(Duration.zero);
    await bloc.close();

    expect(appObserver.calls, containsAll(<String>['create', 'change']));
  });

  test('onError va a la familia error con el bloc como fuente', () async {
    // Bloc RELANZA el error del handler tras onError (por diseño): se
    // contiene en una zona para poder afirmar sobre lo grabado.
    await runZonedGuarded(
      () async {
        final bloc = CobroBloc()..add(ExplotaPressed());
        await Future<void>.delayed(Duration.zero);
        await bloc.close();
      },
      (_, __) {},
    );

    final errors = ThorCore.instance!.store.ofKind(ThorEventKind.error);
    expect(errors, isNotEmpty);
    expect(errors.last.payload['source'], 'bloc');
    expect(errors.last.payload['bloc'], 'CobroBloc');
    expect(appObserver.calls, contains('error'));
  });

  test('ciclo de vida: create y close quedan en la línea de tiempo', () async {
    final bloc = CobroBloc();
    await bloc.close();
    final actions = stateEvents().map((e) => e.payload['action']).toList();
    expect(actions, containsAll(<String>['create', 'close']));
  });

  test('Thor apagado: el observer delega y no revienta', () async {
    ThorCore.debugReset();
    final bloc = CobroBloc()..add(PayPressed());
    await Future<void>.delayed(Duration.zero);
    await bloc.close();
    expect(appObserver.calls, contains('change'));
  });
}
