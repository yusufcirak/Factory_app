import 'package:flutter/material.dart';

import 'provider_devices_page.dart';

/// Provider: ilk kurulum Bluetooth ile (Wi-Fi bilgisi); sonra cihaz Wi-Fi ile sunucuya
/// bağlanır ve bütün veriler sunucudan gelir. Kurulum sihirbazı cihaz listesinden açılır.
class ProviderSection extends StatelessWidget {
  const ProviderSection({super.key});

  @override
  Widget build(BuildContext context) => const ProviderDevicesPage();
}
