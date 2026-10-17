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

  // Lookbehind: un intento por corrida de texto, no uno por carácter. Sin
  // él, una línea larga sin espacios ni `@` es cuadrática (decenas de ms
  // por `print` en el hilo de UI).
  static final _emailIn = RegExp(r'(?<![^\s@])[^\s@]+@[^\s@]+');
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
  //
  // Dos pasos y lineal a propósito: la regex solo halla `clave` +
  // separador (una vez por palabra, por el lookbehind) y [isSecretKey]
  // decide; el valor se lee después con [_pairValue] SOLO si la clave es
  // de secreto. Así una clave cualquiera no se come su valor —en
  // `https://h/p?token=x`, `https:` no esconde el `token=x`— y no hay
  // retroceso catastrófico: la versión con el fragmento de secreto dentro
  // de la regex tardaba segundos en un `print` de 2000 caracteres con
  // guiones, en el hilo de UI.
  static final _pairKey = RegExp(
    r"""(?<![\w\-ñÑ])(["']?)([\w\-ñÑ]+)\1(\s*[:=]\s*)"""
    r'(?:(Bearer|Basic|Token)\s+)?',
    caseSensitive: false,
  );
  static final _pairValue =
      RegExp(r"""("(?:[^"\\]|\\.)*"|'[^']*'|[^\s,;&)}\]"']+)""");
  static final _bearer =
      RegExp(r'\b(Bearer)\s+[A-Za-z0-9\-._~+/]{8,}=*', caseSensitive: false);
  static final _basic = RegExp(r'\bBasic\s+([A-Za-z0-9+/]{8,}={0,2})');
  static final _base64Hint = RegExp('[0-9+/=]');

  /// [text] sin secretos evidentes: el valor de toda clave de secreto
  /// ([isSecretKey]: `password=…`, `"token":"…"`, `api_key: …`) y los
  /// tokens de `Bearer …` / `Basic …` sueltos se vuelven
  /// [redactedMarker]. Para texto libre (logs, labels) donde no hay mapa
  /// que pasar por la allowlist.
  static String scrubSecrets(String text) => _scrubPairs(text)
      .replaceAllMapped(_bearer, (m) => '${m[1]} $redactedMarker')
      // "Basic" es palabra común: solo si lo que sigue parece base64.
      .replaceAllMapped(
        _basic,
        (m) => _base64Hint.hasMatch(m[1]!) ? 'Basic $redactedMarker' : m[0]!,
      );

  static String _scrubPairs(String text) {
    StringBuffer? out;
    var last = 0;
    for (final m in _pairKey.allMatches(text)) {
      if (m.start < last) continue;
      final key = m[2]!;
      if (!isSecretKey(key)) continue;
      final v = _pairValue.matchAsPrefix(text, m.end);
      if (v == null) continue;
      final value = v[0]!;
      final quote =
          value.startsWith('"') || value.startsWith("'") ? value[0] : '';
      final scheme = m[4] == null ? '' : '${m[4]} ';
      (out ??= StringBuffer())
        ..write(text.substring(last, m.start))
        ..write('${m[1]}$key${m[1]}${m[3]}$scheme$quote$redactedMarker$quote');
      last = v.end;
    }
    if (out == null) return text;
    return (out..write(text.substring(last))).toString();
  }

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
