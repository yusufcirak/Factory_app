import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

/// Zemits Provisioning Service istemcisi (docs/factory_provisioning.md, "BLE GATT").
///
/// Tek RX/TX karakteristiği üzerinden `\n` ile biten JSON satırları:
/// istek `{"id","op",...}` → yanıt `{"id","ok",...}`; `id`'siz `{"ev":...}` olaylar.
class ZmBle {
  static const service = '5a4d0001-7a65-6d69-7473-70726f763031';
  static const rx = '5a4d0002-7a65-6d69-7473-70726f763031';
  static const tx = '5a4d0003-7a65-6d69-7473-70726f763031';

  final String deviceId;
  final String name;
  int _mtu = 23;
  int _nextId = 1;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _rxBuf = BytesBuilder();
  StreamSubscription<Uint8List>? _valueSub;
  StreamSubscription<bool>? _connSub;
  bool _connected = false;

  ZmBle._(this.deviceId, this.name);

  bool get connected => _connected;

  /// `{"ev": ...}` olayları ve bağlantı kopuşu (`{"ev":"disconnected"}`).
  Stream<Map<String, dynamic>> get events => _events.stream;

  // --- Tarama ---------------------------------------------------------------

  static final _scanResults = StreamController<BleDevice>.broadcast();
  static bool _scanHooked = false;

  static Future<void> ensureReady() async {
    if (!await ensureBluetoothOn()) {
      throw Exception('Bluetooth is off. Turn on Bluetooth on this phone and tap Continue.');
    }
  }

  /// İzinleri ister; Bluetooth kapalıysa Android'in "Bluetooth'u aç" penceresini gösterir.
  /// Sonunda açık mı döner.
  static Future<bool> ensureBluetoothOn() async {
    await UniversalBle.requestPermissions();
    if (await UniversalBle.getBluetoothAvailabilityState() == AvailabilityState.poweredOn) return true;
    try {
      await UniversalBle.enableBluetooth();
    } catch (_) {}
    // Açılması bir-iki saniye sürer.
    for (var i = 0; i < 10; i++) {
      if (await UniversalBle.getBluetoothAvailabilityState() == AvailabilityState.poweredOn) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  /// [services] UUID'lerinden birini yayınlayan cihazları bildirir (varsayılan:
  /// fabrika servisi). Akış dinlenmeyi bırakınca tarama durur.
  static Stream<BleDevice> scan({List<String> services = const [service]}) {
    if (!_scanHooked) {
      UniversalBle.onScanResult = _scanResults.add;
      _scanHooked = true;
    }
    late StreamController<BleDevice> out;
    StreamSubscription<BleDevice>? sub;
    out = StreamController<BleDevice>(
      onListen: () async {
        sub = _scanResults.stream.listen(out.add);
        try {
          await ensureReady();
          await UniversalBle.startScan(scanFilter: ScanFilter(withServices: services));
        } catch (e) {
          out.addError(e);
        }
      },
      onCancel: () async {
        await sub?.cancel();
        await UniversalBle.stopScan().catchError((_) {});
      },
    );
    return out.stream;
  }

  /// Adı tam olarak [name] olan cihazı [timeout] içinde bulur.
  ///
  /// Fabrikada cihaz USB'den okunan MAC'e göre seçilir; sinyal gücüne
  /// göre eşleştirme yapılmaz (spec B-02).
  static Future<BleDevice> findByName(String name,
      {Duration timeout = const Duration(seconds: 45), List<String> services = const [service]}) {
    return scan(services: services).firstWhere((d) => (d.name ?? d.rawName) == name).timeout(
          timeout,
          onTimeout: () => throw TimeoutException('$name not found over BLE. Is the module powered on?'),
        );
  }

  // --- Bağlantı ---------------------------------------------------------------

  static Future<ZmBle> connect(BleDevice device) async {
    final c = ZmBle._(device.deviceId, device.name ?? device.rawName ?? device.deviceId);
    await UniversalBle.connect(device.deviceId, timeout: const Duration(seconds: 15));
    c._connected = true;
    c._connSub = UniversalBle.connectionStream(device.deviceId).listen((up) {
      if (!up) c._onDisconnected();
    });
    try {
      await UniversalBle.discoverServices(device.deviceId);
      try {
        c._mtu = await UniversalBle.requestMtu(device.deviceId, 247);
      } catch (_) {
        c._mtu = 23; // parçalama sayesinde 23'te de çalışır
      }
      c._valueSub = UniversalBle.characteristicValueStream(device.deviceId, tx).listen(c._onChunk);
      await UniversalBle.subscribeNotifications(device.deviceId, service, tx);
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
    _valueSub?.cancel();
    _connSub?.cancel();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(Exception('BLE connection lost.'));
    }
    _pending.clear();
    _events.add({'ev': 'disconnected'});
  }

  // --- Mesajlaşma ---------------------------------------------------------------

  /// Modül satırları sırayla işler ve bir yanıt bitmeden yenisini almaz;
  /// durum yoklaması ile oynatma gibi eşzamanlı çağrılar bu zincirle sıraya girer.
  Future<void> _lane = Future.value();

  /// İsteği gönderir, yanıtı bekler. `ok:false` yanıtı [ZmBleError] fırlatır.
  Future<Map<String, dynamic>> request(String op,
      [Map<String, dynamic> args = const {}, Duration timeout = const Duration(seconds: 10)]) {
    final result = _lane.then((_) => _send(op, args, timeout));
    _lane = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Map<String, dynamic>> _send(String op, Map<String, dynamic> args, Duration timeout) async {
    if (!_connected) throw Exception('BLE not connected.');
    final id = _nextId++;
    final done = Completer<Map<String, dynamic>>();
    _pending[id] = done;
    final line = utf8.encode('${jsonEncode({'id': id, 'op': op, ...args})}\n');
    final chunk = (_mtu - 3).clamp(20, 512);
    try {
      for (var i = 0; i < line.length; i += chunk) {
        final end = (i + chunk).clamp(0, line.length);
        await UniversalBle.write(deviceId, service, rx, Uint8List.fromList(line.sublist(i, end)));
      }
      final res = await done.future.timeout(timeout,
          onTimeout: () => throw TimeoutException('Module did not answer "$op".'));
      if (res['ok'] != true) {
        throw ZmBleError((res['error'] as String?) ?? 'INTERNAL', (res['message'] as String?) ?? '');
      }
      return res;
    } finally {
      _pending.remove(id);
    }
  }

  void _onChunk(Uint8List data) {
    for (final b in data) {
      if (b == 0x0A) {
        final bytes = _rxBuf.takeBytes();
        if (bytes.isEmpty) continue;
        _dispatch(bytes);
      } else {
        _rxBuf.addByte(b);
        if (_rxBuf.length > 8192) _rxBuf.clear(); // bozuk akış: yeniden senkronlan
      }
    }
  }

  void _dispatch(List<int> bytes) {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = msg['id'];
    if (id is int && _pending.containsKey(id)) {
      _pending[id]!.complete(msg);
    } else if (msg.containsKey('ev')) {
      _events.add(msg);
    }
  }
}

class ZmBleError implements Exception {
  final String code;
  final String message;
  ZmBleError(this.code, this.message);
  @override
  String toString() => message.isEmpty ? code : '$code: $message';
}
