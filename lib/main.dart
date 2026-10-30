import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/factory_api.dart';
import 'services/station_auth.dart';
import 'state/customer_session.dart';
import 'state/device_session.dart';
import 'state/provider_devices.dart';
import 'state/setup_flow.dart';
import 'ui/enrollment_page.dart';
import 'ui/manufacturing_section.dart';
import 'ui/provider_section.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final auth = StationAuth()..init();
  final api = FactoryApi(auth);
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: auth),
      Provider.value(value: api),
      ChangeNotifierProvider(create: (_) => SetupFlow(api)),
      ChangeNotifierProvider(create: (_) => DeviceSession(api)..loadFunctions()),
      ChangeNotifierProvider(create: (_) => CustomerSession(api)),
      ChangeNotifierProvider(create: (_) => ProviderDevices(api)),
    ],
    child: const ZemitsFactoryApp(),
  ));
}

/// Zemits marka laciverti (ZemitsProviderAPP ikon zemini).
const zemitsNavy = Color(0xFF003366);

class ZemitsFactoryApp extends StatelessWidget {
  const ZemitsFactoryApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: zemitsNavy, brightness: b),
          cardTheme: CardThemeData(elevation: 0, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder()),
        );
    return MaterialApp(
      title: 'Zemits Control',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      // Tablet istasyon olarak onaylanana kadar kod ekranı (FACTORY_API.md "İstasyon kaydı").
      home: Consumer<StationAuth>(builder: (_, a, _) => a.ready ? const HomeShell() : const EnrollmentPage()),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// İki bölüm: Manufacturing (üretim hattı) ve Provider (sağlayıcı tarafı kurulum ve cihaz verileri).
class _HomeShellState extends State<HomeShell> {
  int _section = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.asset('assets/images/app_icon.jpg', height: 32),
          ),
          const SizedBox(width: 10),
          Text(_section == 0 ? 'Manufacturing' : 'Provider'),
        ]),
      ),
      body: IndexedStack(index: _section, children: const [ManufacturingSection(), ProviderSection()]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _section,
        onDestinationSelected: (i) => setState(() => _section = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.precision_manufacturing_outlined), label: 'Manufacturing'),
          NavigationDestination(icon: Icon(Icons.storefront_outlined), label: 'Provider'),
        ],
      ),
    );
  }
}
