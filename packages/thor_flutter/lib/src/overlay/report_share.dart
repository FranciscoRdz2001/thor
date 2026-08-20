import 'dart:io';

import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:thor/thor.dart';

/// Resultado de intentar compartir un reporte.
enum ThorShareOutcome {
  /// Se abrió el share sheet del sistema con el archivo .gz.
  sharedFile,

  /// No hubo canal de plataforma (tests, plataforma sin share): el
  /// markdown quedó en el portapapeles y el archivo en disco.
  copiedToClipboard,
}

/// Comparte un [ThorReport]: escribe el artefacto `.thor.json.gz` y lo
/// entrega por el share sheet del sistema (correo, Slack, AirDrop…).
///
/// Fallback: si el canal de share no existe (tests de widget, desktop sin
/// plugin), el markdown va al portapapeles — QA nunca se queda sin salida.
class ThorReportSharer {
  ThorReportSharer._();

  /// Comparte [report]. [directory] es dónde escribir el artefacto; si es
  /// `null` se usa el directorio del journal o el temporal del sistema.
  static Future<ThorShareOutcome> share(
    ThorReport report, {
    Directory? directory,
  }) async {
    final dir = directory ??
        ThorCore.instance?.journal?.directory ??
        Directory.systemTemp;
    final file = await report.writeTo(Directory('${dir.path}/reportes'));
    try {
      await Share.shareXFiles(
        [XFile(file.path, mimeType: 'application/gzip')],
        subject: 'Reporte Thor ${report.reportId}',
        text: report.narrative.isEmpty
            ? 'Reporte Thor'
            : report.narrative,
      );
      return ThorShareOutcome.sharedFile;
    } on Object {
      // Sin canal de plataforma: portapapeles como red de seguridad.
      await Clipboard.setData(ClipboardData(text: report.toMarkdown()));
      return ThorShareOutcome.copiedToClipboard;
    }
  }
}
