import 'package:test/test.dart';
import 'package:thor/thor.dart';

void main() {
  const policy = RedactionPolicy.strict();
  String clean(String url) =>
      ThorNetworkCapture.redactUrl(Uri.parse(url), policy).toString();

  test('an email in the path never leaves (real production endpoint)', () {
    expect(
      clean('https://api.shop.example.com/cache/catalog/category-tree-'
          'favorites/api/client/cache/profile/mango1251@yahoo.com'),
      'https://api.shop.example.com/cache/catalog/category-tree-'
      'favorites/api/client/cache/profile/:email',
    );
    expect(
      clean('https://x.io/u/ana%40mail.com/orders'),
      'https://x.io/u/:email/orders',
    );
  });

  test('long numbers and tokens in the path become markers', () {
    expect(
      clean('https://x.io/address/1737154/last'),
      'https://x.io/address/:n/last',
    );
    expect(
      clean('https://x.io/phone/+52-55-1234-5678'),
      'https://x.io/phone/:n',
    );
    expect(
      clean('https://x.io/quote/9971d011677f4c0ea8336b6d37d52da4'),
      'https://x.io/quote/:token',
    );
    expect(
      clean('https://x.io/s/5a740b63-0c02-45ea-a60d-54e76d09eb99/as/x'),
      'https://x.io/s/:token/as/x',
    );
  });

  test('ordinary paths are untouched', () {
    for (final url in [
      'https://x.io/api/v1/shopmx/event',
      'https://x.io/cache/giftcards/monedero-naranja/api/monedero/pagar',
      'https://x.io/orders/123',
      'https://x.io/generate_204',
    ]) {
      expect(clean(url), url);
    }
  });

  test('query still goes through the allowlist', () {
    expect(clean('https://x.io/a?token=abc'), contains('token='));
    expect(clean('https://x.io/a?token=abc'), isNot(contains('abc')));
  });
}
