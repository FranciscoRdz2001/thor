import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thor/thor.dart';
import 'package:thor_flutter/src/overlay/report_share.dart';
import 'package:thor_flutter/src/screenshot_capture.dart';

/// Inspector en pantalla: la vista Chucker-style de Thor, pero sobre la
/// línea de tiempo completa — Red, Pasos de reproducción y Errores.
///
/// Tema propio oscuro (no hereda el de la app): el inspector es una
/// herramienta, no parte del producto, y debe verse igual en todas las apps.
class ThorInspectorPage extends StatelessWidget {
  /// Crea el inspector.
  const ThorInspectorPage({super.key});

  @override
  Widget build(BuildContext context) {
    final core = ThorCore.instance;
    return Theme(
      data: ThemeData.dark(useMaterial3: true),
      child: core == null
          ? const Scaffold(
              body: Center(child: Text('Thor no está inicializado')),
            )
          : DefaultTabController(
              length: 3,
              child: Scaffold(
                appBar: AppBar(
                  title: const Text('Thor'),
                  actions: [
                    IconButton(
                      tooltip: 'Copiar reporte',
                      icon: const Icon(Icons.copy_all),
                      onPressed: () => _copyReport(context, core),
                    ),
                    IconButton(
                      tooltip: 'Compartir reporte (.gz)',
                      icon: const Icon(Icons.ios_share),
                      onPressed: () => _shareReport(context, core),
                    ),
                  ],
                  bottom: const TabBar(
                    tabs: [
                      Tab(text: 'Red'),
                      Tab(text: 'Pasos'),
                      Tab(text: 'Errores'),
                    ],
                  ),
                ),
                body: TabBarView(
                  children: [
                    _NetworkTab(core: core),
                    _StepsTab(core: core),
                    _ErrorsTab(core: core),
                  ],
                ),
              ),
            ),
    );
  }

  Future<void> _copyReport(BuildContext context, ThorCore core) async {
    final markdown = ThorReport.fromCore(core).toMarkdown();
    await Clipboard.setData(ClipboardData(text: markdown));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reporte copiado al portapapeles')),
      );
    }
  }

  Future<void> _shareReport(BuildContext context, ThorCore core) async {
    // La captura ya retenida (p.ej. del desborde) manda; si no hay, se
    // toma una ahora. Ojo: aquí el inspector está encima, así que la del
    // momento del fallo es más útil que la actual.
    final shot = ThorScreenshot.latest;
    final outcome = await ThorReportSharer.share(
      ThorReport.fromCore(core, screenshotPng: shot),
    );
    if (context.mounted && outcome == ThorShareOutcome.copiedToClipboard) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sin share disponible: reporte al portapapeles'),
        ),
      );
    }
  }
}

// ─── Red ───────────────────────────────────────────────────────────────────

class _NetworkTab extends StatelessWidget {
  const _NetworkTab({required this.core});

  final ThorCore core;

  @override
  Widget build(BuildContext context) {
    final events = core.store
        .timeline(kinds: {ThorEventKind.network})
        .reversed
        .toList();
    if (events.isEmpty) {
      return const Center(child: Text('Sin peticiones todavía'));
    }
    return ListView.separated(
      itemCount: events.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final event = events[index];
        final status = event.payload['statusCode'];
        final error = event.payload['error'];
        final failed = error != null || (status is int && status >= 400);
        final uri = Uri.tryParse(event.payload['url'] as String? ?? '');
        return ListTile(
          dense: true,
          leading: _StatusChip(status: status, failed: failed),
          title: Text(
            '${event.payload['method']} ${uri?.path ?? '?'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${event.screen?.display ?? '?'} · '
            '${event.payload['durationMs']}ms · #${event.seq}',
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _NetworkDetailPage(event: event),
              settings: const RouteSettings(name: 'thor/network-detail'),
            ),
          ),
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status, required this.failed});

  final Object? status;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: failed ? const Color(0x33FF5252) : const Color(0x3369F0AE),
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      child: Text(
        status?.toString() ?? '✗',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: failed ? const Color(0xFFFF8A80) : const Color(0xFF69F0AE),
        ),
      ),
    );
  }
}

class _NetworkDetailPage extends StatelessWidget {
  const _NetworkDetailPage({required this.event});

  final ThorEvent event;

  @override
  Widget build(BuildContext context) {
    final p = event.payload;
    final curl = p['curl'] as String?;
    // El crudo (reproducible) vive SOLO en memoria y puede ya no existir
    // (cuota del RawNetworkStore).
    final rawCurl = RawNetworkStore.forSeq(event.seq);
    return Scaffold(
      appBar: AppBar(
        title: Text('${p['method']} #${event.seq}'),
        actions: [
          if (curl != null || rawCurl != null)
            PopupMenuButton<String>(
              tooltip: 'Copiar cURL',
              icon: const Icon(Icons.terminal),
              onSelected: (value) async {
                await Clipboard.setData(ClipboardData(text: value));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('cURL copiado')),
                  );
                }
              },
              itemBuilder: (_) => [
                if (rawCurl != null)
                  PopupMenuItem(
                    value: rawCurl,
                    child: const Text('Copiar cURL real (con secretos)'),
                  ),
                if (curl != null)
                  PopupMenuItem(
                    value: curl,
                    child: const Text('Copiar cURL redactado (para ticket)'),
                  ),
              ],
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _kv('URL', p['url']),
          _kv('Pantalla', event.screen?.display),
          _kv('Status', p['statusCode'] ?? p['error']),
          _kv('Duración', '${p['durationMs']}ms'),
          if (event.origin != null) _kv('Desde', event.origin),
          _section('Cabeceras de petición', p['requestHeaders']),
          _section('Cuerpo de petición', p['requestBody']),
          _section('Cabeceras de respuesta', p['responseHeaders']),
          _section('Cuerpo de respuesta', p['responseBody']),
          if (curl != null) _section('cURL', curl),
        ],
      ),
    );
  }

  Widget _kv(String label, Object? value) => value == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '$label: ',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                TextSpan(text: value.toString()),
              ],
            ),
          ),
        );

  Widget _section(String title, Object? content) {
    if (content == null) return const SizedBox.shrink();
    final text = content is String
        ? content
        : const JsonEncoder.withIndent('  ').convert(content);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1B1D),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Pasos ─────────────────────────────────────────────────────────────────

class _StepsTab extends StatelessWidget {
  const _StepsTab({required this.core});

  final ThorCore core;

  @override
  Widget build(BuildContext context) {
    final narrative = ThorNarrator.narrate(core.store.timeline());
    return Padding(
      padding: const EdgeInsets.all(12),
      child: narrative.isEmpty
          ? const Center(child: Text('Sin eventos todavía'))
          : SingleChildScrollView(
              child: SelectableText(
                narrative,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
    );
  }
}

// ─── Errores ───────────────────────────────────────────────────────────────

class _ErrorsTab extends StatelessWidget {
  const _ErrorsTab({required this.core});

  final ThorCore core;

  @override
  Widget build(BuildContext context) {
    final groups = ThorAggregates.errorGroups(core.store.timeline());
    if (groups.isEmpty) {
      return const Center(child: Text('Sin errores 🎉'));
    }
    return ListView.separated(
      itemCount: groups.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final g = groups[index];
        return ListTile(
          dense: true,
          leading: CircleAvatar(
            radius: 14,
            backgroundColor: const Color(0x33FF5252),
            child: Text(
              '×${g['count']}',
              style: const TextStyle(fontSize: 11, color: Color(0xFFFF8A80)),
            ),
          ),
          title: Text('${g['type']}'),
          subtitle: Text(
            [
              if (g['screen'] != null) g['screen'],
              if (g['origin'] != null) g['origin'],
            ].join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: Text('${g['type']}'),
              content: SingleChildScrollView(
                child: SelectableText(
                  '${g['message'] ?? ''}\n\n'
                  'Pantalla: ${g['screen'] ?? '?'}\n'
                  'Origen: ${g['origin'] ?? '?'}\n'
                  'Ocurrencias: ${g['count']}',
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
