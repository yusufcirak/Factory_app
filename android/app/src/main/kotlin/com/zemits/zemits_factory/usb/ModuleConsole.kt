package com.zemits.zemits_factory.usb

import com.hoho.android.usbserial.driver.UsbSerialPort
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONObject

/**
 * Modülün seri konsolu (115200 8N1, zemits_module/console.h).
 *
 * Makine yanıtları tek satır JSON olarak '@' ile başlar; diğer satırlar logdur.
 * Yüklemeden sonra kullanılır: aynı karta ikinci kez yükleme yapılırsa NVS silinmediği
 * için kart "üretim tamamlandı" durumunda açılır ve fabrika BLE servisi başlamaz;
 * `production reset` bayrağı kaldırır (kimlik, seri no, GS1 alanları korunur).
 */
class ModuleConsole(private val port: UsbSerialPort, private val onLog: (String) -> Unit) {

    private val line = ByteArrayOutputStream()

    /** Kartı normal açılışa resetler (DTR bırakık: GPIO0 yüksek → uygulama). */
    suspend fun reset() {
        port.dtr = false
        port.rts = true
        delay(100)
        port.rts = false
    }

    /**
     * Kart açılana kadar `info` gönderir; ilk geçerli yanıtı döner.
     * Açılış ~1 sn; log satırının metnine bağlı kalmamak için yanıtın kendisi beklenir.
     */
    suspend fun waitForInfo(timeoutMs: Long = 10_000): JSONObject = withContext(Dispatchers.IO) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            send("info")
            val r = readReply(700)
            if (r != null && r.has("moduleId")) return@withContext r
        }
        throw UsbException("The module did not answer on the serial console after flashing.")
    }

    /** Komutu gönderir, '@' ile başlayan ilk yanıtı bekler. */
    suspend fun request(command: String, timeoutMs: Long = 3_000): JSONObject = withContext(Dispatchers.IO) {
        // Port bir süre kapalı kaldıysa tamponda eski/bozuk çıktı olabilir (firmware_mobile_changes.md).
        SerialIo.drain(port)
        line.reset()
        send(command)
        readReply(timeoutMs) ?: throw UsbException("The module did not answer \"$command\".")
    }

    private fun send(command: String) {
        port.write("$command\n".toByteArray(), 1000)
    }

    /** '@{…}' satırını bekler; log satırlarını [onLog]'a aktarır. */
    private fun readReply(timeoutMs: Long): JSONObject? {
        val deadline = System.currentTimeMillis() + timeoutMs
        val buf = ByteArray(256)
        while (System.currentTimeMillis() < deadline) {
            val n = SerialIo.read(port, buf, 50)
            for (i in 0 until n) {
                val b = buf[i]
                if (b == '\n'.code.toByte()) {
                    val text = line.toString(Charsets.UTF_8.name()).trimEnd('\r')
                    line.reset()
                    // Yanıtın önüne bozuk bayt yapışmış olabilir: "@{" satırın ortasında da aranır.
                    val at = text.indexOf("@{")
                    if (at >= 0) {
                        runCatching { return JSONObject(text.substring(at + 1)) }
                    } else if (text.isNotBlank()) {
                        onLog("  module: $text")
                    }
                } else if (line.size() < 4096) {
                    line.write(b.toInt())
                }
            }
        }
        return null
    }
}
