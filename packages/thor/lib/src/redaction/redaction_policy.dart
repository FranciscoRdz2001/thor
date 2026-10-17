/// Política de redacción de Thor.
///
/// Diseño deliberadamente **allowlist**: por defecto los valores sensibles se
/// tapan y solo pasa en claro lo que la app declara seguro. Una denylist
/// ("tapa estos campos") falla en silencio cuando aparece un campo nuevo con
/// PII; una allowlist falla hacia el lado seguro.
class RedactionPolicy {
  /// Crea una política.
  ///
  /// - [allowedKeys]: claves (case-insensitive) cuyos valores pasan en claro
  ///   en cualquier mapa (headers, bodies, query, estado).
  /// - [allowedBodyContentTypes]: content-types cuyos cuerpos se capturan;
  ///   cualquier otro se registra solo como `<omitido: N bytes>`.
  /// - [maxValueLength]: los valores en claro se truncan a este largo.
  /// - [captureStateValues]: si `false`, de los estados de bloc solo se
  ///   registran los TIPOS (`CheckoutError`), nunca los valores.
  const RedactionPolicy({
    this.allowedKeys = const {},
    this.allowedBodyContentTypes = const {'application/json'},
    this.maxValueLength = 2048,
    this.captureStateValues = false,
  });

  /// Política estricta: nada de valores de estado, solo claves
  /// estructurales comunes en claro. Punto de partida recomendado.
  const RedactionPolicy.strict()
      : this(
          allowedKeys: const {
            // Estructura de respuesta que no identifica a nadie.
            'status', 'status_code', 'success', 'message', 'code',
            'page', 'per_page', 'total', 'count', 'limit', 'offset',
            'content-type', 'content-length', 'accept',
          },
        );

  /// Claves permitidas, normalizadas por [_normalize] al comparar.
  final Set<String> allowedKeys;

  /// Content-types cuyos cuerpos se capturan.
  final Set<String> allowedBodyContentTypes;

  /// Largo máximo de un valor en claro antes de truncar.
  final int maxValueLength;

  /// Si los valores de estado (bloc/provider) se capturan.
  final bool captureStateValues;

  /// Marcador que sustituye a un valor redactado.
  static const redactedMarker = '█redactado█';

  // Claves que NUNCA pasan aunque estén en la allowlist — defensa en
  // profundidad contra una allowlist demasiado generosa.
  // TODAS en forma normalizada (minúsculas, '_' en vez de '-') porque se
  // comparan contra _normalize(key); una entrada con guión aquí jamás
  // matchearía (bug cazado por test).
  static const _hardDenied = {
    'authorization',
    'cookie',
    'set_cookie',
    'x_api_key',
    'api_key',
    'apikey',
    'password',
    'contrasena',
    'contraseña',
    'token',
    'access_token',
    'refresh_token',
    'secret',
    'client_secret',
    'private_key',
    'card_number',
    'cvv',
    'pin',
  };

  static String _normalize(String key) =>
      key.toLowerCase().replaceAll('-', '_');

  /// ¿Es una clave de SECRETO (contraseña, token, tarjeta…)? Va más allá
  /// de [_hardDenied]: también atrapa variantes compuestas
  /// (`userPassword`, `authToken`, `numeroTarjeta`).
  static bool isSecretKey(String key) {
    final k = _normalize(key);
    return _hardDenied.contains(k) || _secretFragment.hasMatch(k);
  }

  static final _secretFragment = RegExp(
    'password|contrase|secret|token|authorization|cookie|api_?key|cvv|cvc|'
    'card_?number|tarjeta|private_?key',
  );

  /// Copia de [value] (JSON: mapas, listas, primitivos) donde el valor de
  /// toda clave de secreto, a cualquier profundidad, es [redactedMarker].
  /// Lo demás pasa tal cual: es para datos que la app manda A PROPÓSITO.
  static Object? redactSecrets(Object? value) => switch (value) {
        final Map<Object?, Object?> m => {
            for (final MapEntry(:key, value: v) in m.entries)
              '$key': isSecretKey('$key') ? redactedMarker : redactSecrets(v),
          },
        final List<Object?> l => [for (final v in l) redactSecrets(v)],
        _ => value,
      };

  /// ¿El valor de esta clave puede pasar en claro?
  bool isKeyAllowed(String key) {
    final k = _normalize(key);
    if (_hardDenied.contains(k)) return false;
    return allowedKeys.map(_normalize).contains(k);
  }

  /// Redacta recursivamente un valor JSON-compatible.
  ///
  /// Mapas: cada entrada pasa por la allowlist. Listas: elemento a elemento.
  /// Escalares sueltos (sin clave que los ampare) se conservan solo si
  /// [keyAllowed] es `true`.
  Object? redactValue(Object? value, {bool keyAllowed = false}) {
    switch (value) {
      case null:
        return null;
      case final Map<Object?, Object?> map:
        return {
          for (final MapEntry(:key, value: v) in map.entries)
            key.toString(): isKeyAllowed(key.toString())
                ? _clamp(redactValue(v, keyAllowed: true))
                : (v is Map || v is List
                    // Estructura anidada: se desciende para conservar la
                    // FORMA del payload (útil para debug) sin sus valores.
                    ? redactValue(v)
                    : redactedMarker),
        };
      case final List<Object?> list:
        return [for (final v in list) redactValue(v, keyAllowed: keyAllowed)];
      default:
        return keyAllowed ? _clamp(value) : redactedMarker;
    }
  }

  /// Redacta un mapa de cabeceras HTTP (o similar clave→valor plano).
  Map<String, String> redactFlatMap(Map<String, String> input) => {
        for (final MapEntry(:key, :value) in input.entries)
          key: isKeyAllowed(key) ? _truncate(value) : redactedMarker,
      };

  Object? _clamp(Object? v) => v is String ? _truncate(v) : v;

  String _truncate(String s) => s.length <= maxValueLength
      ? s
      : '${s.substring(0, maxValueLength)}…(+${s.length - maxValueLength})';
}
