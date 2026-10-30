import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/gs1.dart';
import '../services/factory_api.dart';
import '../services/usb_flasher.dart';
import '../services/zm_ble.dart';

enum SetupStep { download, flash, ble, provision, register, selfTest, finalize }

enum StepStatus { pending, running, done, failed, skipped }

extension SetupStepLabel on SetupStep {
  String get label => switch (this) {
        SetupStep.download => 'Download and verify firmware',
        SetupStep.flash => 'Flash over USB',
        SetupStep.ble => 'Connect over Bluetooth',
        SetupStep.provision => 'Write serial number and model',
        SetupStep.register => 'Device Service registration',
        SetupStep.selfTest => 'Self-test',
        SetupStep.finalize => 'Finish production (switch to setup mode)',
      };
}

/// Bölüm 1 — kod yükleme ve fabrika kaydı (spec §6.1).
///
/// Etiket → model → paket seçilir; [run] kalan adımları sırayla yürütür.
/// Bir adım hata verirse akış orada durur, [run] aynı adımdan devam eder.
class SetupFlow extends ChangeNotifier {
  final FactoryApi api;
  final UsbFlasher usb = UsbFlasher();

  SetupFlow(this.api);

  // --- Girdiler ---
  Gs1Label? label;
  List<DeviceModel> models = [];
  DeviceModel? model;
  FirmwareList? firmware;
  FirmwarePackage? package;
  List<UsbDevice> usbDevices = [];
  UsbDevice? usbDevice;

  /// Firmware zaten yüklüyse (yeniden kayıt): USB adımları atlanır, cihaz BLE listesinden seçilir.
  bool skipFlash = false;
  String? manualModuleId;

  // --- Durum ---
  final status = {for (final s in SetupStep.values) s: StepStatus.pending};
  final details = <SetupStep, String>{};
  double progress = 0;
  final log = <String>[];
  String? error;

  /// Modülde kayıtlı, okutulan etiketten farklı seri no (onay bekliyor).
  String? serialConflict;
  bool _serialChangeApproved = false;

  /// Seri no değişikliği onaylandı: USB konsolundan eski cihaz bilgisini temizle,
  /// akışa devam et; sunucuda modül yeni seri noya yeniden bağlanır (gerekçe otomatik).
  Future<void> approveSerialChange() async {
    final old = serialConflict;
    if (old == null) return;
    final dev = usbDevice;
    if (dev == null) {
      error = 'Connect the module over USB to change its serial number.';
      notifyListeners();
      return;
    }
    busy = true;
    error = null;
    notifyListeners();
    try {
      final r = await usb.console(dev, 'serial clear', onLog: _log);
      if (r['ok'] != true) {
        throw Exception(r['error'] == 'PRODUCTION_DONE'
            ? 'the module is finalized (user mode). Flash it again — the app returns it to production mode — '
                'then change the serial number.'
            : 'the module refused (${r['error'] ?? r}). It may need firmware 0.1.3 or newer.');
      }
    } catch (e) {
      busy = false;
      error = 'Could not change the serial number over USB: ${e.toString().replaceFirst('Exception: ', '')}';
      notifyListeners();
      return;
    }
    _serialChangeApproved = true;
    serialConflict = null;
    busy = false;
    status[SetupStep.provision] = StepStatus.pending;
    await run(reRegisterReason: 'Serial number changed on re-flash: $old → ${label?.serial}');
  }

  /// Seri no değiştirilmesin: akış durur, doğru etiket okutulmalı.
  void declineSerialChange() {
    serialConflict = null;
    error = 'Stopped. Scan the label that belongs to this module, or use a different module.';
    notifyListeners();
  }

  /// Akışı durdurmayan uyarı (ör. öz testte ekran/anakart kontrolleri).
  String? warning;
  bool busy = false;
  bool loadingFirmware = false;

  File? _bin;
  FlashPlan? _plan;
  String? moduleId;
  ZmBle? _ble;
  Map<String, dynamic>? deviceInfo;
  Map<String, dynamic>? registration;
  Map<String, dynamic>? selfTestResult;

  /// Öz testte yalnız ekran/anakart kontrolleri kaldı: modül cihaza takılıp Bench'ten
  /// test edilecek. Finalize o zaman yapılır (sonrasında fabrika BLE servisi kapanır).
  bool awaitingDeviceTest = false;

  bool get finished =>
      status[SetupStep.finalize] == StepStatus.done ||
      (awaitingDeviceTest && status[SetupStep.finalize] == StepStatus.skipped);
  /// Start neden pasif: kullanıcıya gösterilecek eksikler.
  List<String> get missingRequirements => [
        if (label?.serial == null) 'Scan or enter the device label.',
        if (models.isEmpty)
          'No device models on the server. Add a model (name + GTIN) in the admin panel.'
        else if (model == null)
          'Select the device model.',
        if (!skipFlash && model != null && !loadingFirmware && package == null)
          'No published ESP firmware for this model. Upload and publish an ESP package in the admin panel.',
        if (!skipFlash && usbDevice == null) 'Connect the module with a USB OTG cable and tap refresh.',
        if (skipFlash && manualModuleId == null) 'Select the module over Bluetooth.',
      ];

  bool get canRun =>
      !busy &&
      label?.serial != null &&
      model != null &&
      (skipFlash ? (manualModuleId != null) : (package != null && usbDevice != null));

  // --- Sunucu durumu ---

  /// null: henüz sorulmadı; true/false: son denemenin sonucu.
  bool? serverOk;
  String? serverError;
  DateTime? serverCheckedAt;
  bool serverLoading = false;

  /// Model → sunucudaki en güncel ESP paketi (önerilen yoksa en yeni sürüm).
  final latestFirmware = <String, FirmwarePackage?>{};

  // --- Hazırlık ---

  /// Sunucuya bağlanır: modelleri ve her modelin güncel firmware sürümünü çeker.
  Future<void> loadModels() async {
    serverLoading = true;
    notifyListeners();
    try {
      if (!api.hasToken) throw ApiException(0, 'NO_TOKEN', 'No station token');
      models = await api.models();
      latestFirmware.clear();
      await Future.wait(models.map((m) async {
        final fw = await api.firmware(model: m.id);
        latestFirmware[m.id] = fw.recommended ?? fw.packages.firstOrNull;
      }));
      serverOk = true;
      serverError = null;
      if (label != null) _matchModel();
    } catch (e) {
      serverOk = false;
      serverError = e is ApiException && e.status == 401
          ? 'Tablet not recognized by the server; re-approval required.'
          : e.toString();
    }
    serverCheckedAt = DateTime.now();
    serverLoading = false;
    notifyListeners();
  }

  void setLabel(Gs1Label l) {
    label = l;
    _matchModel();
    notifyListeners();
  }

  void _matchModel() {
    final gtin = label?.gtin;
    if (gtin == null) return;
    final m = models.where((m) => m.gtin == gtin).firstOrNull;
    if (m != null && m.id != model?.id) selectModel(m);
  }

  Future<void> selectModel(DeviceModel m) async {
    model = m;
    package = null;
    firmware = null;
    loadingFirmware = true;
    notifyListeners();
    try {
      firmware = await api.firmware(model: m.id);
      package = firmware!.recommended ?? firmware!.packages.firstOrNull;
      error = firmware!.packages.isEmpty ? 'No published ESP package for ${m.name}.' : null;
    } catch (e) {
      error = 'Could not load firmware list: $e';
    }
    loadingFirmware = false;
    notifyListeners();
  }

  void selectPackage(FirmwarePackage p) {
    package = p;
    notifyListeners();
  }

  Future<void> refreshUsb() async {
    usbDevices = await usb.listDevices();
    if (usbDevice == null || !usbDevices.any((d) => d.deviceId == usbDevice!.deviceId)) {
      usbDevice = usbDevices.firstOrNull;
    }
    notifyListeners();
  }

  void selectUsb(UsbDevice d) {
    usbDevice = d;
    notifyListeners();
  }

  void setSkipFlash(bool v, {String? moduleId}) {
    skipFlash = v;
    manualModuleId = moduleId;
    notifyListeners();
  }

  /// Yeni cihaz: girdiler (model, paket, USB) korunur, cihaza özgü her şey sıfırlanır.
  bool _needsBle(SetupStep s) =>
      s == SetupStep.provision || s == SetupStep.selfTest || s == SetupStep.finalize;

  /// Akış yarıdan devam ediyorsa USB'deki kartın kimliği akıştaki kartla aynı mı?
  /// Değilse cihaza özgü durum (etiket dahil) temizlenir ve kullanıcı uyarılır —
  /// eski seri no yeni karta yazılmasın, eski kartın BLE bağlantısı kullanılmasın.
  Future<bool> _sameModuleStillConnected() async {
    final started = status[SetupStep.flash] == StepStatus.done;
    final dev = usbDevice;
    if (!started || skipFlash || dev == null || moduleId == null) return true;
    try {
      final info = await usb.console(dev, 'info', onLog: _log);
      final now = info['moduleId'] as String?;
      if (now == null || now == moduleId) return true;
      _log('A different module is connected ($now, was $moduleId).');
    } catch (_) {
      return true; // konsol yanıt vermezse BLE adımındaki kimlik kontrolü yine korur
    }
    await reset();
    error = 'A different module is connected. Scan the label of this device and press Start.';
    return false;
  }

  Future<void> reset() async {
    await _ble?.disconnect();
    _ble = null;
    label = null;
    moduleId = null;
    manualModuleId = null;
    skipFlash = false;
    deviceInfo = registration = selfTestResult = null;
    for (final s in SetupStep.values) {
      status[s] = StepStatus.pending;
    }
    details.clear();
    warning = null;
    awaitingDeviceTest = false;
    serialConflict = null;
    _serialChangeApproved = false;
    log.clear();
    error = null;
    progress = 0;
    notifyListeners();
  }

  // --- Yürütme ---

  Future<void> run({String? reRegisterReason}) async {
    if (!canRun) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      // Kaldığı yerden devam: kart değiştirildiyse eski kartın BLE bağlantısıyla sürmesin.
      if (!await _sameModuleStillConnected()) return;
      for (final step in SetupStep.values) {
        if (status[step] == StepStatus.done || status[step] == StepStatus.skipped) continue;
        if (step == SetupStep.finalize && awaitingDeviceTest) {
          status[step] = StepStatus.skipped;
          details[step] = 'After the device test in Bench';
          await _ble?.disconnect();
          _ble = null;
          continue;
        }
        if (skipFlash && (step == SetupStep.download || step == SetupStep.flash)) {
          status[step] = StepStatus.skipped;
          moduleId = manualModuleId;
          continue;
        }
        // BLE gerektiren adımlar: bağlantı kopmuşsa ya da yoksa önce yeniden bağlan.
        if (_needsBle(step) && _ble?.connected != true) {
          status[SetupStep.ble] = StepStatus.running;
          notifyListeners();
          await _runStep(SetupStep.ble, reRegisterReason);
          status[SetupStep.ble] = StepStatus.done;
        }
        status[step] = StepStatus.running;
        progress = 0;
        notifyListeners();
        await _runStep(step, reRegisterReason);
        status[step] = StepStatus.done;
        notifyListeners();
      }
    } catch (e) {
      final step = SetupStep.values.where((s) => status[s] == StepStatus.running).firstOrNull;
      if (step != null) status[step] = StepStatus.failed;
      error = e is ApiException ? _apiMessage(e) : e.toString().replaceFirst('Exception: ', '');
      _log('HATA: $error');
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Hata veren adımdan sonrasını değil, tüm cihaz akışını baştan başlatır.
  void restartDevice() {
    for (final s in SetupStep.values) {
      status[s] = StepStatus.pending;
    }
    details.clear();
    warning = null;
    awaitingDeviceTest = false;
    serialConflict = null;
    _serialChangeApproved = false;
    error = null;
    notifyListeners();
  }

  Future<void> _runStep(SetupStep step, String? reRegisterReason) async {
    switch (step) {
      case SetupStep.download:
        final file = package!.files.single;
        _bin = await api.download(file, onProgress: _setProgress);
        _plan = await usb.plan(_bin!);
        details[step] = '${package!.version} · ${(file.size / 1024).round()} KB'
            '${_plan!.appOnly ? '' : ' · merged image'}';

      case SetupStep.flash:
        final r = await usb.flash(usbDevice!, _plan!, onProgress: _setProgress, onLog: _log);
        moduleId = 'ZM${r.mac}';
        details[step] = r.productionReset ? '$moduleId · was finalized, back in production mode' : moduleId!;

      case SetupStep.ble:
        await _ble?.disconnect();
        _log('Searching for $moduleId...');
        final dev = await ZmBle.findByName(moduleId!);
        _ble = await ZmBle.connect(dev);
        deviceInfo = await _ble!.request('info');
        if (deviceInfo!['productionDone'] == true) {
          throw Exception('Production already finished on this module. To redo setup, run "production reset" on the USB console.');
        }
        if (deviceInfo!['moduleId'] != moduleId) {
          throw Exception('Wrong device: ${deviceInfo!['moduleId']} (expected $moduleId)');
        }
        details[step] = 'FW ${deviceInfo!['fwVersion']}';
        await _checkImageHash();

      case SetupStep.provision:
        final l = label!;
        // Aynı karta tekrar yükleme: modülde başka bir seri no kayıtlıysa sor (BLE ile
        // seri no değişmez, B-01; onaylanırsa USB konsolundan temizlenir).
        final existing = ((deviceInfo?['device'] as Map?)?['serial'] as String?) ?? '';
        if (existing.isNotEmpty && existing != l.serial && !_serialChangeApproved) {
          serialConflict = existing;
          throw Exception('This module is already registered as S/N $existing.');
        }
        final key = await api.signingKey();
        final payload = {
          'serial': l.serial,
          'modelId': model!.id,
          'gtin': l.gtin ?? '',
          'lot': l.lot ?? '',
          'mfgDate': l.manufactureDate ?? '',
          'deviceName': model!.name,
          'serverKey': key,
          'http': AppConfig.moduleHttpBase,
          'mqtt': AppConfig.moduleMqttUri,
        };
        try {
          deviceInfo = await _ble!.request('provision', payload);
        } on ZmBleError catch (e) {
          // Aynı seri no ama farklı alanlar (ör. sunucu adresi değişti, lot düzeltildi):
          // firmware BLE ile üzerine yazmaz (B-01). Tablet USB ile bağlıysa eski cihaz
          // bilgisini konsoldan temizleyip aynı seriyi yeniden yazar; sunucu kaydı değişmez.
          if (e.code != 'ALREADY_PROVISIONED' || existing != l.serial || usbDevice == null || skipFlash) rethrow;
          _log('Module already has S/N ${l.serial} with different settings — rewriting over USB...');
          final r = await usb.console(usbDevice!, 'serial clear', onLog: _log);
          if (r['ok'] != true) throw Exception('Could not clear the old settings over USB (${r['error'] ?? r}).');
          deviceInfo = await _ble!.request('provision', payload);
        }
        details[step] = '${l.serial} · ${model!.name}';

      case SetupStep.register:
        final info = deviceInfo!;
        final l = label!;
        registration = await api.register(
          moduleId: moduleId!,
          publicKey: info['publicKey'] as String,
          espFirmwareVersion: info['fwVersion'] as String,
          imageHash: info['imageHash'] as String,
          deviceSerial: l.serial!,
          deviceModelId: model!.id,
          gtin: l.gtin,
          lot: l.lot,
          manufactureDate: l.manufactureDate,
          reRegisterReason: reRegisterReason,
        );
        final b = registration!['binding'] as Map;
        final fp = registration!['firmwarePackage'] as Map?;
        details[step] = '${registration!['created'] == true ? 'New registration' : 'Already registered'} · epoch ${b['epoch']}'
            '${fp == null ? ' · image not matched to a package' : ''}';

      case SetupStep.selfTest:
        selfTestResult = await _ble!.request('selftest', const {}, const Duration(seconds: 30));
        final passed = selfTestResult!['passed'] == true;
        final checks = (selfTestResult!['checks'] as Map?)?.cast<String, dynamic>();
        await api.selfTest(moduleId!, passed: passed, checks: checks);
        final failed = _failedList(checks);
        // Modül tezgâhta tek başına yüklenir: ekran/anakart bağlı değilken UART kontrolleri
        // kalır. Sonuç sunucuya olduğu gibi kaydedilir, akış uyarıyla devam eder. Modülün
        // kendi kontrolleri (ble, serverKey, espNow) kalırsa gerçek arızadır, durulur.
        final moduleFailures = failed.where((c) => !_hostChecks.contains(c)).toList();
        if (moduleFailures.isNotEmpty) {
          details[step] = 'Failed: ${failed.join(', ')}';
          throw Exception('Self-test failed: ${moduleFailures.join(', ')}');
        }
        if (failed.isEmpty) {
          details[step] = 'Passed';
        } else {
          details[step] = 'Module OK · display/mainboard not tested (${failed.join(', ')})';
          awaitingDeviceTest = true;
          warning = 'Module is flashed and registered. You can now install it in the device. Power the device '
              'on, then go to Manufacturing → Bench, connect to $moduleId and run Self-test. '
              'Finalize production there once it passes.';
        }

      case SetupStep.finalize:
        // Modül "proddone" bayrağını yazıp yeniden başlar; bundan sonra fabrika
        // servisi yayın yapmaz (geri alma yalnız USB konsolundan).
        await _ble!.request('finalize');
        await _ble!.disconnect();
        _ble = null;
        details[step] = 'Restarted in setup mode';
    }
  }

  /// Modül `esp_partition_get_sha256` bildirir: dosyanın SHA-256'sı değil, elf2image'ın
  /// imaj sonuna eklediği özet (= SHA-256(dosya[:-32]) = dosyanın son 32 baytı).
  Future<void> _checkImageHash() async {
    if (skipFlash || _plan?.appOnly != true || _bin == null) return;
    final bytes = await _bin!.readAsBytes();
    if (bytes.length <= 32) return;
    final digest = bytes.sublist(bytes.length - 32);
    final expected = digest.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    if (sha256.convert(bytes.sublist(0, bytes.length - 32)).toString() != expected) {
      _log('Warning: no image digest at the end of the .bin, comparison skipped.');
      return;
    }
    if (deviceInfo!['imageHash'] != expected) {
      _log('Warning: module image digest does not match the flashed file (${deviceInfo!['imageHash']}).');
    } else {
      _log('Image digest verified.');
    }
  }

  /// Ekran/anakart bağlantısına bağlı kontroller — tek başına modülde kalmaları beklenir.
  static const _hostChecks = {'uartDwin', 'uartMb', 'bridge'};

  List<String> _failedList(Map<String, dynamic>? checks) =>
      (checks ?? {}).entries.where((e) => e.value == false).map((e) => e.key).toList();

  String _apiMessage(ApiException e) => switch (e.code) {
        'SERIAL_NOT_IN_CATALOG' => 'Serial number not in catalog (${label?.serial}). Add it in the admin panel.',
        'MODEL_MISMATCH' => 'Model mismatch: ${e.message}',
        'GS1_MISMATCH' => 'Label data does not match the catalog: ${e.message}',
        'MODULE_BOUND_TO_OTHER_SERIAL' ||
        'SERIAL_HAS_ACTIVE_MODULE' =>
          '${e.message} — if the module was replaced, use "Re-register" and enter a reason.',
        _ => e.toString(),
      };

  bool get needsReRegister =>
      error != null && status[SetupStep.register] == StepStatus.failed && error!.contains('Re-register');

  void _setProgress(double p) {
    progress = p;
    notifyListeners();
  }

  void _log(String line) {
    log.add(line);
    if (log.length > 500) log.removeAt(0);
    notifyListeners();
  }

  @override
  void dispose() {
    _ble?.disconnect();
    super.dispose();
  }
}
