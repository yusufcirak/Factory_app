import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/factory_api.dart';

/// Sunucudan Wi-Fi değiştirmenin sonucu.
enum WifiChangeResult { done, useBluetooth, cancelled }

/// Cihaz Wi-Fi ile çevrimiçiyken yeni ağ BLE'siz, sunucu üzerinden gönderilir (MOBILE_API.md).
/// Şifre karta yalnız onun açabileceği şekilde şifreli gider; burada loglanmaz.
/// Cihaz çevrimdışı çıkarsa `useBluetooth` döner ve mevcut BLE akışı açılır.
Future<WifiChangeResult> showWifiChangeDialog(BuildContext context, String serial, {String? currentSsid}) async =>
    await showDialog<WifiChangeResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WifiChangeDialog(serial: serial, currentSsid: currentSsid),
    ) ??
    WifiChangeResult.cancelled;

class _WifiChangeDialog extends StatefulWidget {
  final String serial;
  final String? currentSsid;
  const _WifiChangeDialog({required this.serial, this.currentSsid});

  @override
  State<_WifiChangeDialog> createState() => _WifiChangeDialogState();
}

class _WifiChangeDialogState extends State<_WifiChangeDialog> {
  final _ssid = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  String? _formError;

  String? _requestId;
  String? _stage;
  String? _failure;
  bool _ok = false;
  Timer? _poll;
  late DateTime _deadline;

  @override
  void dispose() {
    _poll?.cancel();
    _ssid.dispose();
    _password.dispose();
    super.dispose();
  }

  bool get _running => _requestId != null && !_ok && _failure == null;

  String? _validate() {
    final s = utf8.encode(_ssid.text);
    if (s.isEmpty || s.length > 32) return 'Network name must be 1–32 bytes.';
    final p = _password.text.length;
    if (p != 0 && (p < 8 || p > 63)) return 'Password must be 8–63 characters (empty for an open network).';
    return null;
  }

  Future<void> _submit() async {
    final err = _validate();
    if (err != null) return setState(() => _formError = err);
    final api = context.read<FactoryApi>();
    setState(() {
      _formError = null;
      _stage = 'sent';
    });
    try {
      final r = await api.setWifi(widget.serial, _ssid.text, _password.text);
      _requestId = r['requestId'] as String?;
    } on ApiException catch (e) {
      if (!mounted) return;
      switch (e.code) {
        case 'DEVICE_OFFLINE':
          Navigator.of(context).pop(WifiChangeResult.useBluetooth);
          return;
        case 'SETUP_IN_PROGRESS':
          // Açık istek izlenir, yeni istek açılmaz.
          _requestId = (e.details as Map?)?['requestId'] as String?;
        default:
          return setState(() {
            _stage = null;
            _formError = e.status == 404
                ? 'The server does not support this yet. Use Bluetooth.'
                : (e.message.isEmpty ? e.code : e.message);
          });
      }
    }
    if (!mounted) return;
    if (_requestId == null) return setState(() => _failure = 'The server did not return a request.');
    _deadline = DateTime.now().add(const Duration(minutes: 5));
    setState(() {});
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
  }

  Future<void> _check() async {
    if (!mounted || !_running) return;
    if (DateTime.now().isAfter(_deadline)) {
      _poll?.cancel();
      return setState(() => _failure = 'No result from the device. Check its connection and try again.');
    }
    try {
      final st = await context.read<FactoryApi>().wifiStatus(widget.serial, _requestId!);
      if (!mounted) return;
      final stage = st['stage'] as String?;
      String? fail;
      switch (stage) {
        case 'cloud_ok':
          _poll?.cancel();
          return setState(() {
            _stage = stage;
            _ok = true;
          });
        case 'wifi_failed':
          final back = st['fellBackTo'] as String?;
          fail = '${switch (st['reason']) {
            'wrong_password' => 'Wrong password.',
            'network_not_found' => 'Network not found.',
            _ => 'The new Wi-Fi did not work.',
          }} ${back != null ? 'The device is still working on "$back".' : 'The device kept its previous network.'}';
        case 'rejected':
          fail = switch (st['reason']) {
            'busy' => 'The device is already in another setup. Try again in a few minutes.',
            'busy_updating' => 'The device is installing an update. Try again when it finishes.',
            'production_mode' => 'The device is still in production mode.',
            'decrypt_failed' => 'The device could not read the request. Try again.',
            'expired' => 'The request expired before the device received it. Try again.',
            final r => 'The device refused the change (${r ?? 'unknown reason'}).',
          };
        case 'not_acknowledged':
          fail = 'The device did not respond. It may have gone offline — use Bluetooth next to the device.';
      }
      _stage = stage;
      if (fail != null) {
        _poll?.cancel();
        _failure = fail;
      }
      setState(() {});
    } catch (_) {
      // ağ kesintisi: sonraki turda tekrar
    }
  }

  String get _stageText => switch (_stage) {
        'sent' => 'Sending to the device...',
        'accepted' => 'The device is joining the new network. It may look offline for a moment.',
        'wifi_ok' => 'Joined the network, connecting to the server...',
        _ => 'Waiting for the device...',
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final List<Widget> body;
    final List<Widget> actions;
    if (_ok) {
      body = [
        Icon(Icons.check_circle, color: cs.primary, size: 40),
        const SizedBox(height: 8),
        Text('The device is online on "${_ssid.text}".'),
      ];
      actions = [FilledButton(onPressed: () => Navigator.pop(context, WifiChangeResult.done), child: const Text('Done'))];
    } else if (_failure != null) {
      body = [
        Icon(Icons.error_outline, color: cs.error, size: 40),
        const SizedBox(height: 8),
        Text(_failure!),
      ];
      actions = [
        TextButton(
            onPressed: () => Navigator.pop(context, WifiChangeResult.useBluetooth),
            child: const Text('Use Bluetooth')),
        FilledButton(
            onPressed: () => setState(() {
                  _requestId = null;
                  _stage = null;
                  _failure = null;
                }),
            child: const Text('Try again')),
      ];
    } else if (_stage != null) {
      body = [
        const LinearProgressIndicator(),
        const SizedBox(height: 12),
        Text(_stageText),
      ];
      actions = [];
    } else {
      body = [
        if (widget.currentSsid != null) Text('Current network: ${widget.currentSsid}'),
        const SizedBox(height: 8),
        TextField(
          controller: _ssid,
          decoration: const InputDecoration(labelText: 'Network name (SSID)'),
          autocorrect: false,
        ),
        TextField(
          controller: _password,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Password',
            suffixIcon: IconButton(
              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        if (_formError != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_formError!, style: TextStyle(color: cs.error)),
          ),
      ];
      actions = [
        TextButton(onPressed: () => Navigator.pop(context, WifiChangeResult.cancelled), child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(context, WifiChangeResult.useBluetooth),
            child: const Text('Use Bluetooth')),
        FilledButton(onPressed: _submit, child: const Text('Change')),
      ];
    }
    return AlertDialog(
      title: const Text('Change Wi-Fi'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: body),
      ),
      actions: actions,
    );
  }
}
