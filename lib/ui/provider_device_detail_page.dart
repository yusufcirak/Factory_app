import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/factory_api.dart';
import 'provider_devices_page.dart';
import 'provider_setup_wizard.dart';
import 'wifi_change_dialog.dart';

/// Provider → cihaz ayrıntısı: bağlantı, sürümler, güncellemeler, kullanım — hepsi sunucudan.
/// Üç istek birbirinden bağımsız; biri yoksa (ör. kullanım kapalı) diğerleri yine gösterilir.
class ProviderDeviceDetailPage extends StatefulWidget {
  final String serial;

  /// Cihazın bu sağlayıcıya geçtiği an; devir kuralı (§6.2): öncesinin kullanımı gösterilmez.
  final DateTime? ownedSince;
  const ProviderDeviceDetailPage({super.key, required this.serial, this.ownedSince});

  @override
  State<ProviderDeviceDetailPage> createState() => _ProviderDeviceDetailPageState();
}

class _Section<T> {
  T? data;
  Object? error;
}

class _ProviderDeviceDetailPageState extends State<ProviderDeviceDetailPage> {
  final _device = _Section<Map<String, dynamic>>();
  final _updates = _Section<Map<String, dynamic>>();
  final _usage = _Section<Map<String, dynamic>>();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<FactoryApi>();
    setState(() => _loading = true);
    Future<void> fetch(_Section<Map<String, dynamic>> s, Future<Map<String, dynamic>> f) async {
      try {
        s.data = await f;
        s.error = null;
      } catch (e) {
        s.error = e;
      }
    }

    await Future.wait([
      fetch(_device, api.device(widget.serial)),
      fetch(_updates, api.deviceUpdates(widget.serial)),
      fetch(_usage, api.deviceUsage(widget.serial)),
    ]);
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.serial, style: const TextStyle(fontFamily: 'monospace')),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: _loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(12), children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.wifi),
              title: const Text('Wi-Fi settings'),
              subtitle: Text(_onWifi
                  ? 'Change the Wi-Fi network over the server'
                  : 'Connect over Bluetooth and enter or change the Wi-Fi network'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _changeWifi,
            ),
          ),
          _card(context, 'Connection', _device, _connection),
          _card(context, 'Software', _device, _versions),
          _card(context, 'Updates', _updates, _updatesView),
          _card(context, 'Usage (last 30 days)', _usage, _usageView),
        ]),
      ),
    );
  }

  /// Cihaz Wi-Fi ile çevrimiçi: ağ sunucudan değiştirilir (BLE'siz). Değilse BLE akışı.
  bool get _onWifi => _device.data?['online'] == true && _device.data?['route'] != 'relay';

  Future<void> _changeWifi() async {
    if (_onWifi) {
      final ssid = (_device.data?['wifi'] as Map?)?['ssid'] as String?;
      final r = await showWifiChangeDialog(context, widget.serial, currentSsid: ssid);
      if (!mounted) return;
      if (r != WifiChangeResult.useBluetooth) {
        if (r == WifiChangeResult.done) _load();
        return;
      }
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProviderSetupWizard(serial: widget.serial)));
    if (mounted) _load();
  }

  Widget _card(BuildContext context, String title, _Section<Map<String, dynamic>> s,
      List<Widget> Function(BuildContext, Map<String, dynamic>) body) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: t.titleSmall),
          const SizedBox(height: 8),
          if (s.data != null)
            ...body(context, s.data!)
          else if (s.error != null)
            Text(_errorText(s.error!), style: TextStyle(color: Theme.of(context).colorScheme.error))
          else
            const LinearProgressIndicator(),
        ]),
      ),
    );
  }

  String _errorText(Object e) {
    if (e is ApiException) {
      return switch (e.code) {
        'DEVICE_NOT_CONNECTED' => 'No module is registered for this serial number.',
        'NETWORK' => 'Cannot reach the server.',
        _ when e.status == 404 => 'Device data is turned off for this app on the server.',
        _ when e.status == 403 => 'Not available to this app.',
        _ => e.message.isEmpty ? e.code : e.message,
      };
    }
    return e.toString();
  }

  List<Widget> _connection(BuildContext context, Map<String, dynamic> d) {
    final (label, icon, color) = connectionLabel({
      'status': d['online'] == true ? 'online' : (d['lastSeenAt'] == null ? 'never_connected' : 'offline'),
      'via': d['route'] == 'relay' ? 'relay' : 'wifi',
    });
    return [
      Row(children: [Icon(icon, color: color), const SizedBox(width: 8), Text(label)]),
      const SizedBox(height: 8),
      _kv(context, 'Model', d['deviceModelId']),
      _kv(context, 'Module', d['moduleId']),
      _kv(context, 'Role', d['role']),
      _kv(context, 'Wi-Fi', _wifi(d['wifi'])),
      _kv(context, 'Last seen', _date(d['lastSeenAt'])),
      _kv(context, 'Binding', d['bindingEpoch'] == null ? null : 'epoch ${d['bindingEpoch']}'),
      _kv(context, 'Equipment ready', d['connectedEquipmentReady'] == true ? 'Yes' : 'No'),
    ];
  }

  List<Widget> _versions(BuildContext context, Map<String, dynamic> d) {
    final v = (d['versions'] as Map?) ?? const {};
    return [
      _kv(context, 'ESP module', v['esp']),
      _kv(context, 'Display (DWIN)', v['dwin']),
      _kv(context, 'Mainboard', v['mb']),
      _kv(context, 'Command catalog', v['commandCatalog']),
    ];
  }

  List<Widget> _updatesView(BuildContext context, Map<String, dynamic> u) {
    final installed = (u['installed'] as Map?) ?? const {};
    final available = ((u['available'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final history = ((u['history'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return [
      _kv(context, 'Installed ESP', installed['esp']),
      _kv(context, 'Installed display', installed['dwin']),
      const SizedBox(height: 8),
      if (available.isEmpty) const Text('Up to date — no updates available.'),
      for (final a in available)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.system_update),
          title: Text('${a['kindLabel'] ?? a['kind']} ${a['version']}'),
          subtitle: Text([
            _stage(a['stage'] as String?),
            // ESP indirirken MQTT kapalı: ara ilerleme gelmez, yalnız aşama gösterilir.
            if (a['kind'] != 'esp' && a['progress'] is Map) _progress(a['progress'] as Map),
            if (a['waitingReason'] == 'awaiting_user') 'tap Update to install',
            if (a['stage'] == 'waiting_for_idle' || a['waitingReason'] == 'host_busy')
              'will install when the screen is not in use',
            if ((a['notes'] as String?)?.isNotEmpty == true) a['notes'],
          ].join(' · ')),
          // D15: ESP kendini günceller; DWIN yalnız kullanıcı başlatınca kurulur.
          trailing: _needsUserStart(a)
              ? FilledButton(onPressed: () => _install(a), child: const Text('Update'))
              : null,
        ),
      if (history.isNotEmpty) ...[
        const Divider(),
        for (final h in history.take(5))
          _kv(context, '${h['kind'] ?? ''} ${h['version']}', _stage(h['stage'] as String?)),
      ],
    ];
  }

  /// "Update" yalnız sunucu `canApprove: true` dediğinde: kullanıcı başlatması bekleyen DWIN
  /// işi (waitingReason "awaiting_user"). ESP işlerinde her zaman false (D15).
  static bool _needsUserStart(Map<String, dynamic> a) => a['canApprove'] == true;

  Future<void> _install(Map<String, dynamic> a) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await context.read<FactoryApi>().installUpdate(widget.serial, a['updateId'] as String);
      messenger.showSnackBar(const SnackBar(
          content: Text('Update started. The display installs it when the screen is not in use.')));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(switch (e.code) {
        'UPDATE_INCOMPATIBLE' => 'This update is no longer valid for the device.',
        'UPDATE_ALREADY_INSTALLED' => 'Already installed.',
        _ when e.status == 404 => 'The server does not support starting updates from this app yet.',
        _ => e.message.isEmpty ? e.code : e.message,
      })));
    }
    if (mounted) await _load();
  }

  List<Widget> _usageView(BuildContext context, Map<String, dynamic> u) {
    if (u['hasData'] != true) return [const Text('No data')]; // M-13: veri yok ≠ 0
    final since = widget.ownedSince;
    if (since != null) return _usageSince(context, u, since);
    final totals = (u['totals'] as Map?) ?? const {};
    return [
      for (final e in totals.entries)
        _kv(context, '${e.key}'.replaceAll('_', ' '),
            'device ${(e.value as Map)['device'] ?? 0} · app ${(e.value as Map)['emulated'] ?? 0}'),
      _kv(context, 'Last event', _date(u['lastEventAt'])),
      if (u['metricsDefinitionPending'] == true)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Raw event counts — metric definitions pending.', style: Theme.of(context).textTheme.labelSmall),
        ),
    ];
  }

  /// Devirden sonraki günlerin toplamı (günlük sayımlardan; cihaz/uygulama ayrımı günlükte yok).
  List<Widget> _usageSince(BuildContext context, Map<String, dynamic> u, DateTime since) {
    final from = DateTime(since.toLocal().year, since.toLocal().month, since.toLocal().day);
    final sums = <String, num>{};
    for (final day in ((u['daily'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final d = DateTime.tryParse(day['day'] as String? ?? '');
      if (d == null || d.isBefore(from)) continue;
      ((day['counts'] as Map?) ?? const {}).forEach((k, v) => sums['$k'] = (sums['$k'] ?? 0) + (v as num));
    }
    return [
      if (sums.isEmpty) const Text('No data since this provider took ownership.'),
      for (final e in sums.entries) _kv(context, e.key.replaceAll('_', ' '), '${e.value}'),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text('Since ownership started ${_date(since.toIso8601String())} · raw event counts.',
            style: Theme.of(context).textTheme.labelSmall),
      ),
    ];
  }

  static String _stage(String? s) => switch (s) {
        'available' => 'available',
        'downloading' => 'Downloading…',
        'downloaded' => 'downloaded',
        'verified' => 'verified',
        'waiting_for_idle' => 'waiting',
        'flashing' => 'installing',
        'installed' => 'installed',
        'failed' => 'failed',
        _ => s ?? '—',
      };

  /// Modülün bildirdiği gerçek bayt sayıları (M-19: tahmini yüzde yok).
  static String _progress(Map p) {
    final b = (p['bytes'] as num?) ?? 0, t = (p['total'] as num?) ?? 0;
    return t > 0 ? '${(b / 1024).round()} / ${(t / 1024).round()} KB' : '${(b / 1024).round()} KB';
  }

  static String? _wifi(Object? w) {
    if (w is! Map || w['ssid'] == null) return null;
    final rssi = w['rssi'];
    return rssi == null ? '${w['ssid']}' : '${w['ssid']} ($rssi dBm)';
  }

  static String? _date(Object? iso) {
    final d = DateTime.tryParse(iso as String? ?? '');
    if (d == null) return null;
    final l = d.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  Widget _kv(BuildContext context, String k, Object? v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 140, child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(
            child: SelectableText((v == null || v == '') ? '—' : '$v',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
          ),
        ]),
      );
}
