/// Reglas de captura de cuerpos POR ENDPOINT: más bytes y extractos.
///
/// El tope global (`ThorNetworkCapture.maxBodyBytes`, 8 KB) corta las
/// respuestas grandes (`CategoryTree` 137 KB, patrocinados 141-180 KB,
/// `promo/upc` 282 KB) y compararlas entre sesiones se vuelve imposible: lo
/// que sirve de un árbol de categorías son sus conteos (`$..quantity`), no
/// sus 137 KB. Una [ThorBodyRule] dice, para las rutas que casan con
/// [pathPattern]:
///
/// - [extracts]: `nombre → JSONPath`. Se evalúan sobre el cuerpo COMPLETO
///   (hasta [extractMaxBytes]) YA redactado, y el resultado resumido va en
///   `payload.extracts` (`{n, sum, min, max, values?}`); no hace falta
///   retener el cuerpo entero.
/// - [maxBytes]: cuántos bytes del cuerpo se conservan en el evento y el
///   replay para esas rutas (por defecto el tope global).
///
/// ```dart
/// Thor.run(bodyRules: [
///   ThorBodyRule(
///     pathPattern: r'/CategoryTree',
///     extracts: {'quantity': r'$..quantity'},
///   ),
/// ]);
/// ```
class ThorBodyRule {
  /// Crea una regla. [pathPattern] es una expresión regular que se busca
  /// (no ancla) en la RUTA de la petición.
  const ThorBodyRule({
    required this.pathPattern,
    this.extracts = const {},
    this.maxBytes,
    this.extractMaxBytes = defaultExtractMaxBytes,
  });

  /// Tope por defecto del cuerpo analizado para los extractos (2 MB): más
  /// allá el JSON no se retiene entero y el extracto se marca parcial.
  static const defaultExtractMaxBytes = 2 * 1024 * 1024;

  /// Regex (sobre la ruta) de los endpoints a los que aplica.
  final String pathPattern;

  /// `nombre → JSONPath` (ver [JsonPath]).
  final Map<String, String> extracts;

  /// Bytes de cuerpo conservados en el evento; `null` = tope global.
  final int? maxBytes;

  /// Máximo del cuerpo que se retiene para evaluar [extracts].
  final int extractMaxBytes;

  /// ¿Aplica a [path]?
  bool matches(String path) => _compiled(pathPattern).hasMatch(path);

  static final Map<String, RegExp> _cache = {};
  static RegExp _compiled(String pattern) =>
      _cache[pattern] ??= RegExp(pattern);
}

/// JSONPath mínimo — lo justo para extraer cifras de un cuerpo grande, sin
/// dependencias:
///
/// - `$` raíz, `.clave`, `['clave']`, `[n]` (índice; negativo desde el
///   final), `[*]` / `.*` (todos los hijos) y `..clave` (descenso
///   recursivo: `$..quantity` toda clave `quantity` a cualquier
///   profundidad).
///
/// Una ruta inválida lanza [FormatException] al compilarla; evaluar nunca
/// lanza.
class JsonPath {
  JsonPath._(this._steps, this.source);

  /// Compila [path].
  factory JsonPath.parse(String path) {
    final steps = <_Step>[];
    var i = 0;
    final s = path.trim();
    if (s.isEmpty || s[0] != r'$') {
      throw FormatException('JSONPath debe empezar con \$: $path');
    }
    i = 1;
    while (i < s.length) {
      final c = s[i];
      if (c == '.') {
        final recursive = i + 1 < s.length && s[i + 1] == '.';
        i += recursive ? 2 : 1;
        if (i < s.length && s[i] == '*') {
          steps.add(_Step(_Kind.wildcard, recursive: recursive));
          i++;
          continue;
        }
        final start = i;
        while (i < s.length && s[i] != '.' && s[i] != '[') {
          i++;
        }
        final name = s.substring(start, i);
        if (name.isEmpty) throw FormatException('JSONPath inválido: $path');
        steps.add(_Step(_Kind.key, key: name, recursive: recursive));
      } else if (c == '[') {
        final end = s.indexOf(']', i);
        if (end < 0) throw FormatException('JSONPath sin cerrar: $path');
        final inner = s.substring(i + 1, end).trim();
        i = end + 1;
        if (inner == '*') {
          steps.add(_Step(_Kind.wildcard));
        } else if (inner.length >= 2 &&
            (inner.startsWith("'") || inner.startsWith('"')) &&
            inner.endsWith(inner[0])) {
          steps.add(
            _Step(_Kind.key, key: inner.substring(1, inner.length - 1)),
          );
        } else {
          final n = int.tryParse(inner);
          if (n == null) throw FormatException('JSONPath inválido: $path');
          steps.add(_Step(_Kind.at, index: n));
        }
      } else {
        throw FormatException('JSONPath inválido en $i: $path');
      }
    }
    return JsonPath._(steps, path);
  }

  final List<_Step> _steps;

  /// El texto original.
  final String source;

  /// Tope de nodos visitados: un cuerpo patológico no cuelga la UI.
  static const maxNodes = 200000;

  /// Los valores que [json] tiene en esta ruta (vacío si ninguno).
  List<Object?> eval(Object? json) {
    var current = <Object?>[json];
    final budget = _Budget(maxNodes);
    for (final step in _steps) {
      final next = <Object?>[];
      for (final node in current) {
        _apply(step, node, next, budget);
        if (budget.left <= 0) break;
      }
      current = next;
      if (current.isEmpty) break;
    }
    return current;
  }

  static void _apply(_Step step, Object? node, List<Object?> out, _Budget b) {
    if (--b.left <= 0) return;
    switch (step.kind) {
      case _Kind.key:
        if (step.recursive) {
          _descend(node, step.key!, out, b);
        } else if (node is Map && node.containsKey(step.key)) {
          out.add(node[step.key]);
        }
      case _Kind.at:
        if (node is List && node.isNotEmpty) {
          final i = step.index! < 0 ? node.length + step.index! : step.index!;
          if (i >= 0 && i < node.length) out.add(node[i]);
        }
      case _Kind.wildcard:
        if (step.recursive) {
          _descendAll(node, out, b);
        } else if (node is Map) {
          out.addAll(node.values);
        } else if (node is List) {
          out.addAll(node);
        }
    }
  }

  static void _descend(Object? node, String key, List<Object?> out, _Budget b) {
    if (--b.left <= 0) return;
    if (node is Map) {
      for (final MapEntry(key: k, value: v) in node.entries) {
        if (k == key) out.add(v);
        _descend(v, key, out, b);
      }
    } else if (node is List) {
      for (final v in node) {
        _descend(v, key, out, b);
      }
    }
  }

  static void _descendAll(Object? node, List<Object?> out, _Budget b) {
    if (--b.left <= 0) return;
    if (node is Map) {
      for (final v in node.values) {
        out.add(v);
        _descendAll(v, out, b);
      }
    } else if (node is List) {
      for (final v in node) {
        out.add(v);
        _descendAll(v, out, b);
      }
    }
  }

  /// Máximo de valores sueltos que [summarize] conserva.
  static const maxSummaryValues = 50;

  /// Resumen compacto de [values] para el evento: `{n}` siempre; con
  /// números, `sum`/`min`/`max` y hasta [maxSummaryValues] `values`; con
  /// textos, hasta 20 distintos en `first`.
  static Map<String, Object?> summarize(List<Object?> values) {
    final nums = values.whereType<num>().toList();
    final out = <String, Object?>{'n': values.length};
    if (nums.isNotEmpty && nums.length == values.length) {
      var sum = 0.0;
      var min = nums.first;
      var max = nums.first;
      for (final n in nums) {
        sum += n;
        if (n < min) min = n;
        if (n > max) max = n;
      }
      out
        ..['sum'] = sum == sum.roundToDouble() ? sum.round() : sum
        ..['min'] = min
        ..['max'] = max
        ..['values'] = nums.take(maxSummaryValues).toList();
    } else if (values.isNotEmpty) {
      final texts = <String>{};
      for (final v in values) {
        if (v is String || v is num || v is bool) texts.add('$v');
        if (texts.length >= 20) break;
      }
      out['first'] = texts.toList();
    }
    return out;
  }
}

class _Budget {
  _Budget(this.left);
  int left;
}

enum _Kind { key, at, wildcard }

class _Step {
  _Step(this.kind, {this.key, this.index, this.recursive = false});
  final _Kind kind;
  final String? key;
  final int? index;
  final bool recursive;
}
