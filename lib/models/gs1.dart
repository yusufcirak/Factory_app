/// GS1-128 / GS1 DataMatrix etiket çözümleyici.
///
/// Cihaz etiketindeki UDI: `(01)00860013757588(11)260901(10)1754(21)20250007`
///   01 GTIN (model), 11 üretim tarihi, 10 lot, 21 seri no.
///
/// Kabul edilen girdiler:
///  - parantezli insan-okur biçim (elle giriş),
///  - tarayıcının ham çıktısı: opsiyonel `]C1`/`]d2`/`]Q3` simge öneki, değişken
///    uzunluklu alanların sonunda GS (0x1D) ayıracı.
class Gs1Label {
  final String? gtin;

  /// `YYYY-MM-DD`
  final String? manufactureDate;
  final String? lot;
  final String? serial;
  final String raw;

  const Gs1Label({this.gtin, this.manufactureDate, this.lot, this.serial, required this.raw});

  bool get isComplete => gtin != null && serial != null;

  @override
  String toString() => 'Gs1Label(gtin: $gtin, date: $manufactureDate, lot: $lot, serial: $serial)';
}

class Gs1FormatException implements Exception {
  final String message;
  Gs1FormatException(this.message);
  @override
  String toString() => message;
}

const _gs = '\u001d';

/// Sabit uzunluklu AI'lar (GS1 Genel Şartnameleri, tablo 5.4.7.1'in kullanılan kısmı).
const _fixedLength = <String, int>{
  '00': 18, '01': 14, '02': 14,
  '11': 6, '12': 6, '13': 6, '15': 6, '16': 6, '17': 6,
  '20': 2,
};

/// Değişken uzunluklu alanların üst sınırı.
const _maxVariable = <String, int>{'10': 20, '21': 20, '22': 20};

Gs1Label parseGs1(String input) {
  var s = input.trim();
  // Simge tanımlayıcı öneki (]C1 = GS1-128, ]d2 = DataMatrix, ]Q3 = QR, ]e0 = DataBar)
  if (RegExp(r'^\][A-Za-z]\d').hasMatch(s)) s = s.substring(3);
  // Bazı tarayıcılar FNC1'i metin olarak verir.
  s = s.replaceAll('<GS>', _gs).replaceAll('{GS}', _gs);
  if (s.isEmpty) throw Gs1FormatException('Label data is empty.');

  final fields = s.contains('(') ? _parseBracketed(s) : _parseRaw(s);

  final gtin = fields['01'];
  if (gtin != null && !isValidGtin(gtin)) {
    throw Gs1FormatException('Invalid GTIN check digit: $gtin');
  }
  for (final ai in ['10', '21']) {
    final v = fields[ai];
    if (v != null && (v.isEmpty || v.length > _maxVariable[ai]!)) {
      throw Gs1FormatException('($ai) must be 1–${_maxVariable[ai]} characters.');
    }
  }
  final date = fields['11'];
  return Gs1Label(
    gtin: gtin,
    manufactureDate: date == null ? null : gs1DateToIso(date),
    lot: fields['10'],
    serial: fields['21'],
    raw: input,
  );
}

Map<String, String> _parseBracketed(String s) {
  final out = <String, String>{};
  final re = RegExp(r'\((\d{2,4})\)([^(]*)');
  final matches = re.allMatches(s).toList();
  if (matches.isEmpty || matches.first.start != 0) {
    throw Gs1FormatException('Label is not in "(AI)value" format.');
  }
  for (final m in matches) {
    final ai = m.group(1)!;
    final value = m.group(2)!.replaceAll(_gs, '').trim();
    final fixed = _fixedLength[ai];
    if (fixed != null && value.length != fixed) {
      throw Gs1FormatException('($ai) must be $fixed digits, got ${value.length}.');
    }
    out[ai] = value;
  }
  return out;
}

Map<String, String> _parseRaw(String s) {
  final out = <String, String>{};
  var i = 0;
  while (i < s.length) {
    if (s[i] == _gs) {
      i++;
      continue;
    }
    if (i + 2 > s.length) throw Gs1FormatException('Label data is truncated.');
    final ai = s.substring(i, i + 2);
    if (!RegExp(r'^\d\d$').hasMatch(ai)) {
      throw Gs1FormatException('Unexpected character: "${s.substring(i)}"');
    }
    i += 2;
    final fixed = _fixedLength[ai];
    if (fixed != null) {
      if (i + fixed > s.length) throw Gs1FormatException('($ai) must be $fixed digits.');
      out[ai] = s.substring(i, i + fixed);
      i += fixed;
    } else {
      // Değişken alan: GS'e ya da sona kadar.
      final end = s.indexOf(_gs, i);
      final stop = end < 0 ? s.length : end;
      out[ai] = s.substring(i, stop);
      i = stop;
    }
  }
  return out;
}

/// GS1 mod-10 kontrol hanesi (GTIN-8/12/13/14).
bool isValidGtin(String gtin) {
  if (!RegExp(r'^\d{8}$|^\d{12,14}$').hasMatch(gtin)) return false;
  final digits = gtin.split('').map(int.parse).toList();
  final check = digits.removeLast();
  var sum = 0;
  for (var k = 0; k < digits.length; k++) {
    // Sağdan sola: kontrol hanesinin hemen solundaki rakam ×3.
    final weight = (digits.length - k).isOdd ? 3 : 1;
    sum += digits[k] * weight;
  }
  return (10 - sum % 10) % 10 == check;
}

/// YYMMDD → YYYY-MM-DD. Gün "00" ise ayın son günü (GS1 kuralı).
String gs1DateToIso(String yymmdd) {
  if (!RegExp(r'^\d{6}$').hasMatch(yymmdd)) {
    throw Gs1FormatException('Date must be YYMMDD: $yymmdd');
  }
  final year = 2000 + int.parse(yymmdd.substring(0, 2));
  final month = int.parse(yymmdd.substring(2, 4));
  var day = int.parse(yymmdd.substring(4, 6));
  if (month < 1 || month > 12) throw Gs1FormatException('Invalid month: $yymmdd');
  final lastDay = DateTime.utc(year, month + 1, 0).day;
  if (day == 0) day = lastDay;
  if (day > lastDay) throw Gs1FormatException('Invalid day: $yymmdd');
  String two(int v) => v.toString().padLeft(2, '0');
  return '$year-${two(month)}-${two(day)}';
}
