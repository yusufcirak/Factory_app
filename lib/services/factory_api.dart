import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import 'station_auth.dart';
import 'zemits_http.dart';

class ApiException implements Exception {
  final int status;
  final String code;
  final String message;
  final Object? details;
  ApiException(this.status, this.code, this.message, [this.details]);
  @override
  String toString() => '$code: $message';
}

class DeviceModel {
  final String id;
  final String name;
  final String? gtin;
  DeviceModel({required this.id, required this.name, this.gtin});
  factory DeviceModel.fromJson(Map<String, dynamic> j) =>
      DeviceModel(id: j['id'] as String, name: (j['name'] as String?) ?? j['id'] as String, gtin: j['gtin'] as String?);
}

class FirmwareFile {
  final int idx;
  final String name;
  final int size;
  final String sha256;
  final String url;
  FirmwareFile.fromJson(Map<String, dynamic> j)
      : idx = j['idx'] as int,
        name = j['name'] as String,
        size = (j['size'] as num).toInt(),
        sha256 = j['sha256'] as String,
        url = j['url'] as String;
}

class FirmwarePackage {
  final String packageId;
  final String version;
  final String? deviceName;
  final String rolloutStage;
  final List<FirmwareFile> files;
  FirmwarePackage.fromJson(Map<String, dynamic> j)
      : packageId = j['packageId'] as String,
        version = j['version'] as String,
        deviceName = j['deviceName'] as String?,
        rolloutStage = j['rolloutStage'] as String,
        files = (j['files'] as List).map((f) => FirmwareFile.fromJson(f as Map<String, dynamic>)).toList();
}

class FirmwareList {
  final FirmwarePackage? recommended;
  final List<FirmwarePackage> packages;
  FirmwareList(this.recommended, this.packages);
}

/// Device Service fabrika API'si (`/factory/v1`, istasyon jetonu).
class FactoryApi {
  final http.Client _client = zemitsHttpClient();

  /// İstasyon jetonu buradan gelir; 401 olunca kayıt akışına dönülür.
  final StationAuth auth;

  FactoryApi(this.auth);

  bool get hasToken => auth.token != null;

  Map<String, String> get _auth => {'Authorization': 'Bearer ${auth.token}'};

  /// Sunucunun verdiği indirme adresleri `PUBLIC_BASE_URL` ile kuruluyor; o adres
  /// (device.zemits.ai) henüz çözülmüyorsa da çalışsın diye yol korunup taban
  /// [AppConfig.apiBaseUrl]'den alınır.
  Uri _resolve(String pathOrUrl) {
    final u = Uri.parse(pathOrUrl);
    final base = Uri.parse(AppConfig.apiBaseUrl);
    return base.replace(path: u.path, query: u.hasQuery ? u.query : null);
  }

  Future<dynamic> _json(Future<http.Response> req) async {
    final http.Response res;
    try {
      res = await req.timeout(const Duration(seconds: 20));
    } on SocketException catch (e) {
      throw ApiException(0, 'NETWORK', 'Cannot reach the server: ${e.message}');
    }
    final body = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode >= 400) {
      final err = body is Map ? body['error'] as Map? : null;
      final code = (err?['code'] as String?) ?? 'HTTP_${res.statusCode}';
      if (code == 'SYSTEM_DISABLED') {
        throw ApiException(res.statusCode, code, 'The Zemits system is turned off in the admin panel.');
      }
      // İstasyon panelden pasifleştirildi ya da jeton yanlış: jetonu sil, kayda dön.
      if (res.statusCode == 401 && code == 'STATION_UNAUTHORIZED') unawaited(auth.invalidate());
      throw ApiException(res.statusCode, code,
          (err?['message'] as String?) ?? res.reasonPhrase ?? '', err?['details']);
    }
    return body;
  }

  Future<List<DeviceModel>> models() async {
    final j = await _json(_client.get(_resolve('/factory/v1/models'), headers: _auth));
    return ((j as Map)['models'] as List).map((m) => DeviceModel.fromJson(m as Map<String, dynamic>)).toList();
  }

  Future<FirmwareList> firmware({required String model, String? hardwareRevision}) async {
    final uri = _resolve('/factory/v1/firmware').replace(queryParameters: {
      'model': model,
      'kind': 'esp',
      if (hardwareRevision != null && hardwareRevision.isNotEmpty) 'hardwareRevision': hardwareRevision,
    });
    final j = await _json(_client.get(uri, headers: _auth)) as Map<String, dynamic>;
    final rec = j['recommended'];
    return FirmwareList(
      rec == null ? null : FirmwarePackage.fromJson(rec as Map<String, dynamic>),
      (j['packages'] as List).map((p) => FirmwarePackage.fromJson(p as Map<String, dynamic>)).toList(),
    );
  }

  /// Kayıtlı modülün açık anahtarı (base64 65 bayt) — yoksa ya da iptal edildiyse null.
  /// Müşteri modu testinde BLE INFO.pub ile birebir karşılaştırılır (customer_ble_setup.md adım 3).
  Future<String?> modulePublicKey(String moduleId) async {
    try {
      final j = await _json(_client.get(_resolve('/factory/v1/registrations/$moduleId'), headers: _auth));
      return (j as Map)['publicKey'] as String?;
    } on ApiException catch (e) {
      if (e.code == 'MODULE_NOT_FOUND') return null;
      rethrow;
    }
  }

  // --- Provider: cihaz verileri (/factory/v1/devices, internal uçların istasyon aynası) ---

  /// Device Hub listesi: `{serial, deviceModelId, status, via, lastSeenAt, hostBusy, versions}`.
  Future<List<Map<String, dynamic>>> devicesStatus(List<String> serials) async {
    if (serials.isEmpty) return [];
    final j = await _json(_client.post(_resolve('/factory/v1/devices/status'),
        headers: {..._auth, 'Content-Type': 'application/json'}, body: jsonEncode({'serials': serials})));
    return ((j as Map)['devices'] as List).cast<Map<String, dynamic>>();
  }

  /// Sağlayıcılar: `[{id, name, deviceCount}]`.
  Future<List<Map<String, dynamic>>> providers() async =>
      ((await _json(_client.get(_resolve('/factory/v1/providers'), headers: _auth))) as List).cast<Map<String, dynamic>>();

  /// Sağlayıcının cihazları: devices/status alanları + modelName, gtin, ownedSince.
  Future<List<Map<String, dynamic>>> providerDevices(String providerId) async {
    final j = await _json(
        _client.get(_resolve('/factory/v1/providers/${Uri.encodeComponent(providerId)}/devices'), headers: _auth));
    return ((j as Map)['devices'] as List).cast<Map<String, dynamic>>();
  }

  /// Sağlayıcıya cihaz ekleme, adım 1: tek kullanımlık kod (BLE oturumunda `n` olur).
  Future<String> claimChallenge(String providerId) async {
    final j = await _json(_client.post(
        _resolve('/factory/v1/providers/${Uri.encodeComponent(providerId)}/claims/challenge'),
        headers: {..._auth, 'Content-Type': 'application/json'}, body: '{}'));
    return (j as Map)['nonce'] as String;
  }

  /// Sağlayıcıya cihaz ekleme, adım 2: modülün oturum imzasıyla yakınlık kanıtı.
  /// Sunucu imzayı o seri numarasına bağlı modülün anahtarıyla doğrular.
  Future<Map<String, dynamic>> claimDevice(String providerId, String serial, Map<String, String> proof) async =>
      await _json(_client.post(_resolve('/factory/v1/providers/${Uri.encodeComponent(providerId)}/claims'),
          headers: {..._auth, 'Content-Type': 'application/json'},
          body: jsonEncode({'serial': serial, ...proof}))) as Map<String, dynamic>;

  /// Etiketle ekleme (kurulu klinik, cihaz Wi-Fi'yi kardeşten alır — M-17): geçici sahiplik.
  /// Cihaz bu klinikte görülünce sunucu kesinleştirir; 1 günde görülmezse düşer.
  Future<Map<String, dynamic>> claimByLabel(String providerId, String serial) async =>
      await _json(_client.post(_resolve('/factory/v1/providers/${Uri.encodeComponent(providerId)}/claims'),
          headers: {..._auth, 'Content-Type': 'application/json'},
          body: jsonEncode({'method': 'label', 'serial': serial}))) as Map<String, dynamic>;

  /// Yanlış etiket: yalnız kesinleşmemiş kaydı iptal eder.
  Future<void> cancelProvisional(String providerId, String serial) async => await _json(_client.delete(
      _resolve('/factory/v1/providers/${Uri.encodeComponent(providerId)}/claims/${Uri.encodeComponent(serial)}'),
      headers: _auth));

  /// DWIN güncellemesini kullanıcı başlatır (D15: ESP onaysız kurulur, DWIN "Update" ile).
  /// Cihaz ekran boştayken yükler (waiting_for_idle).
  Future<Map<String, dynamic>> installUpdate(String serial, String updateId) async => await _json(_client.post(
      _resolve('/factory/v1/devices/${Uri.encodeComponent(serial)}/updates/${Uri.encodeComponent(updateId)}/install'),
      headers: {..._auth, 'Content-Type': 'application/json'},
      body: '{}')) as Map<String, dynamic>;

  // --- Wi-Fi değiştirme: uzaktan BLE açma (connectivity_rules.md §9, §16) ---

  /// Sunucu cihaza imzalı `ble_setup` komutu gönderir: cihaz Wi-Fi'yi bırakıp BLE'yi açar.
  /// 202 {requestId, stage:"sent", route, expiresAt}; 409 DEVICE_OFFLINE / SETUP_IN_PROGRESS.
  Future<Map<String, dynamic>> requestBleSetup(String serial, {String? providerId, int windowS = 300}) async =>
      await _json(_client.post(_resolve('/factory/v1/devices/${Uri.encodeComponent(serial)}/ble-setup'),
          headers: {..._auth, 'Content-Type': 'application/json'},
          body: jsonEncode({'windowS': windowS, if (providerId != null) 'providerId': providerId}))) as Map<String, dynamic>;

  /// {requestId, stage, reason, ssid, fellBackTo, history, windowEndsAt}.
  Future<Map<String, dynamic>> bleSetupStatus(String serial, String requestId) async => await _json(_client.get(
      _resolve('/factory/v1/devices/${Uri.encodeComponent(serial)}/ble-setup/${Uri.encodeComponent(requestId)}'),
      headers: _auth)) as Map<String, dynamic>;

  // --- Wi-Fi değiştirme: cihaz çevrimiçiyken sunucudan, BLE'siz (MOBILE_API.md) ---

  /// Şifre karta yalnız onun açabileceği şekilde şifreli gider; uygulama şifreyi loglamaz.
  /// 202 {requestId, stage:"sent", route, ssid, expiresAt}; 409 DEVICE_OFFLINE / SETUP_IN_PROGRESS.
  Future<Map<String, dynamic>> setWifi(String serial, String ssid, String password) async =>
      await _json(_client.post(_resolve('/factory/v1/devices/${Uri.encodeComponent(serial)}/wifi'),
          headers: {..._auth, 'Content-Type': 'application/json'},
          body: jsonEncode({'ssid': ssid, 'password': password}))) as Map<String, dynamic>;

  /// ble-setup ile aynı biçim + cmd:"wifi_set". Başarı yalnız `cloud_ok`.
  Future<Map<String, dynamic>> wifiStatus(String serial, String requestId) async => await _json(_client.get(
      _resolve('/factory/v1/devices/${Uri.encodeComponent(serial)}/wifi/${Uri.encodeComponent(requestId)}'),
      headers: _auth)) as Map<String, dynamic>;

  /// Sağlayıcının cihazlarının son 10 dk'da duyduğu, sahipsiz kayıtlı cihazlar (§8).
  Future<List<Map<String, dynamic>>> nearbyUnclaimed(String providerId) async =>
      ((await _json(_client.get(
                  _resolve('/factory/v1/providers/${Uri.encodeComponent(providerId)}/nearby-unclaimed'),
                  headers: _auth))) as List)
          .cast<Map<String, dynamic>>();

  /// Bağlantı özeti (modulePublicKey dahil).
  Future<Map<String, dynamic>> device(String serial) async =>
      await _json(_client.get(_resolve('/factory/v1/devices/${Uri.encodeComponent(serial)}'), headers: _auth))
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> deviceUpdates(String serial, {String lang = 'en'}) async => await _json(_client.get(
      _resolve('/factory/v1/devices/${Uri.encodeComponent(serial)}/updates').replace(queryParameters: {'lang': lang}),
      headers: _auth)) as Map<String, dynamic>;

  Future<Map<String, dynamic>> deviceUsage(String serial, {int days = 30}) async => await _json(_client.get(
      _resolve('/factory/v1/devices/${Uri.encodeComponent(serial)}/usage').replace(queryParameters: {'days': '$days'}),
      headers: _auth)) as Map<String, dynamic>;

  /// Sunucu imza anahtarı (PEM). Modüle provision sırasında yazılır.
  Future<String> signingKey() async {
    final res = await _client.get(_resolve('/device/v1/signing-key')).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw ApiException(res.statusCode, 'SIGNING_KEY', 'Could not fetch the signing key');
    return res.body.trim();
  }

  /// .bin'i indirir ve SHA-256'yı doğrular. Aynı özetli dosya önbellekte
  /// varsa yeniden indirmez (hat başında aynı paket defalarca yüklenir).
  Future<File> download(FirmwareFile f, {void Function(double)? onProgress}) async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/firmware');
    await dir.create(recursive: true);
    final dest = File('${dir.path}/${f.sha256}.bin');
    if (await dest.exists() && await _sha256(dest) == f.sha256) {
      onProgress?.call(1);
      return dest;
    }

    final req = http.Request('GET', _resolve(f.url))..headers.addAll(_auth);
    final res = await _client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'DOWNLOAD', 'Download failed (${res.statusCode})');
    }
    final tmp = File('${dest.path}.part');
    final sink = tmp.openWrite();
    final total = res.contentLength ?? f.size;
    var got = 0;
    await for (final chunk in res.stream) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress?.call(got / total);
    }
    await sink.close();

    final hash = await _sha256(tmp);
    if (hash != f.sha256) {
      await tmp.delete();
      throw ApiException(0, 'HASH_MISMATCH', 'Downloaded file SHA-256 does not match.');
    }
    return tmp.rename(dest.path);
  }

  Future<Map<String, dynamic>> register({
    required String moduleId,
    required String publicKey,
    required String espFirmwareVersion,
    required String imageHash,
    required String deviceSerial,
    required String deviceModelId,
    String? hardwareRevision,
    String? gtin,
    String? lot,
    String? manufactureDate,
    String? reRegisterReason,
  }) async {
    final body = {
      'moduleId': moduleId,
      'publicKey': publicKey,
      'espFirmwareVersion': espFirmwareVersion,
      'imageHash': imageHash,
      'deviceSerial': deviceSerial,
      'deviceModelId': deviceModelId,
      if (hardwareRevision != null && hardwareRevision.isNotEmpty) 'hardwareRevision': hardwareRevision,
      if (gtin != null) 'gtin': gtin,
      if (lot != null) 'lot': lot,
      if (manufactureDate != null) 'manufactureDate': manufactureDate,
      'operator': AppConfig.operatorName,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      if (reRegisterReason != null) 'reRegister': {'reason': reRegisterReason},
    };
    return await _json(_client.post(_resolve('/factory/v1/registrations'),
        headers: {..._auth, 'Content-Type': 'application/json'}, body: jsonEncode(body))) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> selfTest(String moduleId, {required bool passed, Map<String, dynamic>? checks}) async {
    return await _json(_client.post(_resolve('/factory/v1/registrations/$moduleId/self-test'),
        headers: {..._auth, 'Content-Type': 'application/json'},
        body: jsonEncode({'passed': passed, if (checks != null) 'checks': checks}))) as Map<String, dynamic>;
  }

  static Future<String> _sha256(File f) async => (await sha256.bind(f.openRead()).first).toString();
}
