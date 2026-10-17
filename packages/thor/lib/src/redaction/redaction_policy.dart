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

  static final _longNumber = RegExp(r'^\+?[\d\-. ]{7,}$');
  static final _token = RegExp(r'^[A-Za-z0-9_\-=.]{20,}$');
  static final _hasDigit = RegExp(r'\d');
  static final _hasLetter = RegExp('[A-Za-z]');
  static final _nonDigit = RegExp(r'\D');

  /// Marcador si [word] (una palabra, un segmento de ruta) tiene forma de
  /// dato personal; `null` si no. email → `:email`; número de 7+ dígitos
  /// (teléfono, id de cliente, tarjeta) → `:n`; token largo con letras y
  /// dígitos (hash, uuid, jwt) → `:token`.
  ///
  /// Es la MISMA regla para rutas de URL y para textos de UI (labels de
  /// taps): un solo lugar que endurecer cuando aparezca otro caso.
  static String? personalMarker(String word) {
    if (word.contains('@')) return ':email';
    if (_longNumber.hasMatch(word) &&
        word.replaceAll(_nonDigit, '').length >= 7) {
      return ':n';
    }
    if (_token.hasMatch(word) &&
        _hasDigit.hasMatch(word) &&
        _hasLetter.hasMatch(word)) {
      return ':token';
    }
    return null;
  }

  static final _emailIn = RegExp(r'[^\s@]+@[^\s@]+');
  static final _numberIn = RegExp(r'\+?\d[\d\-. ]*\d');
  static final _longWord = RegExp(r'\S{20,}');

  /// [text] con los datos personales de [personalMarker] reemplazados por
  /// su marcador, en cualquier posición: `"Ana ana@x.com"` →
  /// `"Ana :email"`, `"Pedido 55 1234 5678"` → `"Pedido :n"`. Un número
  /// de teléfono con espacios no es UNA palabra, por eso se busca con
  /// regex sobre el texto entero y no palabra por palabra. Lo demás
  /// (nombres propios incluidos) pasa igual: esto es un filtro de forma,
  /// no un detector de PII — para eso está el enmascarado.
  ///
  /// Antes pasa por [scrubSecrets]: un label o un log con `token=…` o
  /// `Bearer …` pierde el secreto entero, no solo lo que tenga forma.
  static String scrubText(String text) => scrubSecrets(text)
      .replaceAll(_emailIn, ':email')
      .replaceAllMapped(
        _numberIn,
        (m) => m[0]!.replaceAll(_nonDigit, '').length >= 7 ? ':n' : m[0]!,
      )
      .replaceAllMapped(
        _longWord,
        (m) => personalMarker(m[0]!) ?? m[0]!,
      );

  // `clave=valor`, `clave: valor`, `"clave": "valor"` (JSON, query,
  // headers, toString de mapas). El valor puede traer esquema de auth
  // (`Authorization: Bearer x`): se conserva el esquema, cae el token.
  // La clave candidata ya debe traer un fragmento de secreto: con una
  // clave cualquiera, `https://h/p?token=x` se comería como UN par
  // (`https` : `//h/p?token=x`) y el token pasaría.
  static final _secretPair = RegExp(
    r'''(["']?)\b((?:[\w\-]*?(?:password|contrase|secret|token|'''
    r'''authorization|cookie|api[_\-]?key|cvv|cvc|card[_\-]?number|tarjeta|'''
    r'''private[_\-]?key)[\wñÑ\-]*)|pin)\1(\s*[:=]\s*)'''
    r'''(?:(Bearer|Basic|Token)\s+)?'''
    r'''("(?:[^"\\]|\\.)*"|'[^']*'|[^\s,;&)}\]"']+)''',
    caseSensitive: false,
  );
  static final _bearer =
      RegExp(r'\b(Bearer)\s+[A-Za-z0-9\-._~+/]{8,}=*', caseSensitive: false);
  static final _basic = RegExp(r'\bBasic\s+([A-Za-z0-9+/]{8,}={0,2})');
  static final _base64Hint = RegExp('[0-9+/=]');

  /// [text] sin secretos evidentes: el valor de toda clave de secreto
  /// ([isSecretKey]: `password=…`, `"token":"…"`, `api_key: …`) y los
  /// tokens de `Bearer …` / `Basic …` sueltos se vuelven
  /// [redactedMarker]. Para texto libre (logs, labels) donde no hay mapa
  /// que pasar por la allowlist.
  static String scrubSecrets(String text) => text
      .replaceAllMapped(_secretPair, (m) {
        final key = m[2]!;
        if (!isSecretKey(key)) return m[0]!;
        final value = m[5]!;
        final quote =
            value.startsWith('"') || value.startsWith("'") ? value[0] : '';
        final scheme = m[4] == null ? '' : '${m[4]} ';
        return '${m[1]}$key${m[1]}${m[3]}$scheme$quote$redactedMarker$quote';
      })
      .replaceAllMapped(_bearer, (m) => '${m[1]} $redactedMarker')
      // "Basic" es palabra común: solo si lo que sigue parece base64.
      .replaceAllMapped(
        _basic,
        (m) => _base64Hint.hasMatch(m[1]!) ? 'Basic $redactedMarker' : m[0]!,
      );

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
