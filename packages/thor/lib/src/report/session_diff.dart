import 'package:thor/src/model/event.dart';
import 'package:thor/src/model/gesture.dart';
import 'package:thor/src/model/session.dart';
import 'package:thor/src/persistence/journal.dart';

/// Un lado de la comparación: sesión + su línea de tiempo.
class ThorDiffSide {
  /// Crea un lado con [label] legible ("la que falla", "la que funciona").
  const ThorDiffSide({
    required this.label,
    required this.session,
    required this.timeline,
  });

  /// Desde una sesión recuperada de journal.
  factory ThorDiffSide.fromRecovered(
    RecoveredSession recovered, {
    String? label,
  }) =>
      ThorDiffSide(
        label: label ?? recovered.session.sessionId,
        session: recovered.session,
        timeline: recovered.events,
      );

  /// Desde el JSON de un reporte exportado (`.thor.json` descomprimido).
  factory ThorDiffSide.fromReportJson(
    Map<String, Object?> json, {
    String? label,
  }) =>
      ThorDiffSide(
        label: label ?? (json['reportId'] as String? ?? '?'),
        session: ThorSession.fromJson(json['session']! as Map<String, Object?>),
        timeline: [
          for (final e in json['timeline']! as List)
            ThorEvent.fromJson(e as Map<String, Object?>),
        ],
      );

  /// Etiqueta para el markdown.
  final String label;

  /// Cabecera de la sesión.
  final ThorSession session;

  /// Eventos en orden.
  final List<ThorEvent> timeline;
}

/// Comparador de sesiones: responde "¿dónde divergieron?" cuando una corrida
/// falla y otra funciona. Nadie reconstruye eso de memoria; con dos
/// timelines estructuradas es un cálculo.
class ThorSessionDiff {
  ThorSessionDiff._();

  /// Compara [a] contra [b] y devuelve el análisis.
  static ThorDiffResult compare(ThorDiffSide a, ThorDiffSide b) {
    return ThorDiffResult._(
      a: a,
      b: b,
      contextDiffs: _contextDiffs(a.session, b.session),
      flow: _flowDivergence(a.timeline, b.timeline),
      network: _networkDiffs(a.timeline, b.timeline),
      environmentOnlyIn: _environmentOnlyIn(a, b),
      errorsOnlyIn: _errorsOnlyIn(a, b),
    );
  }

  // ── Cabeceras: flavor/version/OS/escala… distintos ──
  static List<String> _contextDiffs(ThorSession a, ThorSession b) {
    final diffs = <String>[];
    void compareMaps(
      String kind,
      Map<String, String> ma,
      Map<String, String> mb,
    ) {
      for (final key in {...ma.keys, ...mb.keys}) {
        final va = ma[key];
        final vb = mb[key];
        if (va != vb) {
          diffs.add('$kind.$key: ${va ?? '(ausente)'} ↔ ${vb ?? '(ausente)'}');
        }
      }
    }

    compareMaps('app', a.appInfo, b.appInfo);
    compareMaps('device', a.deviceInfo, b.deviceInfo);
    if (a.utcOffset != b.utcOffset) {
      diffs.add(
        'zona horaria: ${a.utcOffset.inHours}h ↔ ${b.utcOffset.inHours}h',
      );
    }
    return diffs;
  }

  // ── Flujo: primer punto donde los PASOS del usuario divergen ──
  static FlowDivergence _flowDivergence(
    List<ThorEvent> a,
    List<ThorEvent> b,
  ) {
    final stepsA = _stepKeys(a);
    final stepsB = _stepKeys(b);
    var i = 0;
    while (i < stepsA.length && i < stepsB.length && stepsA[i] == stepsB[i]) {
      i++;
    }
    final identical = i == stepsA.length && i == stepsB.length;
    return FlowDivergence(
      commonSteps: i,
      identical: identical,
      lastCommon: i == 0 ? null : stepsA[i - 1],
      nextInA: i < stepsA.length ? stepsA[i] : null,
      nextInB: i < stepsB.length ? stepsB[i] : null,
    );
  }

  static List<String> _stepKeys(List<ThorEvent> timeline) => [
        for (final e in timeline)
          if (e.kind == ThorEventKind.navigation)
            'abrió ${e.payload['to'] ?? e.screen?.display ?? '?'}'
          else if (e.kind == ThorEventKind.interaction &&
              ThorGesture.isPress(e.payload['gesture']))
            'tocó ${e.payload['label'] ?? e.payload['widget'] ?? '?'}',
      ];

  // ── Red: mismo endpoint, resultado distinto (el oro del diff) ──
  static List<String> _networkDiffs(List<ThorEvent> a, List<ThorEvent> b) {
    Map<String, Set<String>> outcomes(List<ThorEvent> t) {
      final map = <String, Set<String>>{};
      for (final e in t) {
        if (e.kind != ThorEventKind.network) continue;
        final uri = Uri.tryParse(e.payload['url'] as String? ?? '');
        final key = '${e.payload['method']} ${uri?.path ?? '?'}';
        final outcome =
            (e.payload['statusCode'] ?? e.payload['error'] ?? '?').toString();
        map.putIfAbsent(key, () => {}).add(outcome);
      }
      return map;
    }

    final oa = outcomes(a);
    final ob = outcomes(b);
    final diffs = <String>[];
    for (final key in {...oa.keys, ...ob.keys}) {
      final sa = oa[key];
      final sb = ob[key];
      if (sa == null) {
        diffs.add('$key: solo ocurre en B (${sb!.join(',')})');
      } else if (sb == null) {
        diffs.add('$key: solo ocurre en A (${sa.join(',')})');
      } else if (sa.join(',') != sb.join(',')) {
        diffs.add('$key: A=${sa.join(',')} ↔ B=${sb.join(',')}');
      }
    }
    return diffs;
  }

  // ── Señales de entorno presentes en un solo lado ──
  static Map<String, List<String>> _environmentOnlyIn(
    ThorDiffSide a,
    ThorDiffSide b,
  ) {
    Set<String> signals(List<ThorEvent> t) => {
          for (final e in t)
            if (e.kind == ThorEventKind.environment)
              [
                e.payload['signal'],
                if (e.payload['value'] != null) e.payload['value'],
                if (e.payload['state'] != null) e.payload['state'],
                if (e.payload['online'] != null) e.payload['online'],
              ].join(':'),
        };
    final sa = signals(a.timeline);
    final sb = signals(b.timeline);
    return {
      a.label: sa.difference(sb).toList(),
      b.label: sb.difference(sa).toList(),
    };
  }

  // ── Errores presentes en un solo lado (por huella) ──
  static Map<String, List<String>> _errorsOnlyIn(
    ThorDiffSide a,
    ThorDiffSide b,
  ) {
    Set<String> fingerprints(List<ThorEvent> t) => {
          for (final e in t)
            if (e.kind == ThorEventKind.error)
              '${e.payload['type']}@${e.origin ?? e.payload['source']}',
        };
    final fa = fingerprints(a.timeline);
    final fb = fingerprints(b.timeline);
    return {
      a.label: fa.difference(fb).toList(),
      b.label: fb.difference(fa).toList(),
    };
  }
}

/// Punto de divergencia del flujo de usuario.
class FlowDivergence {
  /// Crea el resultado del alineamiento de pasos.
  const FlowDivergence({
    required this.commonSteps,
    required this.identical,
    this.lastCommon,
    this.nextInA,
    this.nextInB,
  });

  /// Pasos idénticos desde el inicio.
  final int commonSteps;

  /// `true` si ambos flujos son exactamente iguales.
  final bool identical;

  /// Último paso compartido.
  final String? lastCommon;

  /// Siguiente paso en A tras el punto común (null = A terminó ahí).
  final String? nextInA;

  /// Siguiente paso en B tras el punto común (null = B terminó ahí).
  final String? nextInB;
}

/// Resultado completo del diff, con render a markdown.
class ThorDiffResult {
  ThorDiffResult._({
    required this.a,
    required this.b,
    required this.contextDiffs,
    required this.flow,
    required this.network,
    required this.environmentOnlyIn,
    required this.errorsOnlyIn,
  });

  /// Lado A.
  final ThorDiffSide a;

  /// Lado B.
  final ThorDiffSide b;

  /// Diferencias de cabecera (flavor, versión, dispositivo, zona).
  final List<String> contextDiffs;

  /// Divergencia del flujo de pasos.
  final FlowDivergence flow;

  /// Endpoints con resultado distinto o presentes en un solo lado.
  final List<String> network;

  /// Señales de entorno exclusivas de cada lado.
  final Map<String, List<String>> environmentOnlyIn;

  /// Huellas de error exclusivas de cada lado.
  final Map<String, List<String>> errorsOnlyIn;

  /// ¿Hay algo que reportar?
  bool get hasDifferences =>
      contextDiffs.isNotEmpty ||
      !flow.identical ||
      network.isNotEmpty ||
      environmentOnlyIn.values.any((v) => v.isNotEmpty) ||
      errorsOnlyIn.values.any((v) => v.isNotEmpty);

  /// Markdown del análisis — para ticket, chat o tool MCP.
  String toMarkdown() {
    final buffer = StringBuffer()
      ..writeln('## Diff de sesiones: A=${a.label} · B=${b.label}')
      ..writeln();
    if (!hasDifferences) {
      buffer.writeln('Sin diferencias relevantes entre las dos sesiones.');
      return buffer.toString();
    }
    if (contextDiffs.isNotEmpty) {
      buffer.writeln('### Contexto distinto');
      for (final d in contextDiffs) {
        buffer.writeln('- $d');
      }
      buffer.writeln();
    }
    buffer.writeln('### Flujo');
    if (flow.identical) {
      buffer.writeln('- Mismos pasos en ambas (${flow.commonSteps}).');
    } else {
      buffer
        ..writeln('- Comparten los primeros ${flow.commonSteps} pasos'
            '${flow.lastCommon == null ? '' : ' (último común: '
                '«${flow.lastCommon}»)'}.')
        ..writeln('- Después, A: '
            '${flow.nextInA ?? '(terminó)'} · B: '
            '${flow.nextInB ?? '(terminó)'}');
    }
    buffer.writeln();
    if (network.isNotEmpty) {
      buffer.writeln('### Red — mismo endpoint, resultado distinto');
      for (final d in network) {
        buffer.writeln('- $d');
      }
      buffer.writeln();
    }
    for (final MapEntry(:key, :value) in environmentOnlyIn.entries) {
      if (value.isEmpty) continue;
      buffer
        ..writeln('### Señales de entorno solo en $key')
        ..writeln(value.map((v) => '- $v').join('\n'))
        ..writeln();
    }
    for (final MapEntry(:key, :value) in errorsOnlyIn.entries) {
      if (value.isEmpty) continue;
      buffer
        ..writeln('### Errores solo en $key')
        ..writeln(value.map((v) => '- $v').join('\n'))
        ..writeln();
    }
    return buffer.toString();
  }
}
