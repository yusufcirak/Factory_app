import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class UsbDevice {
  final int deviceId;
  final int vendorId;
  final int productId;
  final String? productName;
  final String driverName;
  UsbDevice.fromMap(Map m)
      : deviceId = m['deviceId'] as int,
        vendorId = m['vendorId'] as int,
        productId = m['productId'] as int,
        productName = m['productName'] as String?,
        driverName = m['driverName'] as String;

  String get label => '${productName ?? driverName} (${vendorId.toRadixString(16)}:${productId.toRadixString(16)})';
}

/// Yükleme sonucu: MAC + yüklemeden sonra seri konsoldan okunan `info` (okunabildiyse).
class FlashResult {
  final String mac;
  final Map<String, dynamic>? consoleInfo;

  /// Kart daha önce finalize edilmişti; üretim moduna döndürüldü.
  final bool productionReset;
  FlashResult({required this.mac, this.consoleInfo, required this.productionReset});
}

class FlashImage {
  final int address;
  final File file;
  FlashImage(this.address, this.file);
}

/// Yazma planı: hangi bölge hangi adrese.
class FlashPlan {
  final List<FlashImage> images;

  /// Yalnız uygulama imajıysa true — modülün bildireceği imageHash paketle eşleşir.
  final bool appOnly;
  FlashPlan(this.images, {required this.appOnly});
}

/// USB OTG üzerinden ESP32 ROM yükleyicisi (Kotlin: EspLoader, Sketch32'den).
class UsbFlasher {
  static const _method = MethodChannel('zemits/usb');
  static const _events = EventChannel('zemits/usb_events');

  static const _sector = 0x1000;
  static const _otadata = 0xE000;
  static const _appOffset = 0x10000;

  Future<List<UsbDevice>> listDevices() async {
    final list = await _method.invokeMethod<List>('listDevices') ?? const [];
    return list.map((m) => UsbDevice.fromMap(m as Map)).toList();
  }

  /// Yazar; MAC'i (12 hex, büyük harf) ve konsol kontrolünün sonucunu döner.
  Future<FlashResult> flash(
    UsbDevice device,
    FlashPlan plan, {
    void Function(double)? onProgress,
    void Function(String)? onLog,
  }) async {
    final sub = _events.receiveBroadcastStream().listen((e) {
      final m = e as Map;
      switch (m['type']) {
        case 'progress':
          onProgress?.call((m['value'] as num).toDouble());
        case 'log':
          onLog?.call(m['line'] as String);
      }
    });
    try {
      final r = await _method.invokeMethod<Map>('flash', {
        'deviceId': device.deviceId,
        'images': [
          for (final i in plan.images) {'address': i.address, 'path': i.file.path},
        ],
      });
      final info = r!['info'] as String?;
      return FlashResult(
        mac: r['mac'] as String,
        consoleInfo: info == null ? null : jsonDecode(info) as Map<String, dynamic>,
        productionReset: r['productionReset'] == true,
      );
    } on PlatformException catch (e) {
      throw Exception(e.message ?? e.code);
    } finally {
      await sub.cancel();
    }
  }

  /// Modülün USB seri konsoluna tek komut gönderir; '@' JSON yanıtını döner.
  Future<Map<String, dynamic>> console(UsbDevice device, String command, {void Function(String)? onLog}) async {
    final sub = _events.receiveBroadcastStream().listen((e) {
      final m = e as Map;
      if (m['type'] == 'log') onLog?.call(m['line'] as String);
    });
    try {
      final r = await _method.invokeMethod<String>('console', {'deviceId': device.deviceId, 'command': command});
      return jsonDecode(r!) as Map<String, dynamic>;
    } on PlatformException catch (e) {
      throw Exception(e.message ?? e.code);
    } finally {
      await sub.cancel();
    }
  }

  /// Backend'den gelen tek .bin'den yazma planı çıkarır (bkz. docs/factory_provisioning.md).
  ///
  /// - İlk bayt 0xE9: yalnız uygulama → paketlenmiş bootloader/partitions/boot_app0 ile.
  /// - 0x1000'de 0xE9: birleşik imaj → tamamen 0xFF olan 4 KB sektörler atlanarak
  ///   bölgelere ayrılır. Böylece NVS (0x9000) silinmez: modülün kimlik anahtarı
  ///   yeniden yüklemede korunur. otadata her zaman yazılır ki yonga app0'dan açılsın.
  Future<FlashPlan> plan(File bin) async {
    final data = await bin.readAsBytes();
    if (data.isNotEmpty && data[0] == 0xE9) {
      final dir = await _assetDir();
      return FlashPlan([
        FlashImage(0x1000, File('${dir.path}/bootloader.bin')),
        FlashImage(0x8000, File('${dir.path}/partitions.bin')),
        FlashImage(_otadata, File('${dir.path}/boot_app0.bin')),
        FlashImage(_appOffset, bin),
      ], appOnly: true);
    }
    if (data.length > 0x1000 && data[0x1000] == 0xE9) {
      return FlashPlan(await _splitMerged(data, bin), appOnly: false);
    }
    throw Exception('Unrecognized image: expected an ESP32 app (.bin) or merged image (.merged.bin).');
  }

  Future<List<FlashImage>> _splitMerged(Uint8List data, File source) async {
    bool blank(int start) {
      final end = (start + _sector).clamp(0, data.length);
      for (var i = start; i < end; i++) {
        if (data[i] != 0xFF) return false;
      }
      return true;
    }

    final regions = <(int, int)>[];
    int? start;
    for (var off = 0; off < data.length; off += _sector) {
      final keep = !blank(off) || (off >= _otadata && off < _appOffset);
      if (keep) {
        start ??= off;
      } else if (start != null) {
        regions.add((start, off));
        start = null;
      }
    }
    if (start != null) regions.add((start, data.length));

    final dir = Directory('${(await getTemporaryDirectory()).path}/flash_regions');
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);
    final out = <FlashImage>[];
    for (final (s, e) in regions) {
      final f = File('${dir.path}/0x${s.toRadixString(16)}.bin');
      await f.writeAsBytes(Uint8List.sublistView(data, s, e));
      out.add(FlashImage(s, f));
    }
    return out;
  }

  /// Paketlenmiş bootloader/bölüm tablosu Kotlin'in okuyabileceği dosyalara açılır.
  Future<Directory> _assetDir() async {
    final dir = Directory('${(await getApplicationSupportDirectory()).path}/esp32');
    await dir.create(recursive: true);
    for (final name in ['bootloader.bin', 'partitions.bin', 'boot_app0.bin']) {
      final bytes = await rootBundle.load('assets/esp32/$name');
      await File('${dir.path}/$name').writeAsBytes(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
    }
    return dir;
  }
}
