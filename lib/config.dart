/// Sunucu adresleri — uygulamada sabit, kullanıcı değiştiremez.
/// Kaynak: device-service/docs/DEPLOY.md, docs/MOBILE_API.md.
class AppConfig {
  /// Tabletin konuştuğu Device Service (`/factory/v1`).
  static const apiBaseUrl = 'https://devices.zemits.ai';

  /// Provision sırasında modülün NVS'ine yazılan adresler (firmware 0.1.7 varsayılanıyla aynı).
  /// Sertifika devices.zemits.ai + vps01.zemits.ai adlarını taşır; vps01 adıyla kurulmuş
  /// modüller de çalışmaya devam eder.
  static const moduleHttpBase = 'https://devices.zemits.ai';
  static const moduleMqttUri = 'mqtts://devices.zemits.ai:8883';

  /// İstasyon jetonu (`zst_…`): derlemede verilir, kaynak koda yazılmaz.
  ///   flutter build apk --dart-define=STATION_TOKEN=zst_...
  /// Jeton sızarsa admin panelinden istasyon devre dışı bırakılıp yeni APK çıkarılır.
  static const stationToken = String.fromEnvironment('STATION_TOKEN');

  /// Kayıtta denetim günlüğüne yazılan operatör.
  static const operatorName = 'Zemits Control';
}
