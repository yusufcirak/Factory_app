import 'package:flutter_test/flutter_test.dart';
import 'package:zemits_factory/models/gs1.dart';

void main() {
  test('etiketteki parantezli biçim', () {
    final l = parseGs1('(01)00860013757588(11)260901(10)1754(21)20250007');
    expect(l.gtin, '00860013757588');
    expect(l.manufactureDate, '2026-09-01');
    expect(l.lot, '1754');
    expect(l.serial, '20250007');
  });

  test('tarayıcı ham çıktısı (]C1 + GS)', () {
    final l = parseGs1(']C1010086001375758811260901101754\u001d2120250007');
    expect(l.gtin, '00860013757588');
    expect(l.manufactureDate, '2026-09-01');
    expect(l.lot, '1754');
    expect(l.serial, '20250007');
  });

  test('ham çıktıda alan sırası farklı olabilir', () {
    final l = parseGs1('01008600137575882120250007\u001d10175411260901');
    expect(l.serial, '20250007');
    expect(l.lot, '175411260901'); // GS yoksa lot sona kadar sürer — etiket hatalı
  });

  test('GTIN kontrol hanesi', () {
    expect(isValidGtin('00860013757588'), isTrue);
    expect(isValidGtin('00860013757587'), isFalse);
    expect(() => parseGs1('(01)00860013757587(21)1'), throwsA(isA<Gs1FormatException>()));
  });

  test('gün 00 = ayın son günü', () {
    expect(gs1DateToIso('260200'), '2026-02-28');
    expect(() => gs1DateToIso('261301'), throwsA(isA<Gs1FormatException>()));
  });
}
