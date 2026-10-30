import 'dart:async';

import 'package:flutter/material.dart';
import 'package:universal_ble/universal_ble.dart';

import '../services/zm_ble.dart';
import '../services/zm_customer_ble.dart';

/// Cihaz müşteri kurulum servisini (kullanıcı modu) mı yayınlıyor?
bool isCustomerMode(BleDevice d) {
  final name = d.name ?? d.rawName ?? '';
  return d.services.any((u) => u.toLowerCase() == ZmCustomerBle.service) ||
      name.startsWith(ZmCustomerBle.namePrefix) ||
      name.startsWith(ZmCustomerBle.serialNamePrefix); // "ZEM…" ile modül kimliği "ZM…" çakışmaz
}

/// Bluetooth kapalıysa Android'in açma penceresini gösterir; yine kapalıysa uyarır.
Future<bool> ensureBluetoothOrWarn(BuildContext context) async {
  if (await ZmBle.ensureBluetoothOn()) return true;
  if (!context.mounted) return false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.bluetooth_disabled),
      title: const Text('Turn on Bluetooth'),
      content: const Text('Bluetooth is needed to find the device. Turn it on and try again.'),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
    ),
  );
  return false;
}

/// Hangi Zemits cihazları listelensin: üretim modu (fabrika servisi, `ZM…`) ya da
/// kullanıcı modu (müşteri kurulum servisi, `Zemits-XXXXXX`).
enum BleMode { manufacturing, provider }

/// Zemits cihazlarını listeler; seçileni döner.
/// Önce Bluetooth'un açık olduğundan emin olur (gerekirse sistem penceresi).
Future<BleDevice?> pickBleDevice(BuildContext context, {BleMode mode = BleMode.manufacturing}) async {
  if (!await ensureBluetoothOrWarn(context)) return null;
  if (!context.mounted) return null;
  return showModalBottomSheet<BleDevice>(
    context: context,
    isScrollControlled: true,
    builder: (_) => FractionallySizedBox(heightFactor: 0.7, child: _BlePicker(mode: mode)),
  );
}

class _BlePicker extends StatefulWidget {
  final BleMode mode;
  const _BlePicker({required this.mode});

  @override
  State<_BlePicker> createState() => _BlePickerState();
}

class _BlePickerState extends State<_BlePicker> {
  final _found = <String, BleDevice>{};
  StreamSubscription<BleDevice>? _sub;
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = ZmBle.scan(services: [widget.mode == BleMode.manufacturing ? ZmBle.service : ZmCustomerBle.service]).listen(
      (d) => setState(() => _found[d.deviceId] = d),
      onError: (Object e) => setState(() => _error = e.toString()),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = _found.values.toList()..sort((a, b) => (b.rssi ?? -127).compareTo(a.rssi ?? -127));
    return Column(
      children: [
        ListTile(
          title: const Text('Zemits devices'),
          subtitle: Text(_error ??
              (widget.mode == BleMode.provider
                  ? 'Scanning for devices in setup mode (Zemits-XXXXXX)...'
                  : 'Scanning for modules in production mode (ZM + MAC)...')),
          trailing: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
        const Divider(height: 1),
        Expanded(
          child: list.isEmpty
              ? const Center(child: Text('No devices found yet'))
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final d = list[i];
                    final customer = isCustomerMode(d);
                    return ListTile(
                      leading: Icon(customer ? Icons.lock_outline : Icons.precision_manufacturing_outlined),
                      title: Text(d.name ?? d.rawName ?? d.deviceId, style: const TextStyle(fontFamily: 'monospace')),
                      subtitle: Text('${customer ? 'Setup mode' : 'Production mode'} · ${d.deviceId}'),
                      trailing: Text('${d.rssi ?? '–'} dBm'),
                      onTap: () => Navigator.of(context).pop(d),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
