// Pruebas de la ronda 2 de captura (T-N01…T-N13): señales de permisos,
// superficies externas, problemas visibles, fin de sesión y E/S del SDK.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/src/dead_tap_capture.dart';
import 'package:thor_flutter/src/device_model.dart';
import 'package:thor_flutter/src/environment_capture.dart';
import 'package:thor_flutter/thor_flutter.dart';

List<Map<String, Object?>> _env(String signal) => [
      for (final e
          in ThorCore.instance!.store.ofKind(ThorEventKind.environment))
        if (e.payload['signal'] == signal) e.payload,
    ];

List<Map<String, Object?>> _errors([String? source]) => [
      for (final e in ThorCore.instance!.store.ofKind(ThorEventKind.error))
        if (source == null || e.payload['source'] == source) e.payload,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    ThorCore.debugReset();
    await ThorCore.init();
    DeadTapCapture.enabled = true;
  });

  tearDown(() {
    DeadTapCapture.enabled = false;
    UiHealthCapture.uninstall();
    InteractionCapture.uninstall();
    EnvironmentCapture.uninstall();
    ThorCore.debugReset();
  });

  textInputTests();

  group('toque sin efecto', () {
    Widget app({required VoidCallback? onPressed, Widget? extra}) =>
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ElevatedButton(
                    onPressed: onPressed, child: const Text('Pagar'),),
                if (extra != null) extra,
              ],
            ),
          ),
        );

    testWidgets('un botón deshabilitado: el toque se reporta', (tester) async {
      InteractionCapture.install();
      await tester.pumpWidget(app(onPressed: null));
      await tester.tap(find.text('Pagar'), warnIfMissed: false);
      await tester.pump(const Duration(seconds: 2));
      final e = _errors('dead_tap').single;
      expect(e['label'], 'Pagar');
      expect(e['disabled'], isTrue);
      expect(e['fatal'], false);
    });

    testWidgets('un botón vivo tocado dos veces sin efecto se reporta',
        (tester) async {
      InteractionCapture.install();
      await tester.pumpWidget(app(onPressed: () {}));
      await tester.tap(find.text('Pagar'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Pagar'));
      await tester.pump(const Duration(seconds: 2));
      final e = _errors('dead_tap').single;
      expect(e['disabled'], isFalse);
      expect(e['label'], 'Pagar');
    });

    testWidgets(
        'un solo toque a un botón vivo NO se reporta (podía ser visual)',
        (tester) async {
      InteractionCapture.install();
      await tester.pumpWidget(app(onPressed: () {}));
      await tester.tap(find.text('Pagar'));
      await tester.pump(const Duration(seconds: 2));
      expect(_errors('dead_tap'), isEmpty);
    });

    testWidgets('si hubo petición/navegación tras el toque, no es muerto',
        (tester) async {
      InteractionCapture.install();
      await tester.pumpWidget(app(onPressed: () {}));
      await tester.tap(find.text('Pagar'));
      await tester.pump(const Duration(milliseconds: 300));
      ThorCore.instance!.recorder.record(ThorEventKind.network, {
        'method': 'POST',
        'url': 'https://x.test/pay',
        'statusCode': 200,
      });
      await tester.tap(find.text('Pagar'));
      await tester.pump(const Duration(milliseconds: 300));
      ThorCore.instance!.recorder.record(ThorEventKind.navigation, {
        'action': 'push',
        'to': 'Recibo',
      });
      await tester.pump(const Duration(seconds: 2));
      expect(_errors('dead_tap'), isEmpty);
    });

    testWidgets('un botón deshabilitado se reporta una vez, no en cada toque',
        (tester) async {
      InteractionCapture.install();
      await tester.pumpWidget(app(onPressed: null));
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Pagar'), warnIfMissed: false);
        await tester.pump(const Duration(seconds: 2));
      }
      expect(_errors('dead_tap'), hasLength(1));
    });
  });

  group('salud visible: excepción cruda y 200 vacío', () {
    test('looksLikeRawException distingue excepciones de copy', () {
      for (final raw in [
        '(error) FormatException: Unexpected end of input',
        "type 'Null' is not a subtype of type 'String'",
        'Null check operator used on a null value',
        "Instance of 'ProductModel'",
        'SocketException: Failed host lookup',
        'Exception: algo salió mal',
      ]) {
        expect(UiHealthCapture.looksLikeRawException(raw), isTrue, reason: raw);
      }
      for (final copy in [
        'No pudimos cargar tus productos',
        'Error al iniciar sesión',
        'Ocurrió un problema, intenta de nuevo',
        'Frutas y Verduras',
      ]) {
        expect(
          UiHealthCapture.looksLikeRawException(copy),
          isFalse,
          reason: copy,
        );
      }
    });

    testWidgets('un Text con la excepción cruda se reporta una vez',
        (tester) async {
      UiHealthCapture.attach();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Text('(error) FormatException: Unexpected end of input'),
          ),
        ),
      );
      UiHealthCapture.scan();
      UiHealthCapture.scan();
      final e = _errors('ui_error').single;
      expect(e['type'], 'RawExceptionText');
      expect(e['kind'], 'raw_exception');
      expect(e['text'], contains('FormatException'));
    });

    test('GET 200 sin cuerpo: error empty_response, una vez por ruta', () {
      UiHealthCapture.attach();
      void emit(String path, {String method = 'GET', Object? body}) {
        ThorCore.instance!.recorder.record(ThorEventKind.network, {
          'method': method,
          'url': 'https://api.test$path?q=1',
          'statusCode': 200,
          'responseBytes': -1,
          if (body != null) 'responseBody': body,
        });
      }

      emit('/sponsored');
      emit('/sponsored');
      emit('/con-cuerpo', body: {'a': 1});
      emit('/post', method: 'POST');
      final e = _errors('empty_response');
      expect(e, hasLength(1));
      expect(e.single['message'], contains('/sponsored'));
      expect(e.single['statusCode'], 200);
    });
  });

  group('permisos y superficies del sistema', () {
    test('Thor.permission / Thor.externalSurface graban la señal', () {
      Thor.permission('microphone', after: 'denied', prompt: true);
      Thor.externalSurface('https://www.shop.example.com/x?t=1',
          mode: 'in_app_browser',);
      expect(_env('permission').single['kind'], 'microphone');
      expect(_env('external_surface').single['host'], 'www.shop.example.com');
    });

    test('un error de permiso denegado deja el evento permission', () {
      ErrorCapture.install();
      PlatformDispatcher.instance.onError!(
        PlatformException(
          code: 'cameraAccessDenied',
          message: 'Camera permission denied',
        ),
        StackTrace.current,
      );
      final p = _env('permission').single;
      expect(p['kind'], 'camera');
      expect(p['after'], 'denied');
      expect(p['source'], 'error');
    });

    testWidgets('inactive ≥ umbral sin pasar a background = system_overlay',
        (tester) async {
      EnvironmentCapture.overlayMin = Duration.zero;
      addTearDown(() =>
          EnvironmentCapture.overlayMin = const Duration(milliseconds: 400),);
      EnvironmentCapture.install();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(_env('system_overlay'), hasLength(1));
      expect(_env('system_overlay').single['ms'], greaterThanOrEqualTo(0));
    });

    testWidgets('irse a background NO es system_overlay', (tester) async {
      EnvironmentCapture.overlayMin = Duration.zero;
      addTearDown(() =>
          EnvironmentCapture.overlayMin = const Duration(milliseconds: 400),);
      EnvironmentCapture.install();
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      expect(_env('system_overlay'), isEmpty);
    });

    testWidgets('el tiempo en background se acumula para la marca de fin',
        (tester) async {
      EnvironmentCapture.install();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(ThorCore.instance!.backgroundMs, greaterThanOrEqualTo(25));
    });
  });

  group('errores internos del SDK (T-N01)', () {
    test('un PathNotFound del journal/replay es source thor, con tope', () {
      ErrorCapture.install();
      for (var i = 0; i < 50; i++) {
        PlatformDispatcher.instance.onError!(
          const PathNotFoundException(
            '/x/Library/Application Support/thor/replay-abc.jsonl',
            OSError('No such file', 2),
          ),
          StackTrace.current,
        );
      }
      final errors = _errors();
      expect(errors, hasLength(ThorCore.maxInternalErrors));
      expect(errors.every((e) => e['source'] == 'thor'), isTrue);
      expect(ThorCore.instance!.internalErrorsDropped, 47);
    });

    test('un FileSystemException ajeno a Thor sigue siendo error de la app',
        () {
      ErrorCapture.install();
      PlatformDispatcher.instance.onError!(
        const FileSystemException('no', '/app/datos.db'),
        StackTrace.current,
      );
      expect(_errors().single['source'], 'platform');
    });
  });

  group('logs (T-N08)', () {
    late DebugPrintCallback saved;

    setUp(() {
      saved = debugPrint;
      LogCapture.resetDuplicates();
    });

    tearDown(() {
      LogCapture.uninstall();
      debugPrint = saved;
    });

    List<Map<String, Object?>> logs() => [
          for (final e in ThorCore.instance!.store.ofKind(ThorEventKind.log))
            e.payload,
        ];

    test('el mismo texto por print y por debugPrint se graba UNA vez', () {
      debugPrint = (message, {wrapWidth}) {};
      LogCapture.install();
      runZoned(
        () {
          debugPrint('[PERF] search 312ms');
          print('[PERF] search 312ms');
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            parent.print(zone, line);
            LogCapture.zoneSpecification.print!(self, parent, zone, line);
          },
        ),
      );
      final l = logs().where((e) => '${e['message']}'.contains('[PERF]'));
      expect(l, hasLength(1));
      expect(l.single['level'], 'info', reason: '[PERF] es informativo');
    });

    test('el mismo origen repetido NO es duplicado', () {
      debugPrint = (message, {wrapWidth}) {};
      LogCapture.install();
      debugPrint('hola');
      debugPrint('hola');
      expect(logs().where((e) => e['message'] == 'hola'), hasLength(2));
    });

    test('pasada la ventana, el otro origen vuelve a grabarse', () async {
      LogCapture.duplicateWindow = const Duration(milliseconds: 10);
      addTearDown(() {
        LogCapture.duplicateWindow = const Duration(milliseconds: 500);
      });
      debugPrint = (message, {wrapWidth}) {};
      LogCapture.install();
      debugPrint('otra vez');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      runZoned(
        () => print('otra vez'),
        zoneSpecification: LogCapture.zoneSpecification,
      );
      expect(logs().where((e) => e['message'] == 'otra vez'), hasLength(2));
    });
  });

  group('modelo del dispositivo (T-N06)', () {
    test('device.plist del simulador → nombre legible', () {
      const plist = '''
<plist version="1.0"><dict>
<key>name</key><string>iPhone 16 Pro</string>
<key>deviceType</key>
<string>com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro</string>
</dict></plist>''';
      expect(DeviceModel.modelFromDevicePlist(plist), 'iPhone 16 Pro');
      expect(DeviceModel.modelFromDevicePlist('<plist/>'), isNull);
    });

    test('simulador con SIMULATOR_MODEL_IDENTIFIER usa ese id', () {
      expect(
        DeviceModel.detect(
          environment: {'SIMULATOR_MODEL_IDENTIFIER': 'iPhone17,1'},
          executable: '/Users/a/Library/Developer/CoreSimulator/Devices/UDID/'
              'data/Containers/Bundle/Application/X/Runner.app/Runner',
          isIos: true,
          isMacOs: false,
        ),
        'iPhone17,1',
      );
    });

    test('Android y otros: null, sin lanzar', () {
      expect(
        DeviceModel.detect(
          environment: const {},
          executable: '/data/app/x',
          isIos: false,
          isMacOs: false,
        ),
        isNull,
      );
    });

    test('esta máquina (sysctl real) devuelve un texto o null, no lanza', () {
      final model = DeviceModel.detect();
      expect(model == null || model.isNotEmpty, isTrue);
    });
  });

  group('replay: hora real del gap y fin de sesión (T-N03, T-N12)', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('thor_round2'));

    tearDown(() async {
      await ThorReplay.stop();
      dir.deleteSync(recursive: true);
    });

    List<Map<String, dynamic>> records(String sid) => [
          for (final l
              in File('${dir.path}/replay-$sid.jsonl').readAsLinesSync())
            if (jsonDecode(l) case final Map<String, dynamic> m) m,
        ];

    testWidgets('el gap lleva from y wall (UTC ISO) y el fin lleva bg',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('x')));
      await tester.runAsync(
        () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
      );
      final sid = ThorCore.instance!.session.sessionId;
      final before = DateTime.now().toUtc();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.runAsync(() => ThorReplay.stop(reason: 'renewed'));

      final recs = records(sid);
      final gap = recs.singleWhere((m) => m['t'] == 'gap');
      final from = DateTime.parse(gap['from'] as String);
      final wall = DateTime.parse(gap['wall'] as String);
      expect(from.isUtc && wall.isUtc, isTrue);
      expect(from.isBefore(before.add(const Duration(seconds: 5))), isTrue);
      expect(
        wall.difference(from).inMilliseconds,
        inInclusiveRange(250, 2000),
      );
      expect(
          wall.difference(from).inMilliseconds, closeTo(gap['ms'] as num, 60),);

      final end = recs.last;
      expect(end['t'], 'end');
      expect(end['reason'], 'renewed');
      expect(end['bg'], 0, reason: '0,3 s < 1 s');
      expect(end['q'], greaterThan(gap['q'] as int));
    });

    testWidgets('el replay lleva x (extractos), tamaños de texto y señales',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('x')));
      await tester.runAsync(
        () => ThorReplay.start(const ThorReplayConfig(), directory: dir),
      );
      final sid = ThorCore.instance!.session.sessionId;
      final big = 'a' * 20000;
      ThorCore.instance!.recorder
        ..record(ThorEventKind.network, {
          'method': 'GET',
          'url': 'https://api.test/CategoryTree',
          'statusCode': 200,
          'responseBody': big,
          'responseBodyTruncated': true,
          'bodyCap': 30000,
          'extracts': {
            'quantity': {'n': 2, 'sum': 5},
          },
        })
        ..record(ThorEventKind.interaction, {
          'gesture': ThorGesture.textEdit,
          'widget': 'TextField',
          'label': 'Buscar',
          'length': 80,
          'startLength': 0,
          'empty': false,
          'edits': 1,
          'source': 'pasted_or_scanned',
        });
      Thor.permission('camera', after: 'denied', prompt: true);
      Thor.externalSurface('https://www.shop.example.com/t?x=1');
      await tester.runAsync(ThorReplay.stop);

      final evs = [
        for (final m in records(sid))
          if (m['t'] == 'ev') m,
      ];
      final net = evs.firstWhere((e) => e['k'] == 'network')['p'] as Map;
      expect(net['x'], {
        'quantity': {'n': 2, 'sum': 5},
      });
      expect((net['body'] as String).length, 20000,
          reason: 'bodyCap 30000 sube el tope del replay (4 KB por defecto)',);
      expect(net['bt'], isTrue);
      final edit = evs.firstWhere((e) {
        final p = e['p'];
        return e['k'] == 'interaction' &&
            p is Map &&
            p['g'] == ThorGesture.textEdit;
      })['p'] as Map;
      expect(edit['length'], 80);
      expect(edit['source'], 'pasted_or_scanned');
      expect(edit['empty'], isFalse);
      final envs = [
        for (final e in evs)
          if (e['k'] == 'environment') e['p'] as Map,
      ];
      final perm = envs.firstWhere((p) => p['signal'] == 'permission');
      expect(perm['kind'], 'camera');
      expect(perm['after'], 'denied');
      expect(perm['prompt'], isTrue);
      final ext = envs.firstWhere((p) => p['signal'] == 'external_surface');
      expect(ext['host'], 'www.shop.example.com');
    });

    test('endMarker: killed si lo último fue irse; crash si no', () {
      String? reasonOf(List<String> lines) {
        final m = ThorReplay.endMarker(lines);
        return m == null ? null : (jsonDecode(m) as Map)['reason'] as String;
      }

      const meta = '{"t":"meta","v":2,"q":1}';
      String life(String state, int q) =>
          '{"t":"ev","ts":${q * 10},"k":"environment",'
          '"p":{"signal":"lifecycle","state":"$state"},"q":$q}';

      expect(reasonOf([meta, life('paused', 2)]), 'killed');
      expect(reasonOf([meta, life('resumed', 2)]), 'crash');
      expect(reasonOf([meta, '["p",20,"d",1,1,2]']), 'crash');
      expect(
        reasonOf([
          meta,
          life('paused', 2),
          '{"t":"ev","ts":30,"k":"error","p":{"src":"zone"},"q":3}',
        ]),
        'crash',
        reason: 'un error fatal manda',
      );
      expect(
        reasonOf([meta, '{"t":"end","reason":"clean","ts":9,"q":2}']),
        isNull,
        reason: 'ya cerró',
      );
      expect(ThorReplay.endMarker(const []), isNull);

      final marker = jsonDecode(ThorReplay.endMarker([
        meta,
        '{"t":"gap","k":"background","ts":10,"ms":42000,"q":2}',
        life('paused', 3),
      ])!,) as Map;
      expect(marker['bg'], 42);
      expect(marker['q'], 4);
      expect(marker['ts'], 30);
    });
  });
}

class _Field extends StatelessWidget {
  const _Field(this.controller, {this.obscure = false});
  final TextEditingController controller;
  final bool obscure;

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: TextField(
            controller: controller,
            obscureText: obscure,
            decoration: const InputDecoration(labelText: 'Buscar'),
          ),
        ),
      );
}

void textInputTests() {
  List<Map<String, Object?>> gestures(String g) => [
        for (final e
            in ThorCore.instance!.store.ofKind(ThorEventKind.interaction))
          if (e.payload['gesture'] == g) e.payload,
      ];

  group('entrada de texto (3.1): tamaños, jamás contenido', () {
    setUp(() {
      InteractionCapture.install();
      InteractionCapture.longTextThreshold = 50;
    });

    testWidgets('focus trae largo y vacío; al salir, text_edit con tamaños',
        (tester) async {
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      await tester.pumpWidget(_Field(controller));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final focus = gestures('text_focus').single;
      expect(focus['length'], 3);
      expect(focus['empty'], isFalse);

      // Teclear de a un carácter.
      final typed = StringBuffer('abc');
      for (final c in ['d', 'e', 'f']) {
        typed.write(c);
        await tester.enterText(find.byType(TextField), '$typed');
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      final edit = gestures('text_edit').single;
      expect(edit['label'], 'Buscar');
      expect(edit['length'], 6);
      expect(edit['startLength'], 3);
      expect(edit['edits'], 3);
      expect(edit['empty'], isFalse);
      expect(edit.containsKey('source'), isFalse, reason: 'corto: sin source');
      expect(
        ThorCore.instance!.store.toString(),
        isNot(contains('abcdef')),
        reason: 'el contenido no se captura',
      );
    });

    testWidgets('texto largo pegado de golpe: source pasted_or_scanned',
        (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_Field(controller));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '7501055300' * 8);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      final edit = gestures('text_edit').single;
      expect(edit['length'], 80);
      expect(edit['source'], 'pasted_or_scanned');
    });

    testWidgets('texto largo tecleado: source typed', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      InteractionCapture.longTextThreshold = 5;
      await tester.pumpWidget(_Field(controller));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      final typed = StringBuffer();
      for (var i = 0; i < 6; i++) {
        typed.write(i);
        await tester.enterText(find.byType(TextField), '$typed');
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(gestures('text_edit').single['source'], 'typed');
    });

    testWidgets('borrar todo deja empty: true; sin cambios no hay text_edit',
        (tester) async {
      final controller = TextEditingController(text: 'hola');
      addTearDown(controller.dispose);
      await tester.pumpWidget(_Field(controller));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(gestures('text_edit'), isEmpty);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      final edit = gestures('text_edit').single;
      expect(edit['empty'], isTrue);
      expect(edit['length'], 0);
    });

    testWidgets('contraseña: ni el largo, solo si quedó vacío', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_Field(controller, obscure: true));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hunter2');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      final focus = gestures('text_focus').single;
      expect(focus.containsKey('length'), isFalse);
      final edit = gestures('text_edit').single;
      expect(edit['obscure'], isTrue);
      expect(edit.containsKey('length'), isFalse);
      expect(edit['empty'], isFalse);
    });

    testWidgets('el narrador lo cuenta como paso anidado', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_Field(controller));
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '7501055300' * 8);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      final narrative =
          ThorNarrator.narrate(ThorCore.instance!.store.timeline());
      expect(narrative, contains('«Buscar»: quedó con 80 caracteres'));
      expect(narrative, contains('pegado o escaneado'));
    });
  });
}
