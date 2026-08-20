import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';

import 'package:thor/src/model/event.dart';
import 'package:thor/src/model/session.dart';
import 'package:thor/src/persistence/journal.dart';
import 'package:thor/src/recorder.dart';
import 'package:thor/src/report/aggregates.dart';
import 'package:thor/src/report/narrator.dart';
import 'package:thor/src/thor_core.dart';

/// Reporte autocontenido de Thor: el artefacto que QA entrega.
///
/// Un solo JSON (con variante `.gz`) con `schemaVersion`, IDs estables,
/// UTC+offset, origen, pasos narrados, agregados y el timeline completo —
/// listo para adjuntarse a un ticket hoy y para el POST a la plataforma de
/// pruebas cuando exista (`Thor.onReport`).
class ThorReport {
  ThorReport._({
    required this.reportId,
    required this.origin,
    required this.session,
    required this.generatedAtUtc,
    required this.narrative,
    required this.timeline,
    required this.context,
    required this.aggregates,
    required this.evicted,
    this.note,
  });

  /// Construye el reporte de la sesión ACTIVA.
  ///
  /// [note]: texto libre de QA ("esperaba que guardara el cobro").
  factory ThorReport.fromCore(
    ThorCore core, {
    ThorReportOrigin origin = ThorReportOrigin.manual,
    String? note,
  }) {
    final timeline = core.store.timeline();
    return ThorReport._(
      reportId: generateThorId(),
      origin: origin,
      session: core.session,
      generatedAtUtc: clock.now().toUtc(),
      narrative: ThorNarrator.narrate(timeline),
      timeline: timeline,
      context: core.snapshotContext(),
      aggregates: _buildAggregates(timeline),
      evicted: {
        for (final MapEntry(:key, :value) in core.store.evictedCounts.entries)
          if (value > 0) key.name: value,
      },
      note: note,
    );
  }

  /// Construye el reporte de una sesión RECUPERADA (la app murió).
  factory ThorReport.fromRecovered(RecoveredSession recovered) {
    final timeline = recovered.events;
    return ThorReport._(
      reportId: generateThorId(),
      origin: ThorReportOrigin.crashRecovery,
      session: recovered.session,
      generatedAtUtc: clock.now().toUtc(),
      narrative: ThorNarrator.narrate(timeline),
      timeline: timeline,
      context: const {},
      aggregates: _buildAggregates(timeline),
      evicted: {
        if (recovered.corruptLines > 0) 'corruptLines': recovered.corruptLines,
      },
    );
  }

  /// Versión del esquema del artefacto. Súbela en cambios incompatibles.
  static const int schemaVersion = 1;

  /// Identificador único del reporte.
  final String reportId;

  /// Cómo se originó (manual / crash / test automatizado).
  final ThorReportOrigin origin;

  /// Sesión que produjo la evidencia.
  final ThorSession session;

  /// Momento de generación (UTC).
  final DateTime generatedAtUtc;

  /// Pasos de reproducción en lenguaje natural.
  final String narrative;

  /// Línea de tiempo completa (ya redactada al capturar).
  final List<ThorEvent> timeline;

  /// Fotografía de contexto de dominio (`Thor.addContext`).
  final Map<String, Object?> context;

  /// Vistas agregadas (por pantalla, duplicados, grupos de error).
  final Map<String, Object?> aggregates;

  /// Eventos descartados por cuota — el truncado se declara, nunca se
  /// disfraza de completitud.
  final Map<String, int> evicted;

  /// Nota libre de QA.
  final String? note;

  static Map<String, Object?> _buildAggregates(List<ThorEvent> timeline) => {
        'networkByScreen': ThorAggregates.networkByScreen(timeline),
        'suspiciousDuplicates': ThorAggregates.suspiciousDuplicates(timeline),
        'errorGroups': ThorAggregates.errorGroups(timeline),
      };

  /// JSON completo del artefacto.
  Map<String, Object?> toJson() => {
        'schemaVersion': schemaVersion,
        'reportId': reportId,
        'origin': origin.name,
        'generatedAtUtc': generatedAtUtc.toIso8601String(),
        'session': session.toJson(),
        if (note != null) 'note': note,
        'narrative': narrative,
        'aggregates': aggregates,
        'context': context,
        'evicted': evicted,
        'timeline': [for (final e in timeline) e.toJson()],
      };

  /// Markdown listo para pegar en un ticket/chat: encabezado + pasos +
  /// agregados clave. El JSON va aparte como adjunto.
  String toMarkdown() {
    final b = StringBuffer()
      ..writeln('## Reporte Thor `$reportId`')
      ..writeln()
      ..writeln('- Origen: ${origin.name}')
      ..writeln('- Sesión: `${session.sessionId}` · '
          'instalación `${session.installId}`')
      ..writeln('- App: ${session.appInfo}')
      ..writeln('- Dispositivo: ${session.deviceInfo}');
    if (note != null) b.writeln('- Nota de QA: $note');
    b
      ..writeln()
      ..writeln('### Pasos')
      ..writeln()
      ..writeln(narrative.isEmpty ? '(sin eventos)' : narrative);
    final errors = aggregates['errorGroups']! as List;
    if (errors.isNotEmpty) {
      b
        ..writeln()
        ..writeln('### Errores agrupados');
      for (final g in errors.cast<Map<String, Object?>>()) {
        b.writeln(
          '- ${g['type']} ×${g['count']} en ${g['screen'] ?? '?'}'
          '${g['origin'] == null ? '' : ' (${g['origin']})'}',
        );
      }
    }
    final dups = aggregates['suspiciousDuplicates']! as List;
    if (dups.isNotEmpty) {
      b
        ..writeln()
        ..writeln('### Peticiones duplicadas sospechosas');
      for (final d in dups.cast<Map<String, Object?>>()) {
        b.writeln('- ${d['key']} — ráfaga de ${d['maxBurst']}');
      }
    }
    if (evicted.isNotEmpty) {
      b
        ..writeln()
        ..writeln('> Se descartaron eventos por cuota: $evicted — la línea '
            'de tiempo está truncada en esas familias.');
    }
    return b.toString();
  }

  /// Escribe el artefacto comprimido (`<reportId>.thor.json.gz`) en [dir].
  /// Devuelve el archivo. El JSON crudo nunca toca el disco sin comprimir.
  Future<File> writeTo(Directory dir) async {
    await dir.create(recursive: true);
    final file = File('${dir.path}/$reportId.thor.json.gz');
    final bytes = gzip.encode(utf8.encode(jsonEncode(toJson())));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }
}
