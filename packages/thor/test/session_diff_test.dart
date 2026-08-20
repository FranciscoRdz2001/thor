import 'package:test/test.dart';
import 'package:thor/thor.dart';

ThorSession _session(String id, {Map<String, String> app = const {}}) =>
    ThorSession(
      sessionId: id,
      installId: 'i-$id',
      startedAtUtc: DateTime.utc(2026, 8, 20),
      utcOffset: const Duration(hours: -7),
      appInfo: app,
    );

ThorEvent _e(
  int seq,
  ThorEventKind kind,
  Map<String, Object?> payload, {
  String? origin,
}) =>
    ThorEvent(
      seq: seq,
      kind: kind,
      atUtc: DateTime.utc(2026, 8, 20, 12, 0, seq),
      utcOffset: Duration.zero,
      origin: origin,
      payload: payload,
    );

List<ThorEvent> _loginFlow({required int status, bool withError = false}) => [
      _e(0, ThorEventKind.navigation, {'action': 'push', 'to': 'LoginPage'}),
      _e(
        1,
        ThorEventKind.interaction,
        {'widget': 'ElevatedButton', 'label': 'Entrar'},
      ),
      _e(2, ThorEventKind.network, {
        'method': 'POST',
        'url': 'https://api.x/auth/login',
        'statusCode': status,
        'durationMs': 100,
      }),
      if (withError)
        _e(
          3,
          ThorEventKind.error,
          {'type': 'StateError'},
          origin: 'package:app/login.dart:88',
        ),
    ];

void main() {
  group('ThorSessionDiff', () {
    test('sesiones idénticas: sin diferencias', () {
      final result = ThorSessionDiff.compare(
        ThorDiffSide(
          label: 'A',
          session: _session('a'),
          timeline: _loginFlow(status: 200),
        ),
        ThorDiffSide(
          label: 'B',
          session: _session('b'),
          timeline: _loginFlow(status: 200),
        ),
      );
      expect(result.hasDifferences, isFalse);
      expect(result.toMarkdown(), contains('Sin diferencias'));
    });

    test('mismo endpoint con resultado distinto — el caso central', () {
      final result = ThorSessionDiff.compare(
        ThorDiffSide(
          label: 'falla',
          session: _session('a'),
          timeline: _loginFlow(status: 500, withError: true),
        ),
        ThorDiffSide(
          label: 'funciona',
          session: _session('b'),
          timeline: _loginFlow(status: 200),
        ),
      );
      expect(result.hasDifferences, isTrue);
      expect(
        result.network.single,
        contains('POST /auth/login: A=500 ↔ B=200'),
      );
      // El error solo existe en la que falla, con su huella.
      expect(
        result.errorsOnlyIn['falla'],
        ['StateError@package:app/login.dart:88'],
      );
      expect(result.errorsOnlyIn['funciona'], isEmpty);
      // El flujo de PASOS fue idéntico: la divergencia es de red, no de uso.
      expect(result.flow.identical, isTrue);
    });

    test('flujos que divergen: reporta el punto exacto', () {
      final a = [
        _e(0, ThorEventKind.navigation, {'action': 'push', 'to': 'Home'}),
        _e(1, ThorEventKind.interaction, {'label': 'Cobrar'}),
        _e(2, ThorEventKind.interaction, {'label': 'Confirmar'}),
      ];
      final b = [
        _e(0, ThorEventKind.navigation, {'action': 'push', 'to': 'Home'}),
        _e(1, ThorEventKind.interaction, {'label': 'Cobrar'}),
        _e(2, ThorEventKind.interaction, {'label': 'Cancelar'}),
      ];
      final result = ThorSessionDiff.compare(
        ThorDiffSide(label: 'A', session: _session('a'), timeline: a),
        ThorDiffSide(label: 'B', session: _session('b'), timeline: b),
      );
      expect(result.flow.commonSteps, 2);
      expect(result.flow.lastCommon, 'tocó Cobrar');
      expect(result.flow.nextInA, 'tocó Confirmar');
      expect(result.flow.nextInB, 'tocó Cancelar');
    });

    test('contexto distinto: flavor y zona horaria salen en el diff', () {
      final result = ThorSessionDiff.compare(
        ThorDiffSide(
          label: 'A',
          session: _session('a', app: {'flavor': 'staging'}),
          timeline: const [],
        ),
        ThorDiffSide(
          label: 'B',
          session: ThorSession(
            sessionId: 'b',
            installId: 'i-b',
            startedAtUtc: DateTime.utc(2026, 8, 20),
            utcOffset: const Duration(hours: -6),
            appInfo: const {'flavor': 'production'},
          ),
          timeline: const [],
        ),
      );
      expect(
        result.contextDiffs,
        containsAll(<String>[
          'app.flavor: staging ↔ production',
          'zona horaria: -7h ↔ -6h',
        ]),
      );
    });

    test('señal de entorno solo en un lado (la red se cayó en A)', () {
      final result = ThorSessionDiff.compare(
        ThorDiffSide(
          label: 'A',
          session: _session('a'),
          timeline: [
            ..._loginFlow(status: 200),
            _e(
              9,
              ThorEventKind.environment,
              {'signal': 'connectivity', 'value': 'none'},
            ),
          ],
        ),
        ThorDiffSide(
          label: 'B',
          session: _session('b'),
          timeline: _loginFlow(status: 200),
        ),
      );
      expect(result.environmentOnlyIn['A'], ['connectivity:none']);
      expect(result.toMarkdown(), contains('solo en A'));
    });

    test('petición presente solo en un lado', () {
      final extra = [
        ..._loginFlow(status: 200),
        _e(9, ThorEventKind.network, {
          'method': 'GET',
          'url': 'https://api.x/flags',
          'statusCode': 200,
          'durationMs': 20,
        }),
      ];
      final result = ThorSessionDiff.compare(
        ThorDiffSide(
          label: 'A',
          session: _session('a'),
          timeline: extra,
        ),
        ThorDiffSide(
          label: 'B',
          session: _session('b'),
          timeline: _loginFlow(status: 200),
        ),
      );
      expect(result.network.single, contains('solo ocurre en A'));
    });

    test('roundtrip: un lado construido desde el JSON de un reporte', () {
      ThorCore.debugReset();
      final side = ThorDiffSide.fromReportJson({
        'reportId': 'r1',
        'session': _session('a', app: {'flavor': 'qa'}).toJson(),
        'timeline': [for (final e in _loginFlow(status: 500)) e.toJson()],
      });
      expect(side.session.appInfo['flavor'], 'qa');
      expect(side.timeline, hasLength(3));
      expect(side.label, 'r1');
    });
  });
}
