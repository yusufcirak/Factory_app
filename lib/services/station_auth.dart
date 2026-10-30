import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../config.dart';
import 'zemits_http.dart';

enum StationState { loading, ready, enrolling, rejected, expired, error }

/// İstasyon kimliği: tablet jetonu kendiliğinden alır (device-service/docs/FACTORY_API.md,
/// "İstasyon kaydı"). Jeton yoksa istek açılır, ekranda kod gösterilir, personel panelden
/// onaylayınca jeton bir kez gelir ve güvenli depoya yazılır.
class StationAuth extends ChangeNotifier {
  static const _kToken = 'station_token';
  static const _kStationId = 'station_id';
  static const _kEnrollId = 'enroll_id';
  static const _kEnrollSecret = 'enroll_secret';
  static const _kEnrollCode = 'enroll_code';
  static const _kEnrollExpires = 'enroll_expires';

  final _store = const FlutterSecureStorage();
  final _client = zemitsHttpClient();
  Timer? _poll;

  StationState state = StationState.loading;
  String? token;
  String? stationId;
  String? code;
  DateTime? expiresAt;
  String? error;
  String? deviceName;

  bool get ready => state == StationState.ready;

  Future<void> init() async {
    // Derlemede gömülü jeton (geliştirme/acil durum) her şeyden önce gelir.
    if (AppConfig.stationToken.isNotEmpty) {
      token = AppConfig.stationToken;
      return _set(StationState.ready);
    }
    token = await _store.read(key: _kToken);
    stationId = await _store.read(key: _kStationId);
    if (token != null) return _set(StationState.ready);

    // Yarım kalmış istek varsa (uygulama kapanıp açıldı) aynı kodla sürdür.
    final id = await _store.read(key: _kEnrollId);
    final exp = DateTime.tryParse(await _store.read(key: _kEnrollExpires) ?? '');
    if (id != null && exp != null && exp.isAfter(DateTime.now())) {
      code = await _store.read(key: _kEnrollCode);
      expiresAt = exp;
      _set(StationState.enrolling);
      _startPolling(id, (await _store.read(key: _kEnrollSecret))!, 5);
      return;
    }
    await startEnrollment();
  }

  /// Yeni kayıt isteği açar.
  Future<void> startEnrollment() async {
    _poll?.cancel();
    error = null;
    code = null;
    _set(StationState.loading);
    try {
      deviceName ??= await _deviceName();
      final res = await _client
          .post(_uri('/factory/v1/enrollments'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'deviceName': deviceName, 'deviceInfo': await _deviceInfo()}))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 429) {
        throw Exception('Too many pending requests on the server. Try again in a few minutes.');
      }
      if (res.statusCode == 404) {
        throw Exception('The server does not support tablet enrollment yet (update not deployed).');
      }
      final j = _decode(res);
      if (res.statusCode != 201) throw Exception(_err(j, res.statusCode));

      final id = j['enrollmentId'] as String, secret = j['secret'] as String;
      code = j['code'] as String;
      expiresAt = DateTime.tryParse(j['expiresAt'] as String? ?? '');
      // Uygulama kapanırsa aynı istekle devam edebilmek için; secret loglanmaz.
      await _store.write(key: _kEnrollId, value: id);
      await _store.write(key: _kEnrollSecret, value: secret);
      await _store.write(key: _kEnrollCode, value: code);
      await _store.write(key: _kEnrollExpires, value: expiresAt?.toIso8601String());
      _set(StationState.enrolling);
      _startPolling(id, secret, (j['pollIntervalS'] as num?)?.toInt() ?? 5);
    } on SocketException catch (e) {
      _fail('Cannot reach the server: ${e.message}');
    } catch (e) {
      _fail(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _startPolling(String id, String secret, int intervalS) {
    _poll?.cancel();
    _poll = Timer.periodic(Duration(seconds: intervalS.clamp(2, 60)), (_) => _check(id, secret));
    _check(id, secret);
  }

  bool _checking = false;

  Future<void> _check(String id, String secret) async {
    if (_checking) return;
    _checking = true;
    try {
      final res = await _client
          .get(_uri('/factory/v1/enrollments/$id'), headers: {'Authorization': 'Bearer $secret'})
          .timeout(const Duration(seconds: 15));
      final j = _decode(res);
      if (res.statusCode == 404) {
        await _clearEnrollment();
        return startEnrollment();
      }
      if (res.statusCode != 200) return; // geçici hata: sonraki turda tekrar
      switch (j['status']) {
        case 'approved':
          // Jeton YALNIZ BİR KEZ gelir: önce kalıcı kaydet, sonra ekranı değiştir.
          final t = j['token'] as String;
          await _store.write(key: _kToken, value: t);
          await _store.write(key: _kStationId, value: j['stationId'] as String?);
          token = t;
          stationId = j['stationId'] as String?;
          _poll?.cancel();
          await _clearEnrollment();
          _set(StationState.ready);
        case 'rejected':
          _poll?.cancel();
          await _clearEnrollment();
          _set(StationState.rejected);
        case 'expired':
        case 'delivered': // jeton daha önce verilmiş ama bizde yok: kaybolmuş
          _poll?.cancel();
          await _clearEnrollment();
          _set(StationState.expired);
      }
    } catch (_) {
      // ağ kesintisi: bir sonraki turda tekrar dener
    } finally {
      _checking = false;
    }
  }

  /// Herhangi bir uç `401 STATION_UNAUTHORIZED` döndü: jeton geçersiz, kayda dön.
  Future<void> invalidate() async {
    if (AppConfig.stationToken.isNotEmpty) {
      return _fail('The built-in station token is not valid on the server.');
    }
    token = null;
    stationId = null;
    await _store.delete(key: _kToken);
    await _store.delete(key: _kStationId);
    await startEnrollment();
  }

  Future<void> _clearEnrollment() async {
    for (final k in [_kEnrollId, _kEnrollSecret, _kEnrollCode, _kEnrollExpires]) {
      await _store.delete(key: k);
    }
  }

  Future<String> _deviceName() async {
    try {
      final a = await DeviceInfoPlugin().androidInfo;
      return '${a.manufacturer} ${a.model}'.trim();
    } catch (_) {
      return 'Zemits Control tablet';
    }
  }

  Future<Map<String, Object>> _deviceInfo() async {
    final info = <String, Object>{};
    try {
      info['appVersion'] = (await PackageInfo.fromPlatform()).version;
      final a = await DeviceInfoPlugin().androidInfo;
      info['manufacturer'] = a.manufacturer;
      info['model'] = a.model;
      info['androidSdk'] = a.version.sdkInt;
    } catch (_) {}
    return info;
  }

  Uri _uri(String path) => Uri.parse(AppConfig.apiBaseUrl).replace(path: path);

  Map<String, dynamic> _decode(http.Response r) {
    try {
      return r.body.isEmpty ? {} : jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  String _err(Map<String, dynamic> j, int status) =>
      ((j['error'] as Map?)?['message'] as String?) ?? 'Server error ($status)';

  void _fail(String msg) {
    error = msg;
    _set(StationState.error);
  }

  void _set(StationState s) {
    state = s;
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}
