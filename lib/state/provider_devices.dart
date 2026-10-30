import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/factory_api.dart';

/// Provider bölümü: seçili sağlayıcının cihazları sunucudan gelir (Provider app'teki
/// Device Hub'ın karşılığı). Sahiplik admin panelinden atanır; tablet değiştiremez.
class ProviderDevices extends ChangeNotifier {
  static const _kProvider = 'provider_id';

  final FactoryApi api;
  ProviderDevices(this.api);

  List<Map<String, dynamic>> providers = [];
  String? providerId;
  List<Map<String, dynamic>> devices = [];

  /// Bu sağlayıcının cihazlarının yakında duyduğu, sahipsiz kayıtlı cihazlar (§8).
  List<Map<String, dynamic>> nearby = [];
  bool loading = false;
  String? error;
  DateTime? updatedAt;
  Timer? _poll;

  Map<String, dynamic>? get provider => providers.where((p) => p['id'] == providerId).firstOrNull;

  /// Cihazın bu sağlayıcıya geçtiği an (devir kuralı §6.2: öncesi gösterilmez).
  DateTime? ownedSince(String serial) => DateTime.tryParse(
      devices.where((d) => d['serial'] == serial).firstOrNull?['ownedSince'] as String? ?? '');

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    providerId = prefs.getString(_kProvider);
    try {
      providers = await api.providers();
      if (providerId == null || provider == null) providerId = providers.firstOrNull?['id'] as String?;
      error = null;
    } catch (e) {
      error = e.toString();
    }
    notifyListeners();
    await refresh();
  }

  Future<void> selectProvider(String id) async {
    providerId = id;
    devices = [];
    nearby = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kProvider, id);
    notifyListeners();
    await refresh();
  }

  /// Sekme görünürken 15 sn'de bir yenile.
  void startPolling() {
    _poll ??= Timer.periodic(const Duration(seconds: 15), (_) => refresh(quiet: true));
  }

  void stopPolling() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> refresh({bool quiet = false}) async {
    if (providerId == null || loading) return;
    loading = true;
    if (!quiet) notifyListeners();
    try {
      devices = await api.providerDevices(providerId!);
      error = null;
      try {
        nearby = await api.nearbyUnclaimed(providerId!);
      } catch (_) {
        nearby = []; // sunucu bu özelliği vermiyorsa uyarı gösterilmez
      }
      updatedAt = DateTime.now();
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}
