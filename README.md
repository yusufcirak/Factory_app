# Zemits Control (factory_app)

Personel için Android uygulaması: ESP32 ara modülüne ilk kodu yükler, cihazı kaydeder ve
Bluetooth ile cihaz verilerini gösterir. Müşteriye verilmez.

Sözleşmeler: [docs/factory_provisioning.md](../docs/factory_provisioning.md) (fabrika),
[docs/customer_ble_setup.md](../docs/customer_ble_setup.md) (müşteri kurulumu).

## Kurulum

Uygulamada ayar ekranı yoktur; her şey derlemede gömülüdür ([lib/config.dart](lib/config.dart)):

- Tablet → Device Service: `https://vps01.zemits.ai:8443` (DNS gelince `https://device.zemits.ai`)
- Modüle yazılan: `https://device.zemits.ai`, `mqtts://device.zemits.ai:8883`
- İstasyon jetonu: derlemede verilir, kaynak koda yazılmaz:
  `flutter build apk --dart-define=STATION_TOKEN=zst_...`
  (admin panelinde istasyon oluşturulunca bir kez gösterilir; sızarsa istasyon devre dışı
  bırakılıp yeni APK çıkarılır)
- Operatör: denetim kaydına `Zemits Control` yazılır.

Açılışta "Kod yükleme" sekmesinin üstündeki **Sunucu** kartı bağlantıyı ve her modelin
sunucudaki güncel ESP sürümünü gösterir.

Sunucuda önceden hazır olması gerekenler (admin paneli):
- **Model**: id, ad ("Zemits Dermeluxx Ultra"), GTIN (`00860013757588`)
- **Seri no kataloğu**: etiketteki seri (ör. `20250007`) ve modeli
- **ESP paketi**: `zemits_module-<sürüm>.bin` (yalnız uygulama imajı, birleşik değil), yayında

## Bölüm 1 — Kod yükleme

Telefon/tablet USB OTG kablosuyla modüle takılır.

| Adım | Ne olur |
|---|---|
| Etiket | Kamerayla GS1 barkodu okunur ya da elle girilir → GTIN, üretim tarihi, lot, seri no. Model GTIN'den otomatik seçilir. |
| Firmware | Sunucudaki modele uygun ESP paketleri listelenir, önerilen seçili gelir. |
| İndir ve doğrula | `.bin` sunucudan indirilir, SHA-256 doğrulanır (aynı dosya önbellekten tekrar kullanılır). |
| USB ile yükle | ROM bootloader'a girilir, MAC okunur (modül kimliği `ZM` + MAC). Uygulamada gömülü bootloader (0x1000), bölüm tablosu (0x8000), boot_app0 (0xE000) ve indirilen uygulama (0x10000) yazılır, her bölge MD5 ile doğrulanır. NVS silinmez: modülün kimlik anahtarı korunur. |
| Bluetooth | Modül açılınca adı MAC'ten türetilen cihaz aranır (yan yana iki cihaz karışmaz), `info` okunur, imaj özeti yüklenen dosyayla karşılaştırılır. |
| Seri no ve model | Seri no, model, GTIN, lot, üretim tarihi, model adı, sunucu anahtarı ve sunucu adresleri modüle yazılır. |
| Kayıt | Device Service'e `POST /factory/v1/registrations`. Seri katalogda yoksa ya da etiket bilgisi katalogla çelişirse durur. |
| Öz test | Modül UART, DWIN, BLE, ESP-NOW, sunucu anahtarı kontrollerini yapar; sonuç sunucuya gönderilir. |
| Üretimi tamamla | `finalize`: modül Wi-Fi/lokasyonu siler, kullanıcı moduna geçip yeniden başlar. Fabrika Bluetooth servisi bir daha açılmaz. |

Bir adım hata verirse akış durur; **Kaldığı yerden devam** aynı adımdan sürdürür. Modül
başka bir seriye bağlıysa **Yeniden kayıt** gerekçe ister (denetim kaydına yazılır).
**Firmware yüklü — yalnız kayıt yap** anahtarı USB adımlarını atlar, cihaz Bluetooth listesinden seçilir.

## Uygulama yapısı (arayüz İngilizce)

**Manufacturing**
- **Setup** — yukarıdaki kod yükleme akışı.
- **Bench** — üretim modundaki modül (`ZM…`): canlı veriler, Wi-Fi, öz test, fonksiyon tekrarı
  (ekran ↔ anakart UART trafiğini izleme, kaydetme, oynatma; ZemitsProviderAPP biçimi).

**Provider** — sağlayıcı tarafı, tek akış:
1. **Set up new device** → kurulum modundaki cihaz (`Zemits-XXXXXX`) Bluetooth ile bulunur.
2. INFO okunur, modül anahtarı sunucudaki kayıtla karşılaştırılır, şifreli oturum kurulur.
3. Wi-Fi ağı seçilir, parola girilir (parola yalnız cihaza gider).
4. Cihaz Wi-Fi ve sunucuya bağlanınca (`wifi: connected` + `cloud: true`) Bluetooth kapanır,
   seri no (ESP32'den) listeye eklenir ve cihaz sayfası açılır.
5. Bundan sonra bütün veriler **sunucudan** gelir: bağlantı, sürümler, güncellemeler, kullanım.
   Elle seri no ekleme yoktur.

Provider verileri `/factory/v1/devices/*` uçlarından gelir (demo; sunucuda
`FACTORY_DEVICE_DATA=false` ile kapatılır).

## Bilinen sınırlar (şu an)

- Gerçek modül ve tabletle uçtan uca henüz denenmedi.
- Bluetooth `wifi` ve `inject` komutları üretim modunda kimlik doğrulaması istemez; `finalize`
  sonrası bu servis kapandığı için kabul edildi (D1 kararı açık).
- `device.zemits.ai` DNS'e girene kadar modüller sunucuya bağlanamaz (modüle kalıcı adres yazılır).

## Geliştirme

```
flutter test                 # GS1 ayrıştırıcı + oturum kriptografisi (firmware vektörleriyle)
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

USB yükleyici Kotlin'dedir (`android/app/src/main/kotlin/.../usb/`, Sketch32'den), Dart'a
`zemits/usb` MethodChannel ile bağlanır.
