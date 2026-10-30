import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/gs1.dart';

/// Kamerayla GS1 etiketini okur; geçerli bir etiket bulunca [Gs1Label] ile kapanır.
class LabelScanPage extends StatefulWidget {
  const LabelScanPage({super.key});

  @override
  State<LabelScanPage> createState() => _LabelScanPageState();
}

class _LabelScanPageState extends State<LabelScanPage> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.code128, BarcodeFormat.dataMatrix, BarcodeFormat.qrCode],
  );
  String? _lastError;
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      try {
        final label = parseGs1(raw);
        if (!label.isComplete) {
          setState(() => _lastError = 'Missing GTIN (01) or serial (21): $raw');
          continue;
        }
        _done = true;
        Navigator.of(context).pop(label);
        return;
      } on Gs1FormatException catch (e) {
        setState(() => _lastError = e.message);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan label')),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Align(
            alignment: Alignment.center,
            child: Container(
              width: MediaQuery.of(context).size.width * 0.85,
              height: 120,
              decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 2), borderRadius: BorderRadius.circular(8)),
            ),
          ),
          if (_lastError != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: Material(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_lastError!, style: const TextStyle(color: Colors.white)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
