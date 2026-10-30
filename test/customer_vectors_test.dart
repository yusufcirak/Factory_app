import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:zemits_factory/services/zm_session_crypto.dart';

/// docs/customer_ble_reference/vectors.json — firmware tarafının sabit anahtarlı
/// referans vektörleri (müşteri BLE oturumu). İstemcimiz bunlarla birebir eşleşmeli.
void main() {
  final v = jsonDecode(File('../docs/customer_ble_reference/vectors.json').readAsStringSync()) as Map<String, dynamic>;
  Uint8List hex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

  test('imzalanan metin aynı', () {
    expect(ZmSessionCrypto.signedText(v['phoneEpkB64'], v['moduleEpkB64'], v['n']), v['signedString']);
  });

  test('örnek imza kimlik anahtarıyla doğrulanır', () {
    expect(
      ZmSessionCrypto.verifySession(
          modulePubB64: v['identityPubB64'], phoneEpk: v['phoneEpkB64'], moduleEpk: v['moduleEpkB64'], n: v['n'], sigB64: v['sigB64_example']),
      isTrue,
    );
  });

  test('oturum anahtarı = sessionKeyHex', () {
    final priv = ECPrivateKey(BigInt.parse(v['phoneEphPrivHex'], radix: 16), ZmSessionCrypto.domain);
    expect(ZmSessionCrypto.hex(ZmSessionCrypto.deriveKey(priv, v['moduleEpkB64'], v['n'])), v['sessionKeyHex']);
  });

  test('CMD şifrelemesi = cmdBlobHex; RESP çözülür', () {
    final key = hex(v['sessionKeyHex']);
    final blob = hex(v['cmdBlobHex']);
    final ct = ZmSessionCrypto.encrypt(key, utf8.encode(v['cmdPlain']), blob.sublist(0, 12));
    expect(ZmSessionCrypto.hex(ct), v['cmdBlobHex']);
    expect(utf8.decode(ZmSessionCrypto.decrypt(key, hex(v['respBlobHex']))!), v['respPlain']);
  });
}
