import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/gs1.dart';
import 'package:universal_ble/universal_ble.dart';

import '../services/factory_api.dart';
import '../services/zm_ble.dart';
import '../services/zm_customer_ble.dart';
import '../state/customer_session.dart';
import '../state/provider_devices.dart';
import 'ble_picker.dart';
import 'label_scan_page.dart';
import 'provider_device_detail_page.dart';

/// Provider kurulum sihirbazı (customer_ble_setup.md + sağlayıcıya cihaz ekleme):
///   1. Cihaz etiketi okutulur (seri no).
///   2. Bluetooth ile bağlanılır; ESP32'nin bildirdiği seri no etiketle aynı olmalı
///      (yan yana duran başka bir sağlayıcının cihazı eklenmesin).
///   3. Oturum sunucunun verdiği tek kullanımlık kodla açılır; modülün imzası sunucuya
///      yakınlık kanıtı olarak gider ve cihaz seçili sağlayıcıya eklenir.
///   4. Wi-Fi girilir; cihaz Wi-Fi + sunucuya bağlanınca Bluetooth kapanır ve
///      sunucudan gelen cihaz sayfası açılır.
class ProviderSetupWizard extends StatefulWidget {
  /// Verilirse "Wi-Fi'yi değiştir" modu: cihaz zaten bu sağlayıcıda; etiket ve ekleme
  /// adımları atlanır, ESP32'nin seri nosu bununla eşleşmeli.
  final String? serial;
  const ProviderSetupWizard({super.key, this.serial});

  bool get reconfigure => serial != null;

  @override
  State<ProviderSetupWizard> createState() => _ProviderSetupWizardState();
}

enum _Step { label, connect, wifi, joining, failed }

class _ProviderSetupWizardState extends State<ProviderSetupWizard> {
  final _ssid = TextEditingController();
  final _pass = TextEditingController();
  bool _obscure = true;
  _Step _step = _Step.label;
  String? _serial;
  String? _phase;
  String? _failure;
  bool _claimed = false;

  /// Bu denemede Wi-Fi bağlandı (modül ağı kaydetti); sunucu bağlantısı ayrıca beklenir.
  bool _wifiOk = false;

  /// Wi-Fi tamam ama sunucuya süre içinde ulaşılamadı (ör. DNS / MQTT portu kapalı).
  bool _serverSlow = false;

  /// connectivity_rules.md §5 (fw 0.1.8+): ağa katılınca cihaz BLE'yi kapatıp buluta
  /// bağlanır; sonuç sunucudan izlenir. Wi-Fi denemesinin başladığı an — "çevrimiçi"
  /// bilgisi bundan eski bir bağlantıya ait olmasın.
  DateTime? _attemptStartedAt;
  Timer? _serverPoll;
  bool _doneCalled = false;

  /// Wi-Fi değiştirme: sunucunun cihaza gönderdiği `ble_setup` isteği (§16). Null: cihaz
  /// çevrimdışıydı ya da sunucu bu özelliği vermiyor — doğrudan kurulum modunda aranır.
  String? _requestId;
  Timer? _timeout;
  late final CustomerSession _s = context.read<CustomerSession>();
  late final ProviderDevices _providers = context.read<ProviderDevices>();

  /// Modül ağı ~3–15 sn dener; sunucuya bağlanması da birkaç saniye sürer.
  static const _joinTimeout = Duration(seconds: 60);

  static const _wifiErrors = {
    'wrong_password': 'Wrong Wi-Fi password.',
    'network_not_found': 'Wi-Fi network not found. Check the network name and that the device is in range.',
    'failed': 'Could not connect to the Wi-Fi network.',
  };

  @override
  void initState() {
    super.initState();
    _s.addListener(_onSession);
    if (widget.reconfigure) {
      _serial = widget.serial;
      _claimed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _connect());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scanLabel());
    }
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _serverPoll?.cancel();
    _s.removeListener(_onSession);
    _s.disconnect();
    _ssid.dispose();
    _pass.dispose();
    super.dispose();
  }

  // --- 1. Etiket ---

  Future<void> _scanLabel() async {
    setState(() {
      _step = _Step.label;
      _failure = null;
    });
    final label = await Navigator.of(context).push<Gs1Label>(MaterialPageRoute(builder: (_) => const LabelScanPage()));
    if (!mounted) return;
    if (label?.serial == null) return; // kullanıcı vazgeçti; ekranda "Scan label" düğmesi kalır
    setState(() => _serial = label!.serial);
    await _connect();
  }

  // --- 2–3. Bluetooth, eşleşme, sağlayıcıya ekleme ---

  Future<void> _connect() async {
    final providerId = _providers.providerId;
    if (providerId == null) return _fail('Select a provider first.');
    setState(() {
      _step = _Step.connect;
      _phase = widget.reconfigure ? 'Looking for the device...' : 'Requesting a one-time code from the server...';
    });
    try {
      if (widget.reconfigure) {
        // Cihaz zaten sağlayıcıda. Wi-Fi'ye bağlıyken BLE kapalıdır (K2): önce sunucudan
        // BLE'yi açtır, sonra doğru cihaza bağlan (seri eşleşmesi) ve Wi-Fi'ye geç.
        if (!await _openRemoteSetup(providerId)) return;
        final d = await _findDevice();
        if (!mounted) return;
        if (d == null) return _fail(_notAdvertising);
        await _s.connect(d, expectedSerial: _serial);
        if (!mounted) return;
        if (!_s.connected) return _fail(_s.error ?? 'Could not connect to the device.');
        setState(() => _step = _Step.wifi);
        _s.scanNetworks();
        return;
      }
      final nonce = await context.read<FactoryApi>().claimChallenge(providerId);
      if (!mounted) return;
      final d = await _findDevice();
      if (!mounted) return;
      if (d == null) return _fail(_notAdvertising);
      await _s.connect(d, expectedSerial: _serial, nonce: nonce);
      if (!mounted) return;
      if (!_s.connected) return _fail(_s.error ?? 'Could not connect to the device.');

      setState(() => _phase = 'Adding the device to ${_providers.provider?['name'] ?? 'the provider'}...');
      final proof = _s.proof;
      if (proof == null) return _fail('No session proof from the device.');
      await context.read<FactoryApi>().claimDevice(providerId, _serial!, proof);
      _claimed = true;
      unawaited(_providers.refresh());
      if (!mounted) return;
      setState(() => _step = _Step.wifi);
      _s.scanNetworks();
    } on ApiException catch (e) {
      _fail(_claimError(e));
    } catch (e) {
      _fail(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  /// §16 adım 1–2: `ble_setup` komutu → cihaz `accepted` diyene kadar bekle (≤ 40 sn).
  /// `ble_open` BLE açıkken sunucuya gelmez (kart Wi-Fi'siz, aşamaları kuyruklar); `accepted`
  /// görülünce hemen taranır.
  /// false: akış hatayla durdu. Cihaz çevrimdışıysa doğrudan aramaya devam edilir (§10).
  Future<bool> _openRemoteSetup(String providerId) async {
    final api = context.read<FactoryApi>();
    setState(() => _phase = 'Asking the device to open setup mode...');
    try {
      final r = await api.requestBleSetup(_serial!, providerId: providerId);
      _requestId = r['requestId'] as String?;
    } on ApiException catch (e) {
      switch (e.code) {
        case 'SETUP_IN_PROGRESS':
          _requestId = (e.details as Map?)?['requestId'] as String?;
        case 'DEVICE_OFFLINE':
          // Wi-Fi'si olmayan cihaz BLE'yi 10 dk sonra kendisi açar; doğrudan aranır.
          setState(() => _phase = 'The device is offline — looking for it in setup mode...');
          return true;
        case 'DEVICE_NOT_CONNECTED':
          _fail('This device has no registered connectivity module.');
          return false;
        default:
          if (e.status == 404) return true; // sunucu bu özelliği henüz vermiyor: doğrudan ara
          _fail(e.message.isEmpty ? e.code : e.message);
          return false;
      }
    }
    if (_requestId == null) return true;
    setState(() => _phase = 'Switching the device to setup mode...');
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (mounted && DateTime.now().isBefore(deadline)) {
      try {
        final st = await api.bleSetupStatus(_serial!, _requestId!);
        switch (st['stage']) {
          case 'accepted':
          case 'ble_open':
          case 'creds_received':
            return true;
          case 'not_acknowledged':
            _fail('The device did not respond. It may be off or out of range; if it has no Wi-Fi it opens '
                'setup mode by itself within 10 minutes.');
            return false;
          case 'rejected':
            _fail(_rejectedText(st['reason'] as String?));
            return false;
          case 'timeout':
            _fail('The setup window ended before the phone connected. Try again.');
            return false;
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }
    if (!mounted) return false;
    // Durum gelmediyse yine de aramayı dene: cihaz BLE'yi açmış olabilir.
    return true;
  }

  static String _rejectedText(String? reason) => switch (reason) {
        'busy' => 'The device is already in another setup. Wait a few minutes and try again.',
        'busy_updating' => 'The device is installing an update. Try again when it finishes.',
        'production_mode' => 'The device is still in production mode. Finish production first.',
        'ble_failed' => 'The device could not turn on Bluetooth. Restart the device and try again.',
        'expired' => 'The request expired before the device received it. Try again.',
        _ => 'The device refused to open setup mode (${reason ?? 'unknown reason'}).',
      };

  /// Seri no okunduysa önce "ZEM"+seri adlı cihaz kendiliğinden aranır (fw 0.1.5+);
  /// bulunamazsa (eski firmware) liste açılır. Bluetooth kapalıysa önce açtırılır.
  Future<BleDevice?> _findDevice() async {
    if (!await ensureBluetoothOrWarn(context)) return null;
    if (_serial != null) {
      setState(() => _phase = 'Looking for ${ZmCustomerBle.nameForSerial(_serial!)}...');
      try {
        return await ZmBle.findByName(ZmCustomerBle.nameForSerial(_serial!),
            services: const [ZmCustomerBle.service],
            // uzaktan açmada kart önce Wi-Fi'yi bırakıp BLE'yi açar: biraz daha uzun ara
            timeout: Duration(seconds: _requestId != null ? 45 : 10));
      } catch (_) {
        // eski firmware "Zemits-XXXXXX" yayınlar: personel listeden seçer
      }
    }
    if (!mounted) return null;
    return pickBleDevice(context, mode: BleMode.provider);
  }

  /// Kurulum modu kapalıysa cihaz listede görünmez.
  static const _notAdvertising = 'No device selected. If the device is not in the list, its setup mode is closed: '
      'turn the device off and on again — without Wi-Fi it opens setup mode for 15 minutes.';

  String _claimError(ApiException e) => switch (e.code) {
        'OWNED_BY_OTHER_PROVIDER' =>
          'This device belongs to another provider. Ownership can only be transferred by Zemits.',
        'SERIAL_MISMATCH' => 'The module inside this device is registered to a different serial number.',
        'SERIAL_NOT_IN_CATALOG' => 'This serial number is not in the Zemits catalog.',
        'PROOF_INVALID' => 'The device could not prove its identity.',
        'CHALLENGE_EXPIRED' => 'The one-time code expired. Please try again.',
        'MODULE_NOT_FOUND' => 'This module is not registered at Zemits.',
        'PROVIDER_NOT_FOUND' => 'The selected provider no longer exists.',
        _ when e.status == 404 => 'The server does not support adding devices yet.',
        _ => e.message.isEmpty ? e.code : e.message,
      };

  // --- 4. Wi-Fi ---

  Future<void> _sendWifi() async {
    if (_ssid.text.trim().isEmpty) return;
    setState(() {
      _step = _Step.joining;
      _failure = null;
      _wifiOk = false;
      _serverSlow = false;
    });
    _attemptStartedAt = DateTime.now().toUtc();
    final err = await _s.setWifi(_ssid.text.trim(), _pass.text);
    _pass.clear();
    if (err != null) return _fail(err);
    _timeout?.cancel();
    _timeout = Timer(_joinTimeout, () {
      if (_step != _Step.joining) return;
      // Wi-Fi kaydedildiyse hata değil: sunucuya ulaşamama ayrı gösterilir, kurulum bitirilebilir.
      if (_wifiOk) {
        setState(() => _serverSlow = true);
      } else {
        _fail('The device did not connect in time.');
      }
    });
  }

  /// Modülün kendiliğinden gönderdiği `status` olaylarını izler.
  void _onSession() {
    if (!mounted || _step != _Step.joining) return;
    // Yalnız bu denemenin sonucu sayılır: yanlış parolada modül eski ağına döner ve
    // genel durum "bağlı" görünür (fw 0.1.2 `attempt`).
    if (_s.status?['attemptSsid'] != _s.attemptSsid) return;
    final attempt = _s.attempt;
    if (_wifiErrors.containsKey(attempt)) return _fail(_wifiErrors[attempt]!);
    if (attempt == 'connected' && !_wifiOk) {
      setState(() => _wifiOk = true);
      _startServerPoll();
    }
    // Eski firmware BLE'yi açık tutar ve bulut sonucunu BLE'den bildirir.
    if (_s.attemptSucceeded) _done();
  }

  /// §5 adım 4: cihaz BLE'yi kapatır (kopma normal); sunucuda çevrimiçi görünmesi beklenir.
  void _startServerPoll() {
    _serverPoll?.cancel();
    final api = context.read<FactoryApi>();
    _serverPoll = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted || _step != _Step.joining) {
        _serverPoll?.cancel();
        return;
      }
      try {
        // Wi-Fi değiştirme: sonucu isteğin aşamasından al (§16 adım 5).
        if (_requestId != null) {
          final st = await api.bleSetupStatus(_serial!, _requestId!);
          switch (st['stage']) {
            case 'cloud_ok':
              if (mounted && _step == _Step.joining) _done();
              return;
            case 'wifi_failed':
              final back = st['fellBackTo'] as String?;
              return _fail('The new Wi-Fi did not work (${st['reason'] ?? 'failed'}). '
                  '${back != null ? 'The device went back to "$back".' : 'The device kept its previous settings.'}');
            case 'timeout':
              return _fail('The setup window ended. The device went back to its previous Wi-Fi.');
          }
        }
        final d = await api.device(_serial!);
        final seen = DateTime.tryParse(d['lastSeenAt'] as String? ?? '');
        final fresh = seen != null && seen.isAfter(_attemptStartedAt!.subtract(const Duration(seconds: 10)));
        if (d['online'] == true && fresh && mounted && _step == _Step.joining) _done();
      } catch (_) {
        // cihaz henüz çevrimiçi değil ya da ağ kesintisi: sonraki turda tekrar
      }
    });
  }

  void _fail(String msg) {
    _timeout?.cancel();
    _serverPoll?.cancel();
    if (!mounted) return;
    setState(() {
      _step = _Step.failed;
      _failure = msg;
    });
  }

  /// Başarı (M-15): Wi-Fi bağlı VE sunucuya ulaşılıyor. Bundan sonra veriler sunucudan.
  Future<void> _done() async {
    _timeout?.cancel();
    _serverPoll?.cancel();
    if (_doneCalled) return;
    _doneCalled = true;
    final serial = _serial!;
    await _s.disconnect();
    await _providers.refresh();
    if (!mounted) return;
    if (widget.reconfigure) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Wi-Fi updated — the device is online.')));
      return Navigator.of(context).pop();
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => ProviderDeviceDetailPage(serial: serial, ownedSince: _providers.ownedSince(serial))));
  }

  // --- Görünüm ---

  @override
  Widget build(BuildContext context) {
    final s = context.watch<CustomerSession>();
    return Scaffold(
      appBar: AppBar(title: Text(widget.reconfigure ? 'Wi-Fi settings' : 'Set up new device')),
      body: SafeArea(
        child: Column(children: [
          _StepBar(step: _step, claimed: _claimed),
          Expanded(
            child: switch (_step) {
              _Step.label => _labelView(context),
              _Step.connect => _busy(context, s.phase ?? _phase ?? 'Connecting...'),
              _Step.wifi => _wifiForm(context, s),
              _Step.joining => _wifiOk
                  ? _serverWait(context)
                  : _busy(context, 'Connecting to ${_ssid.text}...', sub: 'This can take up to a minute.'),
              _Step.failed => _failed(context),
            },
          ),
        ]),
      ),
    );
  }

  Widget _center(List<Widget> children) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      );

  Widget _labelView(BuildContext context) => _center([
        Icon(Icons.qr_code_scanner, size: 64, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text('Scan the label of the device you are setting up', style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text('Adding to: ${_providers.provider?['name'] ?? '—'}', textAlign: TextAlign.center),
        const SizedBox(height: 8),
        const Text(
          'Only the device whose label you scan can be added. Make sure it is powered on '
          '(without Wi-Fi it opens setup mode for 15 minutes).',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(onPressed: _scanLabel, icon: const Icon(Icons.camera_alt), label: const Text('Scan label')),
      ]);

  Widget _busy(BuildContext context, String text, {String? sub}) => _center([
        const CircularProgressIndicator(),
        const SizedBox(height: 20),
        Text(text, textAlign: TextAlign.center),
        if (_serial != null) ...[
          const SizedBox(height: 8),
          Text('S/N $_serial', style: const TextStyle(fontFamily: 'monospace')),
        ],
        if (sub != null) ...[
          const SizedBox(height: 8),
          Text(sub, style: Theme.of(context).textTheme.bodySmall),
        ],
      ]);

  Widget _wifiForm(BuildContext context, CustomerSession s) {
    final info = s.info ?? const {};
    final t = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: ListTile(
          leading: const Icon(Icons.verified, color: Colors.green),
          title: Text('${info['model'] ?? ''}  ·  S/N ${info['serial'] ?? ''}'),
          subtitle: Text('Matches the scanned label · added to ${_providers.provider?['name'] ?? 'the provider'}'),
        ),
      ),
      const SizedBox(height: 16),
      Row(children: [
        Text('Choose Wi-Fi network', style: t.titleMedium),
        const Spacer(),
        IconButton(
          tooltip: 'Scan again',
          onPressed: s.scanning ? null : s.scanNetworks,
          icon: s.scanning
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh),
        ),
      ]),
      for (final n in s.networks)
        ListTile(
          dense: true,
          leading: Icon(n['open'] == true ? Icons.wifi : Icons.wifi_password),
          title: Text('${n['ssid']}'),
          trailing: Text('${n['rssi']} dBm'),
          selected: _ssid.text == n['ssid'],
          onTap: () => setState(() => _ssid.text = '${n['ssid']}'),
        ),
      const SizedBox(height: 12),
      TextField(controller: _ssid, decoration: const InputDecoration(labelText: 'Network name (SSID)')),
      const SizedBox(height: 12),
      TextField(
        controller: _pass,
        obscureText: _obscure,
        decoration: InputDecoration(
          labelText: 'Password',
          suffixIcon: IconButton(
            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Text('The password goes only to the device; it is not stored or sent to any server.', style: t.bodySmall),
      const SizedBox(height: 20),
      FilledButton(onPressed: _sendWifi, child: const Text('Connect')),
    ]);
  }

  /// fw 0.1.4 `cloudError` → kullanıcı mesajı (customer_ble_setup.md "Kullanıcı mesajları").
  static String _cloudErrorText(String? code) => switch (code) {
        'dns' => 'On Wi-Fi, but the Zemits server name cannot be resolved (DNS).',
        'tcp' => 'On Wi-Fi, but the Zemits server cannot be reached. The network may block port 8883.',
        'tls' => 'A secure connection to the server could not be established.',
        'auth' => 'The device is not registered at Zemits or has no active registration. Contact support.',
        'no_time' => 'The device could not get the time from the internet (NTP). Check internet access.',
        'refused' => 'The Zemits server refused the connection.',
        _ => 'On Wi-Fi, but the device cannot reach the Zemits server yet.',
      };

  /// Wi-Fi tamam; sunucu bağlantısı bekleniyor.
  Widget _serverWait(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return _center([
      const Icon(Icons.wifi, size: 56, color: Colors.green),
      const SizedBox(height: 12),
      Text('Wi-Fi connected to ${_ssid.text}', style: t.titleMedium, textAlign: TextAlign.center),
      const SizedBox(height: 24),
      if (!_serverSlow) ...[
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        const Text('Connecting to the Zemits server...', textAlign: TextAlign.center),
      ] else ...[
        Icon(Icons.cloud_off, size: 40, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 8),
        Text(_cloudErrorText(context.watch<CustomerSession>().status?['cloudError'] as String?),
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        const Text('The Wi-Fi network is saved. The device keeps trying and appears online as soon as it '
            'reaches the server. If it cannot connect for 10 minutes, it opens setup mode again by itself '
            '(or turn it off and on).', textAlign: TextAlign.center),
        const SizedBox(height: 20),
        FilledButton(onPressed: _done, child: const Text('Finish setup')),
        TextButton(
          onPressed: () {
            setState(() => _serverSlow = false);
            _timeout = Timer(_joinTimeout, () {
              if (mounted && _step == _Step.joining) setState(() => _serverSlow = true);
            });
          },
          child: const Text('Keep waiting'),
        ),
      ],
    ]);
  }

  Widget _failed(BuildContext context) => _center([
        Icon(Icons.error_outline, size: 56, color: Theme.of(context).colorScheme.error),
        const SizedBox(height: 16),
        Text(_failure ?? 'Setup failed.', textAlign: TextAlign.center),
        const SizedBox(height: 24),
        if (_claimed && _s.connected)
          FilledButton(onPressed: () => setState(() => _step = _Step.wifi), child: const Text('Try Wi-Fi again'))
        else if (widget.reconfigure || _claimed)
          // Cihaz zaten eklendi: etiketi yeniden okutmadan aynı cihaza tekrar bağlan.
          FilledButton(onPressed: _connect, child: const Text('Connect again'))
        else
          FilledButton(onPressed: _scanLabel, child: const Text('Start again')),
      ]);
}

/// Üstte adım göstergesi: Label → Match → Wi-Fi → Online.
class _StepBar extends StatelessWidget {
  final _Step step;
  final bool claimed;
  const _StepBar({required this.step, required this.claimed});

  @override
  Widget build(BuildContext context) {
    final idx = switch (step) {
      _Step.label => 0,
      _Step.connect => 1,
      _Step.wifi => 2,
      _Step.joining => 3,
      _Step.failed => claimed ? 2 : 1,
    };
    const names = ['Label', 'Match & add', 'Wi-Fi', 'Online'];
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(children: [
        for (var i = 0; i < names.length; i++) ...[
          if (i > 0) Expanded(child: Divider(color: i <= idx ? scheme.primary : scheme.outlineVariant)),
          Column(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: i < idx ? scheme.primary : (i == idx ? scheme.primaryContainer : scheme.surfaceContainerHighest),
              child: i < idx
                  ? Icon(Icons.check, size: 14, color: scheme.onPrimary)
                  : Text('${i + 1}', style: TextStyle(fontSize: 11, color: scheme.onSurface)),
            ),
            const SizedBox(height: 4),
            Text(names[i], style: Theme.of(context).textTheme.labelSmall),
          ]),
        ],
      ]),
    );
  }
}
