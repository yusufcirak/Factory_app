import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/asn1.dart';
import 'package:pointycastle/export.dart';

/// Müşteri BLE oturumunun kriptografisi (docs/customer_ble_setup.md, adım 4–6
/// ve "Şifreli mesaj biçimi"). BLE'den bağımsız tutuldu ki test vektörleriyle
/// sınanabilsin (test/session_crypto_test.dart).
class ZmSessionCrypto {
  static const sigPrefix = 'zmble1';
  static const hkdfInfo = 'zemits-ble-v1';

  static final domain = ECDomainParameters('secp256r1');

  /// İmzalanan metin: base64 metinleri olduğu gibi birleştirilir.
  static String signedText(String phoneEpk, String moduleEpk, String n) => '$sigPrefix|$phoneEpk|$moduleEpk|$n';

  /// Modülün kimlik anahtarıyla (DER ECDSA / SHA-256) oturum imzası.
  static bool verifySession({
    required String modulePubB64,
    required String phoneEpk,
    required String moduleEpk,
    required String n,
    required String sigB64,
  }) {
    final seq = ASN1Parser(base64.decode(sigB64)).nextObject() as ASN1Sequence;
    final r = (seq.elements![0] as ASN1Integer).integer!;
    final s = (seq.elements![1] as ASN1Integer).integer!;
    final signer = ECDSASigner(SHA256Digest())
      ..init(false, PublicKeyParameter(ECPublicKey(point(modulePubB64), domain)));
    return signer.verifySignature(
        Uint8List.fromList(utf8.encode(signedText(phoneEpk, moduleEpk, n))), ECSignature(r, s));
  }

  /// z = ECDH X koordinatı (32 bayt BE); key = HKDF-SHA256(salt = n ASCII, ikm = z, info, 32).
  static Uint8List deriveKey(ECPrivateKey phonePriv, String moduleEpk, String n) {
    final shared = (ECDHBasicAgreement()..init(phonePriv)).calculateAgreement(ECPublicKey(point(moduleEpk), domain));
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(
          _bigIntTo32(shared), 32, Uint8List.fromList(ascii.encode(n)), Uint8List.fromList(ascii.encode(hkdfInfo))));
    final key = Uint8List(32);
    hkdf.deriveKey(null, 0, key, 0);
    return key;
  }

  /// iv (12) || AES-256-GCM şifreli metin || tag (16), AAD yok.
  static Uint8List encrypt(Uint8List key, List<int> plain, Uint8List iv) {
    final gcm = GCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    return Uint8List.fromList([...iv, ...gcm.process(Uint8List.fromList(plain))]);
  }

  /// Çözülemezse null.
  static Uint8List? decrypt(Uint8List key, Uint8List data) {
    if (data.length < 12 + 16) return null;
    try {
      final gcm = GCMBlockCipher(AESEngine())
        ..init(false, AEADParameters(KeyParameter(key), 128, data.sublist(0, 12), Uint8List(0)));
      return gcm.process(data.sublist(12));
    } catch (_) {
      return null;
    }
  }

  static ECPoint point(String b64) {
    final p = domain.curve.decodePoint(base64.decode(b64));
    if (p == null) throw Exception('Invalid P-256 public key');
    return p;
  }

  static AsymmetricKeyPair<ECPublicKey, ECPrivateKey> generateKeyPair(SecureRandom rand) =>
      (ECKeyGenerator()..init(ParametersWithRandom(ECKeyGeneratorParameters(domain), rand))).generateKeyPair();

  static SecureRandom secureRandom() {
    final seed = Random.secure();
    return FortunaRandom()..seed(KeyParameter(Uint8List.fromList(List.generate(32, (_) => seed.nextInt(256)))));
  }

  static String hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _bigIntTo32(BigInt v) {
    final out = Uint8List(32);
    var x = v;
    for (var i = 31; i >= 0; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x = x >> 8;
    }
    return out;
  }
}
