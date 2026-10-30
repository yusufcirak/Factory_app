import 'package:flutter/material.dart';

import 'bench_page.dart';
import 'setup_page.dart';

/// Manufacturing: üretim hattı — Setup (kod yükleme, kayıt, öz test) ve
/// Bench (üretim modundaki modülün BLE araçları).
class ManufacturingSection extends StatelessWidget {
  const ManufacturingSection({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: Column(children: [
        TabBar(tabs: [
          Tab(icon: Icon(Icons.system_update_alt), text: 'Setup'),
          Tab(icon: Icon(Icons.build_outlined), text: 'Bench'),
        ]),
        Expanded(child: TabBarView(children: [SetupPage(), BenchPage()])),
      ]),
    );
  }
}
