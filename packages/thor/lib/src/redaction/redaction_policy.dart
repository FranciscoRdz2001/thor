/// Qué tapa una [RedactionPolicy].
enum RedactionMode {
  /// Solo SECRETOS (default de `Thor.run` y del replay): contraseñas,
  /// tokens, cookies, `Authorization`, API keys, client secrets, tarjeta,
  /// CVV, PIN. Todo lo demás —emails, ids, nombres, direcciones, teléfonos,
  /// headers normales, rutas de URL— pasa TAL CUAL: sin eso no se puede
  /// depurar un servicio (qué usuario, qué pedido, qué respondió el
  /// backend). Los secretos se buscan por clave a cualquier profundidad
  /// (headers, query, JSON) y en texto libre (`token=…`, `Bearer …`).
  secretsOnly,

  /// Allowlist (opt-in para apps sensibles): solo pasa en claro lo que la
  /// app declara seguro en `allowedKeys`; las rutas de URL y los textos
  /// libres (logs, errores, labels) pierden además lo que tenga forma de
  /// dato personal (`:email`, `:n`, `:token`).
  allowlist,
}

/// Política de redacción de Thor.
///
/// Dos modos ([RedactionMode]):
/// - [RedactionPolicy.secretsOnly] (default): tapa SOLO secretos. Thor es
///   una herramienta para depurar servicios: ofuscar emails, ids y cuerpos
///   enteros dejaba el análisis sin la información que hace falta.
/// - [RedactionPolicy.strict] / el constructor con `allowedKeys`:
///   **allowlist** — por defecto los valores se tapan y solo pasa en claro
///   lo que la app declara seguro. Una denylist falla en silencio cuando
///   aparece un campo nuevo con PII; una allowlist falla hacia el lado
///   seguro. Es el modo para apps sensibles (salud, banca) que lo piden.
///
/// En los dos modos los secretos ([isSecretKey], [scrubSecrets]) jamás
/// pasan.
class RedactionPolicy {
  /// Crea una política en modo [RedactionMode.allowlist] (salvo que se
  /// pida [mode]).
  ///
  /// - [allowedKeys]: claves (case-insensitive) cuyos valores pasan en claro
  ///   en cualquier mapa (headers, bodies, query, estado). Solo cuenta en
  ///   modo allowlist.
  /// - [allowedBodyContentTypes]: content-types cuyos cuerpos se capturan;
  ///   cualquier otro se registra solo como `<omitido: N bytes>`. En modo
  ///   [RedactionMode.secretsOnly] se capturan además los de texto (ver
  ///   [capturesBody]).
  /// - [maxValueLength]: los valores en claro se truncan a este largo.
  /// - [captureStateValues]: si `false`, de los estados de bloc solo se
  ///   registran los TIPOS (`CheckoutError`), nunca los valores.
  const RedactionPolicy({
    this.allowedKeys = const {},
    this.allowedBodyContentTypes = const {'application/json'},
    this.maxValueLength = 2048,
    this.captureStateValues = false,
    this.mode = RedactionMode.allowlist,
  });

  /// Solo secretos: el default de `Thor.run`. Headers, query, cuerpos
  /// JSON/texto, rutas, logs, errores y labels pasan tal cual salvo los
  /// secretos (por clave a cualquier profundidad y en texto libre).
  const RedactionPolicy.secretsOnly({
    int maxValueLength = 2048,
    bool captureStateValues = false,
  }) : this(
          maxValueLength: maxValueLength,
          captureStateValues: captureStateValues,
          mode: RedactionMode.secretsOnly,
        );

  /// Política estricta (opt-in para apps sensibles): allowlist con solo
  /// claves estructurales comunes en claro, rutas de URL y textos libres
  /// sin datos con forma personal, nada de valores de estado.
  const RedactionPolicy.strict()
      : this(
          allowedKeys: const {
            // Estructura de respuesta que no identifica a nadie.
            'status', 'status_code', 'success', 'message', 'code',
            'page', 'per_page', 'total', 'count', 'limit', 'offset',
            'content-type', 'content-length', 'accept',
          },
        );

  /// Modo de la política.
  final RedactionMode mode;

  /// ¿Tapa solo secretos ([RedactionMode.secretsOnly])?
  bool get isSecretsOnly => mode == RedactionMode.secretsOnly;

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
    if (_notSecret.contains(k)) return false;
    return _hardDenied.contains(k) ||
        _secretExact.contains(k) ||
        _secretFragment.hasMatch(k);
  }

  // Claves que contienen `token` pero NO guardan un secreto: `token_type`
  // es la palabra "Bearer" de OAuth y taparla solo quita contexto al
  // depurar el login (visto en PingOne).
  static const _notSecret = {'token_type'};

  // Claves cortas que solo son secreto COMPLETAS: como fragmento romperían
  // claves normales (`shipping_pin`, `spinner`, `photo`).
  static const _secretExact = {
    'pin',
    'nip',
    'pwd',
    'pass',
    'passwd',
    'otp',
    'cvc',
    // No `auth` a secas: suele ser un OBJETO (`{"auth": {"method": …}}`)
    // que se perdería entero; su token cae por su propia clave o por JWT.
    'authentication',
    'sig',
  };

  // `token` cubre access/refresh/id/x-auth-token; `jwt` y `bearer` los
  // campos que guardan el token con otro nombre. `signature` y
  // `access_key`: URLs firmadas (S3 `X-Amz-Signature`, `aws_access_key_id`)
  // que dan acceso a quien las tenga. `session_id`: en muchos backends
  // (JSESSIONID, PHPSESSID) ES la credencial, igual que la cookie.
  static final _secretFragment = RegExp(
    'password|contrase|passcode|secret|token|authorization|cookie|'
    // `app_?key`: VTEX manda `X-VTEX-API-AppKey` (par de AppToken) y no
    // casaba con `api_?key` por el `app` de en medio (fuga vista en La
    // Comer, prueba e2e).
    'api_?key|app_?key|access_?key|subscription_?key|signature|session_?id|'
    'cvv|cvc|security_?code|card_?number|credit_?card|cc_?num|tarjeta|'
    'private_?key|jwt|bearer|credential|otp_?code',
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
    r"""(?<![\w\-ñÑ])(\\?["']?)([\w\-ñÑ]+)\1(\s*[:=]\s*)"""
    r'(?:(Bearer|Basic|Token)\s+)?',
    caseSensitive: false,
  );
  // El valor: `\"…\"` (JSON dentro de un string JSON: un `print` de
  // `jsonEncode` o un cuerpo cortado), `"…"`, `'…'` o una palabra. Una
  // comilla SIN cerrar llega hasta el final: es un cuerpo cortado por el
  // tope (`"password":"hun`) y cortar ahí no debe dejar el pedazo.
  static final _pairValue = RegExp(
    r'(\\"(?:[^"\\]|\\[^"])*(?:\\"|$)|"(?:[^"\\]|\\.)*(?:"|$)|'
    r"""'[^']*(?:'|$)|[^\s,;&)}\]"']+)""",
  );
  static final _cookieValue = RegExp(r"""[^\s"'\\][^\r\n,}\]"']*""");
  static final _bearer =
      RegExp(r'\b(Bearer)\s+[A-Za-z0-9\-._~+/]{8,}=*', caseSensitive: false);
  static final _basic = RegExp(r'\bBasic\s+([A-Za-z0-9+/]{8,}={0,2})');
  static final _base64Hint = RegExp('[0-9+/=]');

  // Un JWT suelto (`print(token)`, una ruta `/reset/<jwt>`): su cabecera
  // siempre es JSON en base64url, así que empieza con `eyJ`. Sin clave al
  // lado no hay otra forma de reconocerlo.
  static final _jwt = RegExp(r'\beyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]*');

  // Contraseña dentro de una URL (`https://user:pass@host`), p.ej. en el
  // toString de un SocketException.
  static final _userInfo =
      RegExp(r'(\b[a-z][\w+.-]*://[^\s/:@?#]*):[^\s/@?#]+@');

  // Número de tarjeta suelto: 13–19 dígitos (con espacios o guiones) que
  // empiezan como una marca (2–6: Visa, MC, Amex, Discover) y pasan Luhn.
  // El prefijo y Luhn dejan pasar teléfonos (10 dígitos), ids y epochs en
  // ms (empiezan con 1).
  static final _card = RegExp(r'(?<![\d-])[2-6](?:[ -]?\d){12,18}(?![\d])');

  static bool _luhn(String candidate) {
    final digits = candidate.replaceAll(_nonDigit, '');
    if (digits.length < 13 || digits.length > 19) return false;
    var sum = 0;
    for (var i = 0; i < digits.length; i++) {
      var d = digits.codeUnitAt(digits.length - 1 - i) - 48;
      if (i.isOdd) {
        d *= 2;
        if (d > 9) d -= 9;
      }
      sum += d;
    }
    return sum % 10 == 0;
  }

  /// [text] sin secretos evidentes: el valor de toda clave de secreto
  /// ([isSecretKey]: `password=…`, `"token":"…"`, el JSON escapado
  /// dentro de otro string, `api_key: …`, todas las cookies de
  /// `Cookie: a=1; b=2`), los tokens de `Bearer …` / `Basic …`, los JWT
  /// sueltos, la contraseña de `https://usuario:contraseña@host` y los
  /// números de tarjeta (Luhn) se vuelven [redactedMarker]. Para texto
  /// libre (logs, labels) donde no hay mapa que pasar por la allowlist.
  static String scrubSecrets(String text) => _scrubPairs(text)
      .replaceAllMapped(_bearer, (m) => '${m[1]} $redactedMarker')
      .replaceAll(_jwt, redactedMarker)
      .replaceAllMapped(_userInfo, (m) => '${m[1]}:$redactedMarker@')
      .replaceAllMapped(_card, (m) => _luhn(m[0]!) ? redactedMarker : m[0]!)
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
      // Cookie: `a=1; b=2` son VARIAS cookies; el valor llega hasta el fin
      // de la entrada, no hasta el primer `;` (si no, `b=2` pasaba).
      final v = (key.toLowerCase().contains('cookie')
              ? _cookieValue.matchAsPrefix(text, m.end)
              : null) ??
          _pairValue.matchAsPrefix(text, m.end);
      if (v == null) continue;
      final value = v[0]!;
      final quote = value.startsWith(r'\"')
          ? r'\"'
          : value.startsWith('"') || value.startsWith("'")
              ? value[0]
              : '';
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
  ///
  /// Solo secretos: toda clave que no sea de secreto ([isSecretKey]).
  /// Allowlist: solo las de [allowedKeys], y nunca las de [_hardDenied].
  bool isKeyAllowed(String key) {
    if (isSecretsOnly) return !isSecretKey(key);
    final k = _normalize(key);
    if (_hardDenied.contains(k)) return false;
    return allowedKeys.map(_normalize).contains(k);
  }

  /// [text] limpio según el modo, para texto libre que sale del
  /// dispositivo (logs, mensajes de error, labels, nombres de ruta):
  /// [scrubSecrets] en solo secretos; [scrubText] (secretos + forma de
  /// dato personal) en allowlist.
  String scrub(String text) =>
      isSecretsOnly ? scrubSecrets(text) : scrubText(text);

  /// ¿Se captura el cuerpo de este content-type?
  ///
  /// Allowlist: solo [allowedBodyContentTypes]. Solo secretos: además todo
  /// lo que es texto (JSON con sufijo `+json`, `text/*`, XML, formularios,
  /// GraphQL): es lo que hace falta para depurar un servicio. Binarios
  /// (imágenes, PDFs, octet-stream) jamás: solo su tamaño.
  bool capturesBody(String? mimeType) {
    final mime = mimeType ?? 'application/octet-stream';
    if (allowedBodyContentTypes.contains(mime)) return true;
    if (!isSecretsOnly) return false;
    return mime.startsWith('text/') ||
        mime.endsWith('+json') ||
        mime.endsWith('/json') ||
        mime.endsWith('+xml') ||
        mime.endsWith('/xml') ||
        mime == 'application/x-www-form-urlencoded' ||
        mime == 'application/graphql';
  }

  /// Redacta recursivamente un valor JSON-compatible.
  ///
  /// Solo secretos: el valor de toda clave de secreto, a cualquier
  /// profundidad, es [redactedMarker]; los textos pasan por
  /// [scrubSecrets] (un `"nota": "Bearer x"` pierde el token) y se
  /// truncan; lo demás, tal cual.
  ///
  /// Allowlist: cada entrada de un mapa pasa por la allowlist. Listas:
  /// elemento a elemento. Escalares sueltos (sin clave que los ampare) se
  /// conservan solo si [keyAllowed] es `true`.
  Object? redactValue(Object? value, {bool keyAllowed = false}) {
    if (isSecretsOnly) return _redactSecretsDeep(value);
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

  Object? _redactSecretsDeep(Object? value) => switch (value) {
        final Map<Object?, Object?> m => {
            for (final MapEntry(:key, value: v) in m.entries)
              '$key':
                  isSecretKey('$key') ? redactedMarker : _redactSecretsDeep(v),
          },
        final List<Object?> l => [for (final v in l) _redactSecretsDeep(v)],
        final String s => _truncate(scrubSecrets(s)),
        _ => value,
      };

  /// Redacta un mapa de cabeceras HTTP (o similar clave→valor plano).
  ///
  /// En solo secretos el valor de una cabecera normal pasa además por
  /// [scrubSecrets]: un `x-debug: token=abc` no fuga el token.
  Map<String, String> redactFlatMap(Map<String, String> input) => {
        for (final MapEntry(:key, :value) in input.entries)
          key: !isKeyAllowed(key)
              ? redactedMarker
              : _truncate(isSecretsOnly ? scrubSecrets(value) : value),
      };

  Object? _clamp(Object? v) => v is String ? _truncate(v) : v;

  String _truncate(String s) => s.length <= maxValueLength
      ? s
      : '${s.substring(0, maxValueLength)}…(+${s.length - maxValueLength})';
}
