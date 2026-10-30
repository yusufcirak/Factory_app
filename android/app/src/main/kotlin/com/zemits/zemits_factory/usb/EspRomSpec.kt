package com.zemits.zemits_factory.usb

/**
 * ROM yükleyicisiyle yazma ayarları. Sketch32'deki `UploadSpec.EspRom`'un
 * bu uygulamada gereken kısmı: tek hedef ESP32-WROOM-32D (4 MB).
 */
data class EspRomSpec(
    val chip: String = "esp32",
    val baudRate: Int = 921_600,
    val flashSizeBytes: Int = 4 * 1024 * 1024,
)
