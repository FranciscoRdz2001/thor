/// ¿El nombre de un estado (`CheckoutError`, `LoadFailure`) tiene pinta de
/// fallo? Heurística compartida: el narrador lo usa para decidir qué estado
/// contar y el tope de ráfagas para NUNCA recortar una transición a fallo
/// (es la línea de estado que explica el bug).
bool looksLikeFailureName(String name) {
  final lower = name.toLowerCase();
  return lower.contains('error') ||
      lower.contains('fail') ||
      lower.contains('fallo');
}
