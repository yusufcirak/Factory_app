import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/gs1.dart';
import '../services/factory_api.dart';
import '../services/zm_ble.dart';
import '../state/setup_flow.dart';
import 'ble_picker.dart';
import 'label_scan_page.dart';

/// Bölüm 1 — kod yükleme: etiket → model → firmware → USB yükleme → BLE ile
/// kimlik/seri yazma → Device Service kaydı → öz test.
class SetupPage extends StatefulWidget {
  const SetupPage({super.key});

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  @override
  void initState() {
    super.initState();
    final flow = context.read<SetupFlow>();
    flow.loadModels();
    flow.refreshUsb();
  }

  Future<void> _scanLabel() async {
    final label = await Navigator.of(context).push<Gs1Label>(MaterialPageRoute(builder: (_) => const LabelScanPage()));
    if (label != null && mounted) context.read<SetupFlow>().setLabel(label);
  }

  Future<void> _manualLabel() async {
    final ctrl = TextEditingController();
    final label = await showDialog<Gs1Label>(
      context: context,
      builder: (ctx) {
        String? err;
        return StatefulBuilder(
          builder: (ctx, setLocal) => AlertDialog(
            title: const Text('Enter label manually'),
            content: TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '(01)00860013757588(11)260901(10)1754(21)20250007',
                errorText: err,
                errorMaxLines: 3,
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  try {
                    final l = parseGs1(ctrl.text);
                    if (!l.isComplete) throw Gs1FormatException('(01) GTIN and (21) serial number are required.');
                    Navigator.pop(ctx, l);
                  } on Gs1FormatException catch (e) {
                    setLocal(() => err = e.message);
                  }
                },
                child: const Text('OK'),
              ),
            ],
          ),
        );
      },
    );
    if (label != null && mounted) context.read<SetupFlow>().setLabel(label);
  }

  /// Yüklemeden sonra BLE gerekecek: Bluetooth kapalıysa baştan uyar (yükleme bitince değil).
  Future<void> _start(SetupFlow flow) async {
    if (!await ZmBle.ensureBluetoothOn()) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.bluetooth_disabled),
          title: const Text('Turn on Bluetooth'),
          content: const Text('After flashing, the app connects to the module over Bluetooth. '
              'Turn on Bluetooth on this phone, then tap Start again.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
      return;
    }
    await flow.run();
  }

  Future<void> _pickPreflashed(SetupFlow flow, bool on) async {
    if (!on) return flow.setSkipFlash(false);
    final dev = await pickBleDevice(context);
    if (dev != null) flow.setSkipFlash(true, moduleId: dev.name ?? dev.rawName);
  }

  Future<void> _reRegister(SetupFlow flow) async {
    final ctrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Re-register'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Reason (written to the audit log)', hintText: 'Module faulty, replaced'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => ctrl.text.trim().length >= 3 ? Navigator.pop(ctx, ctrl.text.trim()) : null,
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (reason != null) await flow.run(reRegisterReason: reason);
  }

  @override
  Widget build(BuildContext context) {
    final flow = context.watch<SetupFlow>();
    final locked = flow.busy || flow.status.values.any((s) => s == StepStatus.done);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _ServerCard(flow: flow),
        _section(
          context,
          icon: Icons.qr_code_scanner,
          title: 'Device label',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (flow.label != null) _LabelView(flow.label!),
              Wrap(spacing: 8, children: [
                FilledButton.tonalIcon(
                  onPressed: locked ? null : _scanLabel,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Scan with camera'),
                ),
                OutlinedButton.icon(
                  onPressed: locked ? null : _manualLabel,
                  icon: const Icon(Icons.keyboard),
                  label: const Text('Enter manually'),
                ),
              ]),
            ],
          ),
        ),
        _section(
          context,
          icon: Icons.devices_other,
          title: 'Model and firmware',
          child: Column(children: [
            DropdownButtonFormField<String>(
              initialValue: flow.model?.id,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Device model',
                helperText: flow.models.isEmpty ? 'No models loaded from the server' : null,
              ),
              items: [
                for (final m in flow.models)
                  DropdownMenuItem(value: m.id, child: Text(m.gtin == null ? m.name : '${m.name}  ·  ${m.gtin}')),
              ],
              onChanged: locked ? null : (id) => flow.selectModel(flow.models.firstWhere((m) => m.id == id)),
            ),
            if (flow.label?.gtin != null && flow.model != null && flow.model!.gtin != null && flow.model!.gtin != flow.label!.gtin)
              const _Warn('The label GTIN differs from the selected model.'),
            const SizedBox(height: 8),
            if (flow.loadingFirmware) const LinearProgressIndicator(),
            if (flow.firmware != null && !flow.skipFlash)
              DropdownButtonFormField<String>(
                initialValue: flow.package?.packageId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'ESP firmware package'),
                items: [
                  for (final p in flow.firmware!.packages)
                    DropdownMenuItem(
                      value: p.packageId,
                      child: Text('${p.version}  ·  ${p.rolloutStage}'
                          '${identical(p, flow.firmware!.recommended) ? '  (recommended)' : ''}'),
                    ),
                ],
                onChanged: locked
                    ? null
                    : (id) => flow.selectPackage(flow.firmware!.packages.firstWhere((p) => p.packageId == id)),
              ),
          ]),
        ),
        _section(
          context,
          icon: Icons.usb,
          title: 'Connection',
          child: Column(children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Firmware already flashed — register only'),
              subtitle: Text(flow.skipFlash ? 'Module: ${flow.manualModuleId}' : 'Will flash over USB'),
              value: flow.skipFlash,
              onChanged: locked ? null : (v) => _pickPreflashed(flow, v),
            ),
            if (!flow.skipFlash)
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: flow.usbDevice?.deviceId,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'USB serial device',
                      helperText: flow.usbDevices.isEmpty ? 'No USB device — connect the module and tap refresh' : null,
                    ),
                    items: [
                      for (final d in flow.usbDevices) DropdownMenuItem(value: d.deviceId, child: Text(d.label)),
                    ],
                    onChanged: locked ? null : (id) => flow.selectUsb(flow.usbDevices.firstWhere((d) => d.deviceId == id)),
                  ),
                ),
                IconButton(onPressed: locked ? null : flow.refreshUsb, icon: const Icon(Icons.refresh)),
              ]),
          ]),
        ),
        _section(
          context,
          icon: Icons.checklist,
          title: 'Steps',
          child: Column(children: [
            for (final s in SetupStep.values) _StepTile(step: s, flow: flow),
            if (flow.warning != null) _Warn(flow.warning!),
            if (flow.serialConflict != null && !flow.busy)
              _SerialConflictCard(flow: flow)
            else if (flow.error != null)
              _Warn(flow.error!, error: true),
            if (!flow.busy && !flow.finished && flow.error == null)
              for (final m in flow.missingRequirements) _Warn(m),
            const SizedBox(height: 12),
            Row(children: [
              if (flow.finished)
                Expanded(
                  child: FilledButton.icon(
                    onPressed: flow.reset,
                    icon: const Icon(Icons.navigate_next),
                    label: const Text('Next device'),
                  ),
                )
              else ...[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: flow.canRun ? () => _start(flow) : null,
                    icon: flow.busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.play_arrow),
                    label: Text(flow.error != null ? 'Resume' : 'Start'),
                  ),
                ),
                if (flow.needsReRegister) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: () => _reRegister(flow), child: const Text('Re-register')),
                ],
                if (!flow.busy && flow.error != null) ...[
                  const SizedBox(width: 8),
                  IconButton(tooltip: 'Start over', onPressed: flow.restartDevice, icon: const Icon(Icons.restart_alt)),
                ],
              ],
            ]),
          ]),
        ),
        if (flow.log.isNotEmpty)
          Card(
            child: ExpansionTile(
              title: const Text('Log'),
              children: [
                Container(
                  height: 220,
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  color: Colors.black,
                  child: SingleChildScrollView(
                    reverse: true,
                    child: Text(flow.log.join('\n'),
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.greenAccent)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _section(BuildContext context, {required IconData icon, required String title, required Widget child}) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
            ]),
            const SizedBox(height: 12),
            child,
          ]),
        ),
      );
}

class _LabelView extends StatelessWidget {
  final Gs1Label label;
  const _LabelView(this.label);

  @override
  Widget build(BuildContext context) {
    Widget row(String k, String? v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            SizedBox(width: 130, child: Text(k, style: Theme.of(context).textTheme.bodySmall)),
            Expanded(child: Text(v ?? '—', style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600))),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(children: [
        row('(21) Serial no.', label.serial),
        row('(01) GTIN', label.gtin),
        row('(11) Mfg. date', label.manufactureDate),
        row('(10) Lot', label.lot),
      ]),
    );
  }
}

class _StepTile extends StatelessWidget {
  final SetupStep step;
  final SetupFlow flow;
  const _StepTile({required this.step, required this.flow});

  @override
  Widget build(BuildContext context) {
    final s = flow.status[step]!;
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (s) {
      StepStatus.pending => Icon(Icons.radio_button_unchecked, color: scheme.outline),
      StepStatus.running => const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
      StepStatus.done => const Icon(Icons.check_circle, color: Colors.green),
      StepStatus.failed => Icon(Icons.error, color: scheme.error),
      StepStatus.skipped => Icon(Icons.remove_circle_outline, color: scheme.outline),
    };
    final showProgress = s == StepStatus.running && (step == SetupStep.download || step == SetupStep.flash);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: icon,
      title: Text(step.label),
      subtitle: showProgress
          ? Padding(
              padding: const EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(value: flow.progress > 0 ? flow.progress : null),
            )
          : (flow.details[step] == null ? null : Text(flow.details[step]!, style: const TextStyle(fontFamily: 'monospace'))),
    );
  }
}

class _Warn extends StatelessWidget {
  final String text;
  final bool error;
  const _Warn(this.text, {this.error = false});

  @override
  Widget build(BuildContext context) {
    final c = error ? Theme.of(context).colorScheme.error : Colors.orange;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        Icon(error ? Icons.error_outline : Icons.warning_amber, color: c, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ]),
    );
  }
}


/// Sunucu bağlantısı ve modellerin sunucudaki güncel ESP yazılım sürümleri.
class _ServerCard extends StatelessWidget {
  final SetupFlow flow;
  const _ServerCard({required this.flow});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final ok = flow.serverOk;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(ok == true ? Icons.cloud_done : (ok == false ? Icons.cloud_off : Icons.cloud_queue),
                color: ok == true ? Colors.green : (ok == false ? scheme.error : scheme.outline)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  ok == true ? 'Connected to server' : (ok == false ? 'Cannot reach server' : 'Connecting to server...'),
                  style: t.titleMedium),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: flow.serverLoading ? null : flow.loadModels,
              icon: flow.serverLoading
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
            ),
          ]),
          if (flow.serverError != null) Text(flow.serverError!, style: TextStyle(color: scheme.error)),
          if (ok == true && flow.models.isEmpty) const Text('No models defined on the server.'),
          if (ok == true)
            for (final m in flow.models)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(m.name, style: t.bodyLarge),
                      Text(m.gtin == null ? m.id : '${m.id} · GTIN ${m.gtin}', style: t.bodySmall),
                    ]),
                  ),
                  _VersionChip(flow.latestFirmware[m.id]),
                ]),
              ),
        ]),
      ),
    );
  }
}

class _VersionChip extends StatelessWidget {
  final FirmwarePackage? pkg;
  const _VersionChip(this.pkg);

  @override
  Widget build(BuildContext context) {
    if (pkg == null) return const Chip(label: Text('No firmware'));
    return Chip(
      avatar: const Icon(Icons.memory, size: 18),
      label: Text('ESP ${pkg!.version}${pkg!.rolloutStage == 'general' ? '' : ' · ${pkg!.rolloutStage}'}'),
    );
  }
}

/// "Bu modül zaten S/N X — Y olarak değiştirilsin mi?"
class _SerialConflictCard extends StatelessWidget {
  final SetupFlow flow;
  const _SerialConflictCard({required this.flow});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      color: scheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.swap_horiz, color: scheme.onTertiaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text('This module already has a serial number',
                  style: t.titleMedium?.copyWith(color: scheme.onTertiaryContainer)),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            'Stored in the module: S/N ${flow.serialConflict}\n'
            'Scanned label: S/N ${flow.label?.serial}\n\n'
            'Change the module to the scanned serial number? Its old registration is closed on the server.',
            style: TextStyle(color: scheme.onTertiaryContainer),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: FilledButton(
                onPressed: flow.approveSerialChange,
                child: Text('Change to ${flow.label?.serial}'),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: flow.declineSerialChange, child: const Text('Cancel')),
          ]),
        ]),
      ),
    );
  }
}
