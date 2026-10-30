import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_ble/universal_ble.dart';

import '../services/factory_api.dart';
import '../services/zm_ble.dart';

/// Köprüden geçen bir UART çerçevesi.
/// `direction`: 1 = DWIN→MB, 2 = MB→DWIN, 3 = ESP→DWIN, 4 = ESP→MB.
class UartPacket {
  final int direction;
  final int timestamp;
  final List<int> data;

  UartPacket({required this.direction, required this.timestamp, required this.data});

  factory UartPacket.fromEvent(Map<String, dynamic> e) => UartPacket(
        direction: e['dir'] as int,
        timestamp: (e['t'] as num).toInt(),
        data: hexToBytes(e['hex'] as String),
      );

  String get directionLabel => switch (direction) {
        1 => 'DWIN→MB',
        2 => 'MB→DWIN',
        3 => 'ESP→DWIN',
        4 => 'ESP→MB',
        _ => '???',
      };

  /// Oynatırken hedef: kaydedilen yönün karşı tarafı (ZemitsProviderAPP ile aynı).
  String get replayTarget => (direction == 1 || direction == 4) ? 'mb' : 'dwin';

  String get hex => bytesToHex(data, separator: ' ');

  Map<String, dynamic> toJson() => {'direction': direction, 'timestamp': timestamp, 'data': data};

  factory UartPacket.fromJson(Map<String, dynamic> j) => UartPacket(
        direction: j['direction'] as int? ?? 0,
        timestamp: j['timestamp'] as int? ?? 0,
        data: List<int>.from(j['data'] as List? ?? const []),
      );
}

/// Kaydedilmiş "fonksiyon" — ZemitsProviderAPP'in `saved_functions` biçimi.
class SavedFunction {
  final String name;
  final List<UartPacket> packets;
  final DateTime createdAt;

  SavedFunction({required this.name, required this.packets, required this.createdAt});

  Duration get duration => packets.length < 2
      ? Duration.zero
      : Duration(milliseconds: packets.last.timestamp - packets.first.timestamp);

  Map<String, dynamic> toJson() =>
      {'name': name, 'packets': packets.map((p) => p.toJson()).toList(), 'createdAt': createdAt.toIso8601String()};

  factory SavedFunction.fromJson(Map<String, dynamic> j) => SavedFunction(
        name: j['name'] as String,
        packets: (j['packets'] as List).map((p) => UartPacket.fromJson(p as Map<String, dynamic>)).toList(),
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.now(),
      );
}

List<int> hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'[\s:,]|0x', caseSensitive: false), '');
  if (clean.length.isOdd || !RegExp(r'^[0-9a-fA-F]*$').hasMatch(clean)) {
    throw const FormatException('Invalid hex');
  }
  return [for (var i = 0; i < clean.length; i += 2) int.parse(clean.substring(i, i + 2), radix: 16)];
}

String bytesToHex(List<int> bytes, {String separator = ''}) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(separator);

/// Bölüm 2 — BLE ile cihaza bağlanıp verileri görme ve fonksiyon taklidi.
class DeviceSession extends ChangeNotifier {
  /// Öz test sonucunu sunucuya kaydetmek için.
  final FactoryApi? api;
  DeviceSession([this.api]);

  static const _kFunctions = 'saved_functions';
  static const _maxTraffic = 1000;

  ZmBle? _ble;
  StreamSubscription<Map<String, dynamic>>? _evSub;
  Timer? _poll;

  bool connecting = false;
  String? error;
  Map<String, dynamic>? info;
  Map<String, dynamic>? status;
  DateTime? statusAt;

  /// Canlı trafik (sniff açıkken).
  final traffic = <UartPacket>[];
  bool sniffing = false;

  /// Kayıt sürerken toplanan paketler; null = kayıt yok.
  List<UartPacket>? recording;
  List<SavedFunction> functions = [];
  String? playing;
  double playProgress = 0;
  bool _stopPlay = false;

  bool get connected => _ble?.connected == true;
  String? get deviceName => _ble?.name;

  // --- Bağlantı ---

  Future<void> connect(BleDevice device) async {
    await disconnect();
    connecting = true;
    error = null;
    notifyListeners();
    try {
      _ble = await ZmBle.connect(device);
      _evSub = _ble!.events.listen(_onEvent);
      info = await _ble!.request('info');
      await refreshStatus();
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => refreshStatus(quiet: true));
    } catch (e) {
      error = 'Connection failed: $e';
      await _ble?.disconnect();
      _ble = null;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _poll?.cancel();
    await _evSub?.cancel();
    await _ble?.disconnect();
    _ble = null;
    info = status = null;
    lastSelfTestPassed = null;
    sniffing = false;
    recording = null;
    traffic.clear();
    notifyListeners();
  }

  void _onEvent(Map<String, dynamic> e) {
    switch (e['ev']) {
      case 'disconnected':
        _poll?.cancel();
        sniffing = false;
        recording = null;
        error = 'Connection lost.';
      case 'uart':
        final p = UartPacket.fromEvent(e);
        traffic.add(p);
        if (traffic.length > _maxTraffic) traffic.removeRange(0, traffic.length - _maxTraffic);
        recording?.add(p);
    }
    notifyListeners();
  }

  Future<void> refreshStatus({bool quiet = false}) async {
    if (!connected) return;
    try {
      status = await _ble!.request('status');
      statusAt = DateTime.now();
      if (!quiet) error = null;
    } catch (e) {
      if (!quiet) error = 'Could not read status: $e';
    }
    notifyListeners();
  }

  Future<void> refreshInfo() async {
    info = await _ble!.request('info');
    notifyListeners();
  }

  // --- Komutlar ---

  Future<String?> _guard(Future<void> Function() fn) async {
    try {
      await fn();
      error = null;
      return null;
    } catch (e) {
      error = e.toString();
      return error;
    } finally {
      notifyListeners();
    }
  }

  Future<String?> setWifi(String ssid, String pass) =>
      _guard(() => _ble!.request('wifi', {'ssid': ssid, 'pass': pass}));

  /// Son öz testin sonucu (Finalize yalnız geçtiyse açılır).
  bool? lastSelfTestPassed;

  /// Cihaza takılmış modülde öz test; sonuç sunucuya da kaydedilir.
  Future<String?> selfTest(void Function(Map<String, dynamic>) onResult) => _guard(() async {
        final r = await _ble!.request('selftest', const {}, const Duration(seconds: 30));
        lastSelfTestPassed = r['passed'] == true;
        final moduleId = info?['moduleId'] as String?;
        if (api != null && moduleId != null) {
          await api!.selfTest(moduleId,
              passed: lastSelfTestPassed!, checks: (r['checks'] as Map?)?.cast<String, dynamic>());
        }
        onResult(r);
      });

  /// Üretimi tamamla: modül kullanıcı moduna geçip yeniden başlar; fabrika BLE servisi kapanır.
  Future<String?> finalize() => _guard(() async {
        await _ble!.request('finalize');
        await disconnect();
      });

  Future<String?> reboot() => _guard(() => _ble!.request('reboot'));

  Future<String?> setSniff(bool on) => _guard(() async {
        await _ble!.request('sniff', {'on': on});
        sniffing = on;
      });

  Future<String?> inject(String target, List<int> data) =>
      _guard(() => _ble!.request('inject', {'target': target, 'hex': bytesToHex(data)}));

  void clearTraffic() {
    traffic.clear();
    notifyListeners();
  }

  // --- Fonksiyon taklidi: kayıt / oynatma ---

  Future<String?> startRecording() async {
    if (!sniffing) {
      final err = await setSniff(true);
      if (err != null) return err;
    }
    recording = [];
    notifyListeners();
    return null;
  }

  /// Kaydı bitirir; [name] null ise atılır.
  Future<void> stopRecording(String? name) async {
    final packets = recording;
    recording = null;
    if (name != null && packets != null && packets.isNotEmpty) {
      functions.insert(0, SavedFunction(name: name, packets: packets, createdAt: DateTime.now()));
      await _saveFunctions();
    }
    notifyListeners();
  }

  Future<void> play(SavedFunction f) async {
    if (playing != null) return;
    playing = f.name;
    playProgress = 0;
    _stopPlay = false;
    notifyListeners();
    try {
      int? prev;
      for (var i = 0; i < f.packets.length && !_stopPlay; i++) {
        final p = f.packets[i];
        if (prev != null && p.timestamp > prev) {
          // Paketler arası süre korunur; uzun boşluklar 10 sn ile sınırlı.
          await Future<void>.delayed(Duration(milliseconds: (p.timestamp - prev).clamp(0, 10000)));
        }
        prev = p.timestamp;
        await _ble!.request('inject', {'target': p.replayTarget, 'hex': bytesToHex(p.data)});
        playProgress = (i + 1) / f.packets.length;
        notifyListeners();
      }
    } catch (e) {
      error = 'Replay stopped: $e';
    } finally {
      playing = null;
      notifyListeners();
    }
  }

  void stopPlay() => _stopPlay = true;

  Future<void> deleteFunction(SavedFunction f) async {
    functions.remove(f);
    await _saveFunctions();
    notifyListeners();
  }

  Future<void> loadFunctions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kFunctions);
      if (raw != null) {
        functions = (jsonDecode(raw) as List).map((j) => SavedFunction.fromJson(j as Map<String, dynamic>)).toList();
      }
    } catch (_) {
      functions = [];
    }
    notifyListeners();
  }

  /// ZemitsProviderAPP'ten dışa aktarılmış JSON'u ekler (tek fonksiyon ya da liste).
  Future<int> importFunctions(String json) async {
    final decoded = jsonDecode(json);
    final list = decoded is List ? decoded : [decoded];
    final added = list.map((j) => SavedFunction.fromJson(j as Map<String, dynamic>)).toList();
    functions.insertAll(0, added);
    await _saveFunctions();
    notifyListeners();
    return added.length;
  }

  String exportFunctions() => const JsonEncoder.withIndent('  ').convert(functions.map((f) => f.toJson()).toList());

  Future<void> _saveFunctions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFunctions, jsonEncode(functions.map((f) => f.toJson()).toList()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _evSub?.cancel();
    _ble?.disconnect();
    super.dispose();
  }
}
