import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'zm_session_crypto.dart';

/// Müşteri BLE kurulum servisi istemcisi (docs/customer_ble_setup.md).
///
/// Bu uygulamada yalnız TEST amaçlı: kullanıcı modundaki (finalize edilmiş)
/// modüle bağlanıp INFO/durum okumak, Wi-Fi taramak ve ayarlamak için.
/// Protokol sabitleri bu sınıfın ve [ZmSessionCrypto]'nun başında; belge değişince oralar güncellenir.
class ZmCustomerBle {
  // --- Sözleşme sabitleri (customer_ble_setup.md) ---
  static const service = '5a4d0001-7a65-6d69-7473-000000000000';
  static const infoChar = '5a4d0001-7a65-6d69-7473-000000000001';
  static const sessionChar = '5a4d0001-7a65-6d69-7473-000000000002';
  static const cmdChar = '5a4d0001-7a65-6d69-7473-000000000003';
  static const respChar = '5a4d0001-7a65-6d69-7473-000000000004';
  static const namePrefix = 'Zemits-';

  /// Seri no yazılmış modülün kurulum yayın adı: "ZEM" + seri (ör. ZEM20250009).
  static const serialNamePrefix = 'ZEM';
  static String nameForSerial(String serial) => '$serialNamePrefix$serial';
  static const _timeout = Duration(seconds: 5);

  final String deviceId;
  final String name;
  final _rand = ZmSessionCrypto.secureRandom();

  Uint8List? _key;
  final _session = _Reassembler();
  final _resp = _Reassembler();
  final _sessionMsgs = StreamController<Map<String, dynamic>>.broadcast();
  final _respMsgs = StreamController<Map<String, dynamic>>.broadcast();
  final _subs = <StreamSubscription>[];
  Future<void> _lane = Future.value();
  bool _connected = false;

  /// Modülün kendiliğinden gönderdiği `status` mesajları ve kopuş (`{"op":"disconnected"}`).
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  ZmCustomerBle._(this.deviceId, this.name);

  bool get connected => _connected;
  bool get hasSession => _key != null;
  Stream<Map<String, dynamic>> get events => _events.stream;

  static Future<ZmCustomerBle> connect(BleDevice device) async {
    final c = ZmCustomerBle._(device.deviceId, device.name ?? device.rawName ?? device.deviceId);
    await UniversalBle.connect(device.deviceId, timeout: const Duration(seconds: 15));
    c._connected = true;
    c._subs.add(UniversalBle.connectionStream(device.deviceId).listen((up) {
      if (!up) c._onDisconnected();
    }));
    try {
      await UniversalBle.discoverServices(device.deviceId);
      try {
        await UniversalBle.requestMtu(device.deviceId, 247);
      } catch (_) {}
      c._subs.add(UniversalBle.characteristicValueStream(device.deviceId, sessionChar)
          .listen((v) => c._session.add(v, (m) => c._sessionMsgs.add(m))));
      c._subs.add(UniversalBle.characteristicValueStream(device.deviceId, respChar)
          .listen((v) => c._resp.add(v, c._onResp, decrypt: c._decrypt)));
      // Yazmadan önce iki bildirime de abone ol (belge: "Hızlı kontrol listesi").
      await UniversalBle.subscribeNotifications(device.deviceId, service, sessionChar);
      await UniversalBle.subscribeNotifications(device.deviceId, service, respChar);
    } catch (_) {
      await c.disconnect();
      rethrow;
    }
    return c;
  }

  Future<void> disconnect() async {
    try {
      await UniversalBle.disconnect(deviceId);
    } catch (_) {}
    _onDisconnected();
  }

  void _onDisconnected() {
    if (!_connected) return;
    _connected = false;
    _key = null; // oturum anahtarı bağlantıyla ölür
    for (final s in _subs) {
      s.cancel();
    }
    _events.add({'op': 'disconnected'});
  }

  /// INFO: `{moduleId, serial, model, fw, pub, site}` (düz JSON).
  Future<Map<String, dynamic>> readInfo() async {
    final raw = await UniversalBle.read(deviceId, service, infoChar);
    return jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
  }

  /// Şifreli oturumu kurar (adım 4–6). İmza [modulePubB64] ile doğrulanır.
  ///
  /// Gerçek Provider app'te anahtar Provider API'den gelir; bu test aracında
  /// INFO.pub kullanılır — bu, modülün o anahtarın sahibi olduğunu kanıtlar,
  /// sunucudaki kayıtla eşleştiğini değil.
  ///
  /// [nonce] verilirse `n` olarak o kullanılır: sunucunun verdiği tek kullanımlık kod.
  /// Modülün bu oturuma attığı imza ([lastProof]) sunucuya "tablet şu an bu modülün
  /// yanında" kanıtı olarak gönderilir (sağlayıcıya cihaz ekleme).
  Future<void> openSession({required String moduleId, required String modulePubB64, String? nonce}) async {
    final pair = ZmSessionCrypto.generateKeyPair(_rand);
    final myEpk = base64.encode(pair.publicKey.Q!.getEncoded(false));
    final n = nonce ?? ZmSessionCrypto.hex(_rand.nextBytes(16));

    final reply = _sessionMsgs.stream.first.timeout(_timeout,
        onTimeout: () => throw TimeoutException('Module did not answer the session request.'));
    await UniversalBle.write(deviceId, service, sessionChar,
        Uint8List.fromList(utf8.encode(jsonEncode({'epk': myEpk, 'n': n}))));
    final r = await reply;

    if (r['m'] != moduleId) throw Exception('Session reply came from another module: ${r['m']}');
    final modEpk = r['epk'] as String;
    final ok = ZmSessionCrypto.verifySession(
        modulePubB64: modulePubB64, phoneEpk: myEpk, moduleEpk: modEpk, n: n, sigB64: r['sig'] as String);
    if (!ok) throw Exception('Session signature invalid — fake or wrong device.');
    _key = ZmSessionCrypto.deriveKey(pair.privateKey, modEpk, n);
    lastProof = {'moduleId': moduleId, 'phoneEpk': myEpk, 'moduleEpk': modEpk, 'nonce': n, 'sig': r['sig'] as String};
  }

  /// Son oturumun imza kanıtı: {moduleId, phoneEpk, moduleEpk, nonce, sig}.
  Map<String, String>? lastProof;

  /// Şifreli komut (adım 7–8). `wifi` isteğinin yanıtı `status`'tur.
  ///
  /// Modül oturum açılır açılmaz ve durum değiştikçe kendiliğinden `status` gönderir
  /// (fw 0.1.2). [match] verilirse yanıt olarak yalnız ona uyan mesaj alınır.
  Future<Map<String, dynamic>> command(Map<String, dynamic> cmd,
      {Duration timeout = _timeout, bool Function(Map<String, dynamic>)? match}) {
    final result = _lane.then((_) => _command(cmd, timeout, match));
    _lane = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, dynamic>> _command(
      Map<String, dynamic> cmd, Duration timeout, bool Function(Map<String, dynamic>)? match) async {
    if (_key == null) throw Exception('No encrypted session.');
    final expect = cmd['op'] == 'wifi' ? 'status' : cmd['op'];
    final reply = _respMsgs.stream.firstWhere((m) => m['op'] == expect && (match?.call(m) ?? true)).timeout(timeout,
        onTimeout: () => throw TimeoutException('Module did not answer "${cmd['op']}".'));
    await UniversalBle.write(deviceId, service, cmdChar, _encrypt(utf8.encode(jsonEncode(cmd))));
    return reply;
  }

  void _onResp(Map<String, dynamic> m) {
    _respMsgs.add(m);
    if (m['op'] == 'status') _events.add(m);
  }

  Uint8List _encrypt(List<int> plain) => ZmSessionCrypto.encrypt(_key!, plain, _rand.nextBytes(12));

  /// Çözülemeyen mesaj yok sayılır (belge).
  Uint8List? _decrypt(Uint8List data) => _key == null ? null : ZmSessionCrypto.decrypt(_key!, data);
}

/// `[sıra][son mu] + veri` bildirim parçalarını birleştirir (SESSION ve RESP).
class _Reassembler {
  final _buf = BytesBuilder();
  int _expect = 0;

  void add(Uint8List chunk, void Function(Map<String, dynamic>) onMessage,
      {Uint8List? Function(Uint8List)? decrypt}) {
    if (chunk.length < 2) return;
    final seq = chunk[0], last = chunk[1] == 1;
    if (seq == 0) {
      _buf.clear();
      _expect = 0;
    }
    if (seq != _expect) {
      // Sıra kaçtı: mesaj bozuk, sonraki sıra-0'ı bekle.
      _buf.clear();
      _expect = -1;
      return;
    }
    _buf.add(chunk.sublist(2));
    _expect++;
    if (!last) return;
    var data = _buf.takeBytes();
    _expect = 0;
    if (decrypt != null) {
      final plain = decrypt(data);
      if (plain == null) return;
      data = plain;
    }
    try {
      onMessage(jsonDecode(utf8.decode(data)) as Map<String, dynamic>);
    } catch (_) {}
  }
}
