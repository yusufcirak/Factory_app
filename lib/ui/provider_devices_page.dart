import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/gs1.dart';
import '../services/factory_api.dart';
import '../state/provider_devices.dart';
import 'label_scan_page.dart';
import 'provider_device_detail_page.dart';
import 'provider_setup_wizard.dart';

/// Provider → seçili sağlayıcının cihazları ve bağlantı durumu, sunucudan (Device Hub karşılığı).
///
/// Cihaz eklemenin iki yolu (FACTORY_API.md):
///  - Etiketle: klinikte kurulu cihaz varsa. Etiket okutulur → geçici sahiplik → cihaz
///    Wi-Fi'yi kardeşinden alır → sunucu klinikte görünce kesinleştirir (1 gün).
///  - Bluetooth: ilk cihaz ya da yakında kurulu cihaz yoksa; ESP32 seri no eşleşmesi +
///    modülün oturum imzası (yakınlık kanıtı).
/// Başka sağlayıcının cihazı eklenemez; devri yalnız Zemits panelden yapar.
class ProviderDevicesPage extends StatefulWidget {
  const ProviderDevicesPage({super.key});

  @override
  State<ProviderDevicesPage> createState() => _ProviderDevicesPageState();
}

class _ProviderDevicesPageState extends State<ProviderDevicesPage> {
  @override
  void initState() {
    super.initState();
    final d = context.read<ProviderDevices>();
    d.load();
    d.startPolling();
  }

  @override
  void dispose() {
    context.read<ProviderDevices>().stopPolling();
    super.dispose();
  }

  Future<void> _add() async {
    final choice = await showModalBottomSheet<String>(context: context, builder: (_) => const _AddChoiceSheet());
    if (!mounted || choice == null) return;
    if (choice == 'ble') {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProviderSetupWizard()));
      if (mounted) await context.read<ProviderDevices>().refresh();
    } else {
      await _addByLabel();
    }
  }

  /// Etiketle ekleme: okut → geçici sahiplik → cihazın klinikte bağlanması beklenir.
  Future<void> _addByLabel() async {
    final d = context.read<ProviderDevices>();
    final api = context.read<FactoryApi>();
    final messenger = ScaffoldMessenger.of(context);
    final label = await Navigator.of(context).push<Gs1Label>(MaterialPageRoute(builder: (_) => const LabelScanPage()));
    final serial = label?.serial;
    if (serial == null || d.providerId == null) return;
    try {
      final r = await api.claimByLabel(d.providerId!, serial);
      await d.refresh();
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(r['unchanged'] == true
            ? 'S/N $serial is already in this list.'
            : 'S/N $serial added. Power on the device — it connects through a nearby Zemits device.'),
      ));
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(switch (e.code) {
          'OWNED_BY_OTHER_PROVIDER' => 'S/N $serial belongs to another provider. Contact Zemits support.',
          'NO_MODULE' => 'S/N $serial has no connectivity module.',
          'SERIAL_NOT_IN_CATALOG' => 'S/N $serial is not in the Zemits catalog.',
          _ when e.status == 404 => 'The server does not support adding devices yet.',
          _ => e.message.isEmpty ? e.code : e.message,
        }),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<ProviderDevices>();
    final waiting = d.devices.where((x) => x['provisional'] == true).toList();
    final owned = d.devices.where((x) => x['provisional'] != true).toList();
    return Scaffold(
      floatingActionButton: d.providerId == null
          ? null
          : FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add device')),
      body: RefreshIndicator(
        onRefresh: d.load,
        child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
          if (d.providers.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: d.providerId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Provider'),
              items: [
                for (final p in d.providers)
                  DropdownMenuItem(
                      value: p['id'] as String, child: Text('${p['name']}  ·  ${p['deviceCount']} devices')),
              ],
              onChanged: (id) {
                if (id != null) d.selectProvider(id);
              },
            ),
          const SizedBox(height: 8),
          if (d.nearby.isNotEmpty) _NearbyCard(nearby: d.nearby, onScan: _addByLabel),
          if (d.error != null) _ErrorBanner(d.error!),
          if (d.error == null && d.providers.isEmpty && !d.loading)
            const _Hint('No providers on the server yet. Create a provider in the admin panel (Providers).'),
          if (d.error == null && d.providerId != null && d.devices.isEmpty && !d.loading)
            const _Hint('No devices yet. Tap "Add device".'),
          if (waiting.isNotEmpty) ...[
            _Header('Waiting to connect (${waiting.length})'),
            for (final dev in waiting) _WaitingTile(data: dev),
            if (owned.isNotEmpty) _Header('Devices (${owned.length})'),
          ],
          for (final dev in owned) _DeviceTile(data: dev),
          if (d.updatedAt != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text('Updated ${TimeOfDay.fromDateTime(d.updatedAt!).format(context)} · refreshes every 15 s',
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelSmall),
            ),
        ]),
      ),
    );
  }
}

class _AddChoiceSheet extends StatelessWidget {
  const _AddChoiceSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('Add device')),
        ListTile(
          leading: const Icon(Icons.qr_code_scanner),
          title: const Text('Scan label'),
          subtitle: const Text('The clinic already has Zemits devices. The new device gets Wi-Fi from them.'),
          onTap: () => Navigator.pop(context, 'label'),
        ),
        ListTile(
          leading: const Icon(Icons.bluetooth),
          title: const Text('Set up with Bluetooth'),
          subtitle: const Text('First device at this clinic, or no Zemits device nearby. You enter the Wi-Fi.'),
          onTap: () => Navigator.pop(context, 'ble'),
        ),
        const SizedBox(height: 8),
      ]),
    );
  }
}

/// `status` → etiket, ikon, renk (MOBILE_API.md tablosu).
(String, IconData, Color) connectionLabel(Map<String, dynamic>? d) {
  final via = d?['via'];
  return switch (d?['status']) {
    'online' => (
        via == 'relay' ? 'Connected (via another device)' : 'Connected to Zemits (Wi-Fi)',
        Icons.cloud_done,
        Colors.green
      ),
    'offline' => ('Offline', Icons.cloud_off, Colors.orange),
    'never_connected' => ('Not set up yet', Icons.cloud_queue, Colors.grey),
    'no_module' => ('No connectivity module', Icons.link_off, Colors.grey),
    _ => ('Unknown', Icons.help_outline, Colors.grey),
  };
}

class _DeviceTile extends StatelessWidget {
  final Map<String, dynamic> data;
  const _DeviceTile({required this.data});

  @override
  Widget build(BuildContext context) {
    final serial = data['serial'] as String;
    final (label, icon, color) = connectionLabel(data);
    final versions = (data['versions'] as Map?) ?? const {};
    final lastSeen = DateTime.tryParse(data['lastSeenAt'] as String? ?? '');
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color, size: 32),
        title: Text(data['modelName'] as String? ?? data['deviceModelId'] as String? ?? serial),
        subtitle: Text([
          'S/N $serial',
          label,
          if (versions['esp'] != null) 'ESP ${versions['esp']}',
          if (versions['dwin'] != null) 'Display ${versions['dwin']}',
          if (data['status'] == 'offline' && lastSeen != null) 'last seen ${_ago(lastSeen)}',
        ].join(' · ')),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ProviderDeviceDetailPage(
                serial: serial, ownedSince: DateTime.tryParse(data['ownedSince'] as String? ?? '')))),
      ),
    );
  }
}

/// Etiketle eklenmiş, klinikte henüz görülmemiş (geçici sahiplik).
class _WaitingTile extends StatelessWidget {
  final Map<String, dynamic> data;
  const _WaitingTile({required this.data});

  Future<void> _cancel(BuildContext context) async {
    final d = context.read<ProviderDevices>();
    final api = context.read<FactoryApi>();
    final messenger = ScaffoldMessenger.of(context);
    final serial = data['serial'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wrong label?'),
        content: Text('Remove S/N $serial? It has not connected at this clinic yet.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true || d.providerId == null) return;
    try {
      await api.cancelProvisional(d.providerId!, serial);
    } on ApiException catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(e.code == 'PROVISIONAL_NOT_FOUND'
              ? 'S/N $serial has already connected; it can no longer be removed here.'
              : e.message)));
    }
    await d.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final serial = data['serial'] as String;
    final until = DateTime.tryParse(data['provisionalUntil'] as String? ?? '');
    return Card(
      child: ListTile(
        leading: const SizedBox(width: 32, height: 32, child: Padding(
          padding: EdgeInsets.all(4),
          child: CircularProgressIndicator(strokeWidth: 2.5),
        )),
        title: Text(data['modelName'] as String? ?? data['deviceModelId'] as String? ?? serial),
        subtitle: Text([
          'S/N $serial',
          'Power on the device — waiting for it to connect',
          if (until != null) 'expires ${_in(until)}',
        ].join(' · ')),
        trailing: IconButton(tooltip: 'Wrong label', icon: const Icon(Icons.close), onPressed: () => _cancel(context)),
      ),
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t.toLocal());
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

String _in(DateTime t) {
  final d = t.toLocal().difference(DateTime.now());
  if (d.inHours >= 1) return 'in ${d.inHours} h';
  return 'in ${d.inMinutes.clamp(0, 59)} min';
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _ErrorBanner extends StatelessWidget {
  final String error;
  const _ErrorBanner(this.error);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = error.contains('PROVIDER_NOT_FOUND')
        ? 'This provider no longer exists on the server. Pull down to reload.'
        : (error.contains('HTTP_404') || error.contains('NOT_FOUND') || error.contains('Route'))
            ? 'Device data is turned off for this app on the server.'
            : error;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(32), child: Text(text, textAlign: TextAlign.center));
}

/// §8: "Yakında hesabınızda olmayan cihaz var — etiketini okutun". Etiketle ekleme
/// geçici sahiplik verir; cihaz kardeşinden Wi-Fi alıp klinikte görülünce kesinleşir.
class _NearbyCard extends StatelessWidget {
  final List<Map<String, dynamic>> nearby;
  final VoidCallback onScan;
  const _NearbyCard({required this.nearby, required this.onScan});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Card(
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.fiber_new, color: scheme.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                nearby.length == 1
                    ? 'A device nearby is not in your account'
                    : '${nearby.length} devices nearby are not in your account',
                style: t.titleMedium?.copyWith(color: scheme.onTertiaryContainer),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          Text('Scan its serial number label to add it. It then gets Wi-Fi from your other devices.',
              style: TextStyle(color: scheme.onTertiaryContainer)),
          const SizedBox(height: 8),
          for (final n in nearby)
            Text(
              '• ${n['modelId'] ?? 'Zemits device'}'
              '${n['reportedBy'] != null ? ' · next to S/N ${n['reportedBy']}' : ''}'
              '${_seen(n['seenAt'])}',
              style: t.bodySmall?.copyWith(color: scheme.onTertiaryContainer),
            ),
          const SizedBox(height: 12),
          FilledButton.icon(
              onPressed: onScan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan serial number')),
        ]),
      ),
    );
  }

  static String _seen(Object? iso) {
    final d = DateTime.tryParse(iso as String? ?? '');
    return d == null ? '' : ' · ${_ago(d)}';
  }
}
