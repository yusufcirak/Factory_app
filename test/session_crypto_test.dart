import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:zemits_factory/services/zm_session_crypto.dart';

/// session_vector.json, modül tarafını Python `cryptography` ile simüle eden
/// bağımsız bir üretecin çıktısı (imza DER, ECDH + HKDF, AES-GCM).
void main() {
  final v = jsonDecode(File('test/session_vector.json').readAsStringSync()) as Map<String, dynamic>;

  test('oturum imzası doğrulanır', () {
    expect(
      ZmSessionCrypto.verifySession(
        modulePubB64: v['modulePub'],
        phoneEpk: v['phoneEpk'],
        moduleEpk: v['moduleEpk'],
        n: v['n'],
        sigB64: v['sig'],
      ),
      isTrue,
    );
  });

  test('yanlış epk ile imza tutmaz', () {
    expect(
      ZmSessionCrypto.verifySession(
        modulePubB64: v['modulePub'],
        phoneEpk: v['moduleEpk'],
        moduleEpk: v['phoneEpk'],
        n: v['n'],
        sigB64: v['sig'],
      ),
      isFalse,
    );
  });

  test('ECDH + HKDF aynı anahtarı verir, RESP çözülür', () {
    final priv = ECPrivateKey(BigInt.parse(v['phonePrivHex'], radix: 16), ZmSessionCrypto.domain);
    final key = ZmSessionCrypto.deriveKey(priv, v['moduleEpk'], v['n']);
    expect(ZmSessionCrypto.hex(key), v['keyHex']);

    final plain = ZmSessionCrypto.decrypt(key, base64.decode(v['respB64']));
    expect(utf8.decode(plain!), v['plain']);
  });

  test('şifreleme gidiş-dönüş; bozuk tag reddedilir', () {
    final key = Uint8List.fromList(List.generate(32, (i) => i));
    final iv = Uint8List.fromList(List.generate(12, (i) => 100 + i));
    final ct = ZmSessionCrypto.encrypt(key, utf8.encode('{"op":"scan"}'), iv);
    expect(utf8.decode(ZmSessionCrypto.decrypt(key, ct)!), '{"op":"scan"}');
    ct[ct.length - 1] ^= 1;
    expect(ZmSessionCrypto.decrypt(key, ct), isNull);
  });
}
