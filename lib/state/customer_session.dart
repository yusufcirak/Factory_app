import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';

import '../services/factory_api.dart';
import '../services/zm_customer_ble.dart';

/// Bölüm 2, müşteri modu (TEST): finalize edilmiş modüle Provider app'in
/// yaptığı gibi bağlanır — INFO, şifreli oturum, durum, Wi-Fi tarama/ayar.
class CustomerSession extends ChangeNotifier {
  final FactoryApi api;
  CustomerSession(this.api);

  ZmCustomerBle? _ble;
  StreamSubscription<Map<String, dynamic>>? _evSub;

  bool connecting = false;
  String? phase;
  String? error;
  Map<String, dynamic>? info;
  Map<String, dynamic>? status;
  List<Map<String, dynamic>> networks = [];
  bool scanning = false;

  /// INFO.pub sunucudaki kayıtla (Device Service) karşılaştırıldı mı (adım 3).
  /// null: sunucuya sorulamadı (ayar yok / ağ yok) — yalnız INFO.pub ile devam edildi.
  bool? keyVerifiedByServer;

  bool get connected => _ble?.connected == true && _ble!.hasSession;
  String? get deviceName => _ble?.name;

  /// Genel durum: modül şu an Wi-Fi'de ve sunucuya bağlı (hangi ağ olursa olsun).
  bool get online => status?['wifi'] == 'connected' && status?['cloud'] == true;

  /// Bu oturumda gönderilen Wi-Fi denemesinin sonucu (fw 0.1.2 `attempt`/`attemptSsid`):
  /// connecting | connected | wrong_password | network_not_found | failed.
  /// Yanlış parolada modül eski ağına döner ve `wifi:connected, cloud:true` olur; bu yüzden
  /// başarı yalnız `attempt == connected` VE `cloud == true` (customer_ble_setup.md).
  String? get attempt => status?['attempt'] as String?;
  String? attemptSsid;
  bool get attemptSucceeded =>
      attempt == 'connected' && status?['cloud'] == true && status?['attemptSsid'] == attemptSsid;

  /// Son oturumun yakınlık kanıtı (sağlayıcıya cihaz ekleme için).
  Map<String, String>? get proof => _ble?.lastProof;

  /// [expectedSerial]: okutulan etiketteki seri no — ESP32'nin bildirdiğiyle aynı olmalı,
  /// yoksa yan yana duran başka bir cihaza bağlanılmış demektir; oturum açılmadan durulur.
  /// [nonce]: sunucunun verdiği tek kullanımlık kod, oturum imzasına girer.
  Future<void> connect(BleDevice device, {String? expectedSerial, String? nonce}) async {
    await disconnect();
    connecting = true;
    error = null;
    notifyListeners();
    try {
      _setPhase('Connecting...');
      _ble = await ZmCustomerBle.connect(device);
      _evSub = _ble!.events.listen(_onEvent);
      _setPhase('Reading identity...');
      info = await _ble!.readInfo();
      if (expectedSerial != null && info!['serial'] != expectedSerial) {
        throw Exception('This is not the scanned device: it reports serial number '
            '${info!['serial']}, the label says $expectedSerial.');
      }
      await _verifyKeyWithServer();
      _setPhase('Opening encrypted session...');
      await _ble!.openSession(
          moduleId: info!['moduleId'] as String, modulePubB64: info!['pub'] as String, nonce: nonce);
      _setPhase(null);
      await refreshStatus();
    } catch (e) {
      error = 'Connection failed: $e';
      await _ble?.disconnect();
      _ble = null;
    } finally {
      connecting = false;
      phase = null;
      notifyListeners();
    }
  }

  /// customer_ble_setup.md adım 3: INFO.pub, sunucudaki modül anahtarıyla birebir aynı olmalı.
  /// Kayıt yoksa ya da anahtar farklıysa DUR. Sunucuya ulaşılamazsa test aracı olarak devam eder.
  Future<void> _verifyKeyWithServer() async {
    keyVerifiedByServer = null;
    if (!api.hasToken) return;
    _setPhase('Verifying identity with server...');
    final String? serverKey;
    try {
      serverKey = await api.modulePublicKey(info!['moduleId'] as String);
    } on ApiException catch (e) {
      if (e.code == 'NETWORK') return;
      rethrow;
    }
    if (serverKey == null) throw Exception('Module is not registered on the server or its key was revoked.');
    if (serverKey != info!['pub']) throw Exception('INFO.pub does not match the server key — fake or wrong device.');
    keyVerifiedByServer = true;
  }

  Future<void> disconnect() async {
    await _evSub?.cancel();
    await _ble?.disconnect();
    _ble = null;
    info = status = null;
    networks = [];
    notifyListeners();
  }

  void _onEvent(Map<String, dynamic> e) {
    if (e['op'] == 'disconnected') {
      error = 'Connection lost.';
    } else {
      status = e;
    }
    notifyListeners();
  }

  Future<void> refreshStatus() => _guard(() async => status = await _ble!.command({'op': 'status'}));

  Future<void> scanNetworks() async {
    scanning = true;
    notifyListeners();
    await _guard(() async {
      // Modül taraması ~9 sn sürüyor (fw 0.1.2 ölçümü).
      final r = await _ble!.command({'op': 'scan'}, timeout: const Duration(seconds: 15));
      networks = ((r['networks'] as List?) ?? const []).cast<Map<String, dynamic>>();
    });
    scanning = false;
    notifyListeners();
  }

  /// Yanıt bu denemenin `attempt: connecting` status'udur; sonuç sonraki status olaylarıyla
  /// gelir. Önceki denemeden kalan ya da kendiliğinden gelen status yanıt sayılmaz.
  Future<String?> setWifi(String ssid, String pass) async {
    attemptSsid = ssid;
    await _guard(() async => status = await _ble!.command({'op': 'wifi', 'ssid': ssid, 'pass': pass},
        match: (m) => m['attemptSsid'] == ssid && m['attempt'] == 'connecting'));
    return error;
  }

  Future<void> _guard(Future<void> Function() fn) async {
    try {
      await fn();
      error = null;
    } catch (e) {
      error = e.toString();
    }
    notifyListeners();
  }

  void _setPhase(String? p) {
    phase = p;
    notifyListeners();
  }

  @override
  void dispose() {
    _evSub?.cancel();
    _ble?.disconnect();
    super.dispose();
  }
}
