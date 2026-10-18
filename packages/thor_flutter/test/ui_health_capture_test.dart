import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thor_flutter/thor_flutter.dart';

/// Contrato de `UiHealthCapture`: pantalla atascada, pantalla en blanco,
/// mensajes de la app (diálogo/snackbar) e imágenes que no cargaron.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var fakeMs = 0;

  setUp(() async {
    ThorCore.debugReset();
    await ThorCore.init();
    fakeMs = 100000;
    UiHealthCapture.nowMs = () => fakeMs;
    UiHealthCapture.isForeground = () => true;
    UiHealthCapture.attach();
  });

  tearDown(() {
    UiHealthCapture.uninstall();
    ThorCore.debugReset();
  });

  List<Map<String, Object?>> perf(String kind) => [
        for (final e
            in ThorCore.instance!.store.ofKind(ThorEventKind.performance))
          if (e.payload['kind'] == kind) e.payload,
      ];

  List<Map<String, Object?>> errors(String source) => [
        for (final e in ThorCore.instance!.store.ofKind(ThorEventKind.error))
          if (e.payload['source'] == source) e.payload,
      ];

  List<Map<String, Object?>> env(String signal) => [
        for (final e
            in ThorCore.instance!.store.ofKind(ThorEventKind.environment))
          if (e.payload['signal'] == signal) e.payload,
      ];

  Widget app(Widget body) => MaterialApp(home: Scaffold(body: body));

  group('stuck_loading', () {
    testWidgets('un spinner visible 8 s o más se reporta una vez',
        (tester) async {
      ThorCore.instance!.setScreen('OrdersPage');
      await tester.pumpWidget(app(const Center(child: Text('x'))));
      await tester.pumpWidget(
        app(const Center(child: CircularProgressIndicator())),
      );

      UiHealthCapture.scan();
      fakeMs += 7000;
      UiHealthCapture.scan();
      expect(perf('stuck_loading'), isEmpty, reason: 'aún no son 8 s');

      fakeMs += 2000;
      UiHealthCapture.scan();
      expect(perf('stuck_loading'), [
        {'kind': 'stuck_loading', 'screen': 'OrdersPage', 'ms': 9000},
      ]);

      fakeMs += 20000;
      UiHealthCapture.scan();
      expect(perf('stuck_loading'), hasLength(1), reason: 'un solo reporte');
    });

    testWidgets('si la carga termina, el episodio se reinicia',
        (tester) async {
      ThorCore.instance!.setScreen('OrdersPage');
      await tester.pumpWidget(
        app(const Center(child: CircularProgressIndicator())),
      );
      UiHealthCapture.scan();
      fakeMs += 5000;
      await tester.pumpWidget(app(const Center(child: Text('listo'))));
      UiHealthCapture.scan(); // ya no carga: se descarta el episodio
      await tester.pumpWidget(
        app(const Center(child: CircularProgressIndicator())),
      );
      fakeMs += 5000;
      UiHealthCapture.scan(); // episodio nuevo: arranca aquí
      fakeMs += 5000;
      UiHealthCapture.scan();
      expect(perf('stuck_loading'), isEmpty);
    });

    testWidgets('un progreso determinado no es una carga atascada',
        (tester) async {
      ThorCore.instance!.setScreen('UploadPage');
      await tester.pumpWidget(
        app(const Center(child: CircularProgressIndicator(value: 0.4))),
      );
      UiHealthCapture.scan();
      fakeMs += 30000;
      UiHealthCapture.scan();
      expect(perf('stuck_loading'), isEmpty);
    });

    testWidgets('un esqueleto (Shimmer/Skeleton) cuenta como carga',
        (tester) async {
      ThorCore.instance!.setScreen('ListPage');
      await tester.pumpWidget(app(const _SkeletonList()));
      UiHealthCapture.scan();
      fakeMs += 9000;
      UiHealthCapture.scan();
      expect(perf('stuck_loading'), hasLength(1));
    });

    testWidgets('en segundo plano no corre y el episodio se descarta',
        (tester) async {
      ThorCore.instance!.setScreen('OrdersPage');
      await tester.pumpWidget(
        app(const Center(child: CircularProgressIndicator())),
      );
      UiHealthCapture.scan();
      fakeMs += 9000;
      UiHealthCapture.isForeground = () => false;
      // El temporizador real no se instala en tests; se simula su tick.
      UiHealthCapture.install();
      await tester.pump(UiHealthCapture.tick);
      expect(perf('stuck_loading'), isEmpty);
      // El temporizador periódico no puede sobrevivir al test.
      UiHealthCapture.uninstall();
    });
  });

  group('blank_screen', () {
    testWidgets('pantalla casi vacía 5 s se reporta con sus nodos',
        (tester) async {
      ThorCore.instance!.setScreen('OrdersPage');
      await tester.pumpWidget(app(const SizedBox.expand()));
      UiHealthCapture.scan();
      fakeMs += 6000;
      UiHealthCapture.scan();
      expect(perf('blank_screen'), [
        {
          'kind': 'blank_screen',
          'screen': 'OrdersPage',
          'ms': 6000,
          'nodes': 0,
        },
      ]);
      fakeMs += 6000;
      UiHealthCapture.scan();
      expect(perf('blank_screen'), hasLength(1));
    });

    testWidgets('una pantalla con contenido no es blanca', (tester) async {
      ThorCore.instance!.setScreen('HomePage');
      await tester.pumpWidget(
        app(
          Column(
            children: [for (var i = 0; i < 6; i++) Text('producto $i')],
          ),
        ),
      );
      UiHealthCapture.scan();
      fakeMs += 20000;
      UiHealthCapture.scan();
      expect(perf('blank_screen'), isEmpty);
    });

    testWidgets('cargando no es en blanco (es otra señal)', (tester) async {
      ThorCore.instance!.setScreen('HomePage');
      await tester.pumpWidget(
        app(const Center(child: CircularProgressIndicator())),
      );
      UiHealthCapture.scan();
      fakeMs += 6000;
      UiHealthCapture.scan();
      expect(perf('blank_screen'), isEmpty);
    });

    testWidgets('sin pantalla conocida no se reporta nada', (tester) async {
      await tester.pumpWidget(app(const SizedBox.expand()));
      UiHealthCapture.scan();
      fakeMs += 20000;
      UiHealthCapture.scan();
      expect(perf('blank_screen'), isEmpty);
    });
  });

  group('mensajes de la app', () {
    testWidgets('un AlertDialog de fallo es un ui_error con su texto',
        (tester) async {
      ThorCore.instance!.setScreen('OrdersPage');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Error'),
                  content: const Text('No se pudo cargar tus pedidos'),
                  actions: [
                    TextButton(
                      onPressed: () {},
                      child: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
              child: const Text('abrir'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('abrir'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      UiHealthCapture.scan();
      final found = errors('ui_error');
      expect(found, hasLength(1));
      expect(found.single['type'], 'UiError');
      expect(found.single['widget'], 'AlertDialog');
      expect(found.single['text'], 'Error · No se pudo cargar tus pedidos');
      expect(found.single['fatal'], false);
      expect(found.single['message'], contains('No se pudo cargar'));

      UiHealthCapture.scan();
      expect(errors('ui_error'), hasLength(1), reason: 'sigue visible: 1 vez');
    });

    testWidgets('un SnackBar neutral es ui_message, no error', (tester) async {
      ThorCore.instance!.setScreen('CartPage');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Producto agregado')),
                ),
                child: const Text('agregar'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('agregar'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      UiHealthCapture.scan();
      expect(errors('ui_error'), isEmpty);
      expect(env('ui_message'), [
        {
          'signal': 'ui_message',
          'widget': 'SnackBar',
          'text': 'Producto agregado',
        },
      ]);
    });

    testWidgets('un Toast propio (clase *Toast) se lee igual', (tester) async {
      ThorCore.instance!.setScreen('CartPage');
      await tester.pumpWidget(
        app(const _FakeToast('Sin conexión, intenta de nuevo')),
      );
      UiHealthCapture.scan();
      final found = errors('ui_error');
      expect(found, hasLength(1));
      expect(found.single['widget'], '_FakeToast');
    });

    testWidgets('el texto va sin secretos', (tester) async {
      ThorCore.instance!.setScreen('LoginPage');
      await tester.pumpWidget(
        app(const _FakeToast('Error de sesión: token=abc123secreto')),
      );
      UiHealthCapture.scan();
      final text = errors('ui_error').single['text']! as String;
      expect(text, isNot(contains('abc123secreto')));
    });

    testWidgets('si desaparece y vuelve, se reporta de nuevo', (tester) async {
      ThorCore.instance!.setScreen('LoginPage');
      await tester.pumpWidget(app(const _FakeToast('Falló el pago')));
      UiHealthCapture.scan();
      await tester.pumpWidget(app(const SizedBox.shrink()));
      UiHealthCapture.scan();
      await tester.pumpWidget(app(const _FakeToast('Falló el pago')));
      UiHealthCapture.scan();
      expect(errors('ui_error'), hasLength(2));
    });

    test('looksLikeError reconoce fallos en español e inglés', () {
      for (final t in [
        'Error al guardar',
        'No se pudo cargar',
        'Algo salió mal. Inténtalo de nuevo',
        'Falló la conexión',
        'Request failed',
        'Something went wrong',
        'Sin conexión',
      ]) {
        expect(UiHealthCapture.looksLikeError(t), isTrue, reason: t);
      }
      for (final t in ['Producto agregado', '¿Eliminar la lista?', 'Gracias']) {
        expect(UiHealthCapture.looksLikeError(t), isFalse, reason: t);
      }
    });
  });

  group('imágenes', () {
    void network(String url, {int? status, String? error}) =>
        ThorCore.instance!.recorder.record(ThorEventKind.network, {
          'method': 'GET',
          'url': url,
          'durationMs': 30,
          if (status != null) 'statusCode': status,
          if (error != null) 'error': error,
        });

    test('una imagen con 404 en la capa de red es image_error con URL', () {
      network('https://cdn.x.com/a/logo.png', status: 404);
      final found = errors('image_error');
      expect(found, hasLength(1));
      expect(found.single['url'], 'https://cdn.x.com/a/logo.png');
      expect(found.single['statusCode'], 404);
      expect(found.single['message'], contains('HTTP 404'));
      expect(found.single['message'], contains('logo.png'));
    });

    test('lo que no es imagen o no falló se ignora', () {
      network('https://api.x.com/orders', status: 500);
      network('https://cdn.x.com/ok.png', status: 200);
      expect(errors('image_error'), isEmpty);
    });

    test('mismo URL en 5 s: una sola vez; tras la ventana, otra', () {
      network('https://cdn.x.com/logo.png?v=1', status: 404);
      network('https://cdn.x.com/logo.png?v=2', status: 404);
      expect(errors('image_error'), hasLength(1));
      fakeMs += 6000;
      network('https://cdn.x.com/logo.png', status: 404);
      expect(errors('image_error'), hasLength(2));
    });

    test('una cuadrícula con el CDN caído no genera cientos de errores', () {
      for (var i = 0; i < 100; i++) {
        network('https://cdn.x.com/p/$i.png', status: 503);
      }
      expect(errors('image_error').length, lessThanOrEqualTo(10));
      fakeMs += 6000;
      network('https://cdn.x.com/p/otra.png', status: 503);
      expect(errors('image_error').length, lessThanOrEqualTo(11));
    });

    test('NetworkImageLoadException de Flutter: image_error, no flutter', () {
      final uri = Uri.parse('https://cdn.x.com/banner.jpg');
      ErrorCapture.recordFlutterError(
        FlutterErrorDetails(
          exception: NetworkImageLoadException(statusCode: 403, uri: uri),
          library: 'image resource service',
        ),
      );
      expect(errors('flutter'), isEmpty);
      final found = errors('image_error');
      expect(found.single['url'], 'https://cdn.x.com/banner.jpg');
      expect(found.single['statusCode'], 403);
    });

    test('la red y la excepción de la misma imagen no se duplican', () {
      final uri = Uri.parse('https://cdn.x.com/banner.jpg');
      network(uri.toString(), status: 404);
      ErrorCapture.recordFlutterError(
        FlutterErrorDetails(
          exception: NetworkImageLoadException(statusCode: 404, uri: uri),
          library: 'image resource service',
        ),
      );
      expect(errors('image_error'), hasLength(1));
    });

    test('otro fallo de imagen (decodificación) también se etiqueta', () {
      ErrorCapture.recordFlutterError(
        FlutterErrorDetails(
          exception: Exception('Invalid image data'),
          library: 'image resource service',
        ),
      );
      expect(errors('image_error'), hasLength(1));
    });
  });

  group('desbordes de layout', () {
    testWidgets('un RenderFlex overflow se etiqueta layout_overflow',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(children: [SizedBox(width: 5000, height: 20)]),
          ),
        ),
      );
      final exception = tester.takeException();
      expect(exception, isA<FlutterError>());
      ErrorCapture.recordFlutterError(
        FlutterErrorDetails(exception: exception as Object),
      );
      expect(errors('layout_overflow'), hasLength(1));
    });
  });
}

class _SkeletonList extends StatelessWidget {
  const _SkeletonList();

  @override
  Widget build(BuildContext context) =>
      const Column(children: [_SkeletonBox(), _SkeletonBox()]);
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox();

  @override
  Widget build(BuildContext context) => const SizedBox(width: 100, height: 20);
}

class _FakeToast extends StatelessWidget {
  const _FakeToast(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(child: Text(message));
}
