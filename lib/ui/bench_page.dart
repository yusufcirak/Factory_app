import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/device_session.dart';
import 'ble_picker.dart';

/// Manufacturing → Bench: üretim modundaki modüle BLE ile bağlan, verileri gör,
/// fonksiyon taklidi (UART kayıt/oynatma).
class BenchPage extends StatelessWidget {
  const BenchPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<DeviceSession>();
    if (!s.connected) return _Disconnected(session: s);
    return DefaultTabController(
      length: 3,
      child: Column(children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: ListTile(
            leading: const Icon(Icons.bluetooth_connected, color: Colors.green),
            title: Text(s.deviceName ?? '', style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
            subtitle: Text((s.info?['device'] as Map?)?['deviceName'] as String? ?? 'No model info'),
            trailing: TextButton(onPressed: s.disconnect, child: const Text('Disconnect')),
          ),
        ),
        const TabBar(tabs: [
          Tab(icon: Icon(Icons.info_outline), text: 'Info'),
          Tab(icon: Icon(Icons.wifi), text: 'Wi-Fi'),
          Tab(icon: Icon(Icons.play_circle_outline), text: 'Functions'),
        ]),
        if (s.error != null)
          MaterialBanner(
            content: Text(s.error!),
            actions: [TextButton(onPressed: () => s.refreshStatus(), child: const Text('Refresh'))],
          ),
        const Expanded(child: TabBarView(children: [_InfoTab(), _WifiTab(), _FunctionsTab()])),
      ]),
    );
  }
}

class _Disconnected extends StatelessWidget {
  final DeviceSession session;
  const _Disconnected({required this.session});

  @override
  Widget build(BuildContext context) {
    final busy = session.connecting;
    final err = session.error;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.bluetooth_searching, size: 72, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          const Text('Connect to a module over Bluetooth', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 8),
          const Text('Production mode modules: identity, versions, Wi-Fi and bridge status; record and replay UART functions.',
              textAlign: TextAlign.center),
          if (err != null) ...[
            const SizedBox(height: 12),
            Text(err, style: TextStyle(color: Theme.of(context).colorScheme.error), textAlign: TextAlign.center),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: busy
                ? null
                : () async {
                    final d = await pickBleDevice(context);
                    if (d != null) await session.connect(d);
                  },
            icon: busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.search),
            label: Text(busy ? 'Connecting...' : 'Find module'),
          ),
        ]),
      ),
    );
  }
}

// --- Bilgi -----------------------------------------------------------------

class _InfoTab extends StatelessWidget {
  const _InfoTab();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<DeviceSession>();
    final info = s.info ?? const {};
    final dev = (info['device'] as Map?) ?? const {};
    final st = s.status ?? const {};
    final wifi = (st['wifi'] as Map?) ?? const {};
    final link = (st['link'] as Map?) ?? const {};
    final bridge = (st['bridge'] as Map?) ?? const {};

    return RefreshIndicator(
      onRefresh: () async {
        await s.refreshInfo();
        await s.refreshStatus();
      },
      child: ListView(padding: const EdgeInsets.all(12), children: [
        _KvCard('Identity', {
          'Module': info['moduleId'],
          'ESP firmware': info['fwVersion'],
          'Image SHA-256': info['imageHash'],
          'Provisioned': info['provisioned'] == true ? 'Yes' : 'No',
          'Server key': info['serverKeyLoaded'] == true ? 'Loaded' : 'Missing',
        }),
        _KvCard('Device (label)', {
          'Model name': dev['deviceName'],
          'Model': dev['modelId'],
          'Serial no.': dev['serial'],
          'GTIN': dev['gtin'],
          'Mfg. date': dev['mfgDate'],
          'Lot': dev['lot'],
          'Hardware rev.': dev['hwRevision'],
        }),
        _KvCard('Runtime', {
          'Uptime': _uptime(st['uptimeS']),
          'Boot count': st['bootCount'],
          'Free heap': st['freeHeap'] == null ? null : '${((st['freeHeap'] as num) / 1024).toStringAsFixed(1)} KB',
          'DWIN UI': st['dwinVersion'],
          'Device busy': st['hostBusy'] == null ? null : (st['hostBusy'] == true ? 'Yes' : 'No'),
          'Last UART traffic': st['msSinceTraffic'] == null ? null : '${((st['msSinceTraffic'] as num) / 1000).toStringAsFixed(1)} s ago',
          'Network mode': st['netMode'],
        }, footer: s.statusAt == null ? null : 'Updated ${TimeOfDay.fromDateTime(s.statusAt!).format(context)} · every 3 s'),
        _KvCard('Connectivity', {
          'Wi-Fi': wifi['ssid'],
          'Status': wifi['connected'] == true ? 'Connected' : 'Not connected',
          'IP': wifi['ip'],
          'Signal': wifi['rssi'] == null ? null : '${wifi['rssi']} dBm',
          'Role': link['role'],
          'Server': link['online'] == null ? null : (link['online'] == true ? 'Online' : 'Offline'),
        }),
        if (bridge.isNotEmpty) _KvCard('UART bridge', {for (final e in bridge.entries) e.key as String: e.value}),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Self-test'),
            onPressed: () => s.selfTest((r) => _showSelfTest(context, r)),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.verified),
            label: const Text('Finalize production'),
            onPressed: s.lastSelfTestPassed != true
                ? null
                : () async {
                    final ok = await _confirm(
                        context,
                        'Finalize production? The module switches to user mode and restarts. '
                        'This Bench connection will no longer be available for it.');
                    if (!ok) return;
                    final err = await s.finalize();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(err ?? 'Production complete. The module restarted in user mode.')));
                    }
                  },
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reboot'),
            onPressed: () async {
              final ok = await _confirm(context, 'Reboot the module? The BLE connection will drop.');
              if (ok) await s.reboot();
            },
          ),
        ]),
      ]),
    );
  }

  static String? _uptime(Object? sec) {
    if (sec is! num) return null;
    final d = Duration(seconds: sec.toInt());
    return '${d.inHours}h ${d.inMinutes % 60}m ${d.inSeconds % 60}s';
  }

  void _showSelfTest(BuildContext context, Map<String, dynamic> r) {
    final checks = (r['checks'] as Map?) ?? const {};
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(r['passed'] == true ? 'Self-test passed' : 'Self-test failed'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final e in checks.entries)
            ListTile(
              dense: true,
              leading: Icon(
                e.value == false ? Icons.close : Icons.check,
                color: e.value == false ? Colors.red : Colors.green,
              ),
              title: Text('${e.key}'),
              trailing: e.value is bool ? null : Text('${e.value}'),
            ),
          if (r['passed'] == true)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('You can now finalize production.'),
            )
          else if (checks.entries.any((e) => e.value == false && {'uartDwin', 'uartMb', 'bridge'}.contains(e.key)))
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Is the module installed in the device and the device powered on? '
                  'The mainboard check needs traffic in the last 10 s — touch the screen and run the test again.'),
            ),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }
}

class _KvCard extends StatelessWidget {
  final String title;
  final Map<String, Object?> values;
  final String? footer;
  const _KvCard(this.title, this.values, {this.footer});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: t.titleSmall),
          const SizedBox(height: 8),
          for (final e in values.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 130, child: Text(e.key, style: t.bodySmall)),
                Expanded(
                  child: SelectableText(
                    (e.value == null || e.value == '') ? '—' : '${e.value}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  ),
                ),
              ]),
            ),
          if (footer != null) ...[const SizedBox(height: 6), Text(footer!, style: t.labelSmall)],
        ]),
      ),
    );
  }
}

// --- Wi-Fi -----------------------------------------------------------------

class _WifiTab extends StatefulWidget {
  const _WifiTab();

  @override
  State<_WifiTab> createState() => _WifiTabState();
}

class _WifiTabState extends State<_WifiTab> {
  final _ssid = TextEditingController();
  final _pass = TextEditingController();
  bool _obscure = true;
  bool _sending = false;

  @override
  void dispose() {
    _ssid.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<DeviceSession>();
    final wifi = (s.status?['wifi'] as Map?) ?? const {};
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: ListTile(
          leading: Icon(wifi['connected'] == true ? Icons.wifi : Icons.wifi_off,
              color: wifi['connected'] == true ? Colors.green : Colors.grey),
          title: Text(wifi['ssid'] as String? ?? 'No network configured'),
          subtitle: Text(wifi['connected'] == true ? '${wifi['ip']} · ${wifi['rssi']} dBm' : 'Not connected'),
        ),
      ),
      const SizedBox(height: 16),
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
      const Text('The password goes only to the module; it is not stored on the server or this tablet.', style: TextStyle(fontSize: 12)),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _sending
            ? null
            : () async {
                if (_ssid.text.trim().isEmpty) return;
                setState(() => _sending = true);
                final err = await s.setWifi(_ssid.text.trim(), _pass.text);
                if (!context.mounted) return;
                setState(() => _sending = false);
                _pass.clear();
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(err ?? 'Sent. Connection status will appear above in a few seconds.')));
              },
        child: Text(_sending ? 'Sending...' : 'Set Wi-Fi'),
      ),
    ]);
  }
}

// --- Fonksiyonlar (UART kayıt / oynatma) -------------------------------------

class _FunctionsTab extends StatelessWidget {
  const _FunctionsTab();

  static const _dirColors = {1: Colors.orange, 2: Colors.cyan, 3: Colors.green, 4: Colors.purple};

  @override
  Widget build(BuildContext context) {
    final s = context.watch<DeviceSession>();
    final rec = s.recording;
    return ListView(padding: const EdgeInsets.all(12), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('UART traffic', style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              const Text('Monitor'),
              Switch(value: s.sniffing, onChanged: rec != null ? null : (v) => _report(context, s.setSniff(v))),
              IconButton(tooltip: 'Clear', onPressed: s.clearTraffic, icon: const Icon(Icons.delete_sweep_outlined)),
            ]),
            Container(
              height: 220,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: const Color(0xFF0F172A), borderRadius: BorderRadius.circular(8)),
              child: s.traffic.isEmpty
                  ? const Center(child: Text('No traffic', style: TextStyle(color: Colors.white54)))
                  : ListView.builder(
                      reverse: true,
                      itemCount: s.traffic.length,
                      itemBuilder: (_, i) {
                        final p = s.traffic[s.traffic.length - 1 - i];
                        return Text.rich(
                          TextSpan(children: [
                            TextSpan(
                              text: '${p.directionLabel.padRight(9)} ',
                              style: TextStyle(color: _dirColors[p.direction] ?? Colors.white),
                            ),
                            TextSpan(text: p.hex, style: const TextStyle(color: Colors.white70)),
                          ]),
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              if (rec == null)
                FilledButton.icon(
                  onPressed: s.playing != null ? null : () => _report(context, s.startRecording()),
                  icon: const Icon(Icons.fiber_manual_record),
                  label: const Text('Start recording'),
                )
              else ...[
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () async {
                    final name = await _askName(context, rec.length);
                    await s.stopRecording(name);
                  },
                  icon: const Icon(Icons.stop),
                  label: Text('Stop (${rec.length})'),
                ),
              ],
              const Spacer(),
              TextButton.icon(
                onPressed: () => _manualInject(context, s),
                icon: const Icon(Icons.send),
                label: const Text('Send manually'),
              ),
            ]),
          ]),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Row(children: [
          Text('Saved functions (${s.functions.length})', style: Theme.of(context).textTheme.titleSmall),
          const Spacer(),
          PopupMenuButton<String>(
            onSelected: (v) => v == 'import' ? _import(context, s) : _export(context, s),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'import', child: Text('Import from clipboard')),
              PopupMenuItem(value: 'export', child: Text('Export to clipboard')),
            ],
          ),
        ]),
      ),
      if (s.functions.isEmpty)
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('No recordings. Record while performing an action on the device, then replay it here.'),
        ),
      for (final f in s.functions)
        Card(
          child: ListTile(
            leading: s.playing == f.name
                ? SizedBox(width: 28, height: 28, child: CircularProgressIndicator(value: s.playProgress, strokeWidth: 3))
                : const Icon(Icons.smart_button),
            title: Text(f.name),
            subtitle: Text('${f.packets.length} packets · ${(f.duration.inMilliseconds / 1000).toStringAsFixed(1)} s'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (s.playing == f.name)
                IconButton(onPressed: s.stopPlay, icon: const Icon(Icons.stop))
              else
                IconButton(
                  onPressed: s.playing != null || rec != null ? null : () => s.play(f),
                  icon: const Icon(Icons.play_arrow),
                ),
              IconButton(
                onPressed: s.playing != null
                    ? null
                    : () async {
                        if (await _confirm(context, 'Delete "${f.name}"?')) await s.deleteFunction(f);
                      },
                icon: const Icon(Icons.delete_outline),
              ),
            ]),
          ),
        ),
    ]);
  }

  Future<void> _report(BuildContext context, Future<String?> op) async {
    final err = await op;
    if (err != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
  }

  Future<String?> _askName(BuildContext context, int count) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Save recording ($count packets)'),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Function name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Discard')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim().isEmpty ? 'Function ${DateTime.now()}' : ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _manualInject(BuildContext context, DeviceSession s) async {
    final ctrl = TextEditingController();
    var target = 'dwin';
    final send = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Send UART frame'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'dwin', label: Text('→ DWIN')),
                ButtonSegment(value: 'mb', label: Text('→ Mainboard')),
              ],
              selected: {target},
              onSelectionChanged: (v) => setLocal(() => target = v.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: 'Hex', hintText: '5A A5 05 82 10 00 00 01'),
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
          ],
        ),
      ),
    );
    if (send != true || !context.mounted) return;
    try {
      await _report(context, s.inject(target, hexToBytes(ctrl.text)));
    } on FormatException {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid hex')));
    }
  }

  Future<void> _import(BuildContext context, DeviceSession s) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!context.mounted) return;
    try {
      final n = await s.importFunctions(data?.text ?? '');
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n function(s) imported')));
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Clipboard text is not function JSON')));
    }
  }

  Future<void> _export(BuildContext context, DeviceSession s) async {
    await Clipboard.setData(ClipboardData(text: s.exportFunctions()));
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied to clipboard')));
  }
}

Future<bool> _confirm(BuildContext context, String text) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
        ],
      ),
    ) ??
    false;
