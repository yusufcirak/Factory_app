package com.zemits.zemits_factory.usb

import com.hoho.android.usbserial.driver.UsbSerialPort
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * ESP32 ailesini ROM içindeki seri bootloader üzerinden programlar.
 *
 * esptool.py'nin yaptığı işin telefonda gerekli olan alt kümesi. Yükleme
 * "stub" olmadan, doğrudan ROM yükleyicisiyle yapılır: stub kullanmak daha
 * hızlıdır ama her yonga revizyonu için ayrı bir ikili gerektirir ve
 * bunları paketlemek APK'yı şişirir. ROM yolu her revizyonda çalışır.
 */
class EspLoader(
    private val port: UsbSerialPort,
    private val spec: EspRomSpec,
) {

    /**
     * @param images adres -> yazılacak dosya (bootloader, bölüm tablosu, uygulama)
     * @return yonganın fabrika MAC adresi (6 bayt) — modül kimliği bundan türer
     */
    suspend fun flash(
        images: Map<Int, File>,
        onProgress: (Double) -> Unit,
        onLog: (String) -> Unit,
        eraseAll: Boolean = false,
    ): ByteArray = withContext(Dispatchers.IO) {
        onLog("Putting the board into bootloader mode...")
        enterBootloader()

        onLog("Syncing...")
        synchronize(onLog)

        // MAC, yazmadan ÖNCE okunur: tablet BLE'de bu karta ait reklamı
        // (ad = "ZM" + MAC) arayacak, yan yana duran başka kartla karışmasın.
        val mac = readMac()
        onLog("MAC: " + mac.joinToString(":") { "%02X".format(it) })

        raiseBaudRate(onLog)

        // ESP32 dışındaki yongalarda ROM, flash yongasına bağlanmadan
        // yazma komutlarını reddeder.
        onLog("Attaching the flash chip...")
        command(CMD_SPI_ATTACH, ByteArray(8), timeoutMs = DEFAULT_TIMEOUT_MS)

        configureSpiParameters()

        if (eraseAll) eraseEntireFlash(onLog)

        val totalBytes = images.values.sumOf { it.length() }.toDouble()
        var writtenBytes = 0L

        // Adres sırasına göre yaz: bootloader önce gelirse, yazma yarıda
        // kesilse bile kart en azından bootloader'ıyla ayakta kalır.
        for ((address, file) in images.toSortedMap()) {
            val data = file.readBytes()
            onLog("Writing %s to 0x%05X (%d bytes)...".format(file.name, address, data.size))

            // Bölgeler arasında FLASH_END GÖNDERİLMEZ: ROM onu 0x106
            // ("mesaj geçerli ama sonuç yanlış") ile reddediyor. Ard arda
            // FLASH_BEGIN vermek doğru kullanım; esptool da böyle yapıyor
            // ve oturumu yalnızca en sonda kapatıyor.
            writeRegion(address, data, onLog) { regionWritten ->
                onProgress(((writtenBytes + regionWritten) / totalBytes).coerceIn(0.0, 1.0))
            }
            writtenBytes += data.size

            verifyMd5(address, data, onLog)
        }

        onLog("Restarting the board...")
        // flag=0: yüklemeyi bitir ve uygulamayı çalıştır (esptool'da
        // `int(not reboot)` — sezginin tersi).
        command(CMD_FLASH_END, le32(0), timeoutMs = DEFAULT_TIMEOUT_MS, expectResponse = false)
        hardReset()
        onLog("Upload complete.")
        mac
    }

    /**
     * Fabrika MAC'ini eFuse'tan okur (yalnız klasik ESP32).
     *
     * esptool `read_mac` ile aynı: BLK0 RDATA1 alt 32 bit, RDATA2'nin alt
     * 16 biti üst kısım. Sonuç `esp_efuse_mac_get_default` ile aynı sırada.
     */
    private fun readMac(): ByteArray {
        val chip = spec.chip.lowercase().filter { it.isLetterOrDigit() }
        if (chip != "esp32") throw UsbException("MAC read is only defined for ESP32 (chip: ${spec.chip}).")
        val mac0 = readReg(EFUSE_BLK0_RDATA1)
        val mac1 = readReg(EFUSE_BLK0_RDATA2)
        return byteArrayOf(
            (mac1 shr 8).toByte(), mac1.toByte(),
            (mac0 shr 24).toByte(), (mac0 shr 16).toByte(), (mac0 shr 8).toByte(), mac0.toByte(),
        )
    }

    /** READ_REG: ROM değeri başlığın "değer" alanında döner, gövdede değil. */
    private fun readReg(address: Int): Int {
        val packet = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).apply {
            put(0); put(CMD_READ_REG); putShort(4); putInt(0); putInt(address)
        }.array()
        port.write(SlipCodec.encode(packet), WRITE_TIMEOUT_MS)
        val deadline = System.currentTimeMillis() + DEFAULT_TIMEOUT_MS
        while (System.currentTimeMillis() < deadline) {
            val frame = SlipCodec.readFrame(port, (deadline - System.currentTimeMillis()).toInt()) ?: continue
            if (frame.size < 10 || frame[0] != 1.toByte() || frame[1] != CMD_READ_REG) continue
            if (frame[8] != 0.toByte()) {
                throw UsbException(espErrorMessage(CMD_READ_REG, frame[9].toInt() and 0xFF))
            }
            return ByteBuffer.wrap(frame, 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
        }
        throw UsbException("The chip did not answer the command (0x%02X).".format(CMD_READ_REG))
    }

    /**
     * Flash'ın tamamını siler.
     *
     * esptool'un `erase_flash` komutu yardımcı bir "stub" yükleyip onun
     * ERASE_FLASH komutunu kullanıyor; burada stub yok. Onun yerine ROM'un
     * kendi FLASH_BEGIN'i, silinecek boyut tüm flash ve yazılacak blok
     * sayısı sıfır verilerek çağrılıyor — FLASH_BEGIN zaten belirtilen
     * bölgeyi silmekle işe başlıyor.
     *
     * Silme, 4 MB'lık bir yongada onlarca saniye sürebilir; zaman aşımı
     * buna göre uzun tutuldu.
     */
    private suspend fun eraseEntireFlash(onLog: (String) -> Unit) {
        onLog("Erasing entire flash (${spec.flashSizeBytes / (1024 * 1024)} MB)...")
        // Silinecek boyut tüm flash, yazılacak blok yok, 0x0'dan itibaren.
        val payload = flashBeginPayload(spec.flashSizeBytes, 0, 0)

        command(CMD_FLASH_BEGIN, payload, timeoutMs = FULL_ERASE_TIMEOUT_MS)
        onLog("Flash erased.")
    }

    /**
     * FLASH_BEGIN komutunun gövdesi.
     *
     * Klasik ESP32 dışındaki yongaların ROM'u (S2, S3, C3, C6, H2…) sona beşinci
     * bir alan bekliyor: "şifreli yaz" bayrağı. esptool bunu
     * `SUPPORTS_ENCRYPTED_FLASH` olan hedeflerde ROM'la konuşurken ekliyor.
     * 16 baytlık gövde S3'te 0x05 ("mesaj geçersiz") ile reddediliyordu:
     * bağlantı ve SPI_ATTACH geçiyor, yükleme ilk FLASH_BEGIN'de düşüyordu.
     * Klasik ESP32'nin ROM'u ise 20 baytı kabul etmiyor; o yüzden koşullu.
     */
    private fun flashBeginPayload(eraseSize: Int, blockCount: Int, offset: Int): ByteArray {
        val chip = spec.chip.lowercase().filter { it.isLetterOrDigit() }
        val withEncryptFlag = chip != "esp32"
        return ByteBuffer.allocate(if (withEncryptFlag) 20 else 16).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(eraseSize)
            putInt(blockCount)
            putInt(FLASH_BLOCK_SIZE)
            putInt(offset)
            if (withEncryptFlag) putInt(0) // şifresiz yaz
        }.array()
    }

    // --- Bootloader'a giriş ------------------------------------------------

    /**
     * Otomatik reset devresini sürerek yongayı seri indirme moduna sokar.
     *
     * Devre şu şekilde bağlı: RTS -> EN (reset), DTR -> GPIO0 (boot seçimi).
     * Yonga resetten çıkarken GPIO0 düşükse ROM bootloader'a girer.
     */
    private suspend fun enterBootloader() {
        port.dtr = false
        port.rts = true // EN düşük: yonga resette
        delay(100)
        port.dtr = true // GPIO0 düşük: indirme modu seçilecek
        port.rts = false // EN yüksek: yonga resetten çıkıyor
        delay(50)
        port.dtr = false // GPIO0 serbest bırakılır
        delay(50)
        drainInput()
    }

    private suspend fun hardReset() {
        port.rts = true
        delay(100)
        port.rts = false
    }

    /**
     * ROM'un hazır olduğunu doğrular.
     *
     * İlk birkaç SYNC'in kaybolması normaldir: yonga henüz resetten
     * çıkıyor olabilir. esptool da aynı şekilde ısrarla dener.
     */
    private suspend fun synchronize(onLog: (String) -> Unit) {
        repeat(SYNC_ATTEMPTS) { attempt ->
            drainInput()
            val payload = byteArrayOf(0x07, 0x07, 0x12, 0x20) + ByteArray(32) { 0x55 }
            val response = runCatching {
                command(CMD_SYNC, payload, timeoutMs = 500)
            }.getOrNull()

            if (response != null) {
                // SYNC'e yonga birden fazla yanıt kuyruklar; kalanları temizle
                // yoksa sonraki komutun yanıtı sanılırlar.
                repeat(7) { SlipCodec.readFrame(port, 100) }
                onLog("Connected (attempt ${attempt + 1}).")
                return
            }
            delay(100)
        }
        throw UsbException(
            "The ESP chip is not responding. Try holding BOOT while pressing " +
                "RESET, or use a different USB cable.",
        )
    }

    /**
     * Bağlantı kurulduktan sonra hızı yükseltir.
     *
     * ROM bootloader'ı 115200'de başlar; 300 KB'lık bir uygulama o hızda
     * dakikalar sürer. Yonga hızı komutu aldığı anda değiştirdiği için
     * portu da hemen çevirmek gerekir, arada gönderilen her şey kaybolur.
     *
     * Başarısız olursa 115200'de devam edilir: yavaş ama çalışır.
     */
    private suspend fun raiseBaudRate(onLog: (String) -> Unit) {
        val target = spec.baudRate
        if (target <= ROM_BAUD) return

        val request = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(target)
            // İkinci alan "şu anki hız"; yalnızca stub kullanılırken anlamlı,
            // ROM yükleyicisinde 0 olmalı.
            putInt(0)
        }.array()

        val replied = runCatching {
            command(CMD_CHANGE_BAUDRATE, request, timeoutMs = DEFAULT_TIMEOUT_MS)
        }.isSuccess

        // ROM yanıtı eski hızda gönderip HEMEN yeni hıza geçiyor. Yanıt
        // kaybolursa (CP2102 gibi köprülerde görüldü) yonga yine de yeni
        // hızdadır; eskiden "hız artırılamadı" deyip 115200'de kalınıyordu,
        // iki taraf farklı hızda konuştuğu için sonraki her komut yanıtsız
        // kalıyordu ("did not answer 0x0D"). Yanıt ne olursa olsun yonga
        // önce yeni hızda, olmazsa eski hızda yoklanıyor.
        if (switchAndProbe(target)) {
            onLog(if (replied) "  Speed raised to $target baud." else "  Speed raised to $target baud (reply was lost).")
            return
        }
        if (switchAndProbe(ROM_BAUD)) {
            onLog("  (could not raise the speed, staying at 115200)")
            return
        }
        throw UsbException(
            "The chip stopped responding right after connecting (no answer at $target or $ROM_BAUD baud). " +
                "It may have reset: check the cable and power, or hold BOOT while uploading.",
        )
    }

    /** Portu [baud]'a çevirir ve yonganın o hızda SYNC'e yanıt verip vermediğine bakar. */
    private suspend fun switchAndProbe(baud: Int): Boolean {
        port.setParameters(baud, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
        // Yonga hız değiştirirken hattaki çöpü at.
        delay(50)
        drainInput()
        val payload = byteArrayOf(0x07, 0x07, 0x12, 0x20) + ByteArray(32) { 0x55 }
        repeat(3) {
            val ok = runCatching { command(CMD_SYNC, payload, timeoutMs = 400) }.isSuccess
            if (ok) {
                // SYNC'e birden fazla yanıt kuyruklanıyor; sonraki komutun yanıtı sanılmasınlar.
                repeat(7) { SlipCodec.readFrame(port, 60) }
                drainInput()
                return true
            }
        }
        return false
    }

    /**
     * Flash yongasının geometrisini ROM'a bildirir.
     *
     * Bu yapılmazsa ROM varsayılan bir boyut varsayar ve 1 MB üstündeki
     * adreslere yazma sessizce yanlış yere gider.
     */
    private suspend fun configureSpiParameters() {
        val params = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(0)                      // flash id (kullanılmıyor)
            putInt(spec.flashSizeBytes)    // toplam boyut
            putInt(64 * 1024)              // blok boyutu
            putInt(4 * 1024)               // sektör boyutu
            putInt(256)                    // sayfa boyutu
            putInt(0xFFFF)                 // durum maskesi
        }.array()
        command(CMD_SPI_SET_PARAMS, params, timeoutMs = DEFAULT_TIMEOUT_MS)
    }

    // --- Yazma -------------------------------------------------------------

    private suspend fun writeRegion(
        address: Int,
        data: ByteArray,
        onLog: (String) -> Unit,
        onRegionProgress: (Long) -> Unit,
    ) {
        val blockCount = (data.size + FLASH_BLOCK_SIZE - 1) / FLASH_BLOCK_SIZE

        // Silinecek boyut = verinin kendi boyutu. Sektöre yuvarlamaya ya da
        // esptool'daki "erase bug" formülüne KAPILMAYIN: o formül ESP8266'ya
        // özgü (`targets/esp8266.py`), ESP32'nin `get_erase_size`'ı boyutu
        // olduğu gibi döndürür. Formülü buraya uygulamak silinen alanı
        // yazılandan küçük yapıyor ve büyük bölgeler yazma hatası (0x108)
        // veriyor; küçük bölgeler tesadüfen geçtiği için geç farkediliyor.
        val eraseSize = data.size
        onLog(
            "  FLASH_BEGIN erase=%d blocks=%d x %d addr=0x%05X".format(
                eraseSize, blockCount, FLASH_BLOCK_SIZE, address,
            ),
        )

        // FLASH_BEGIN hedef bölgeyi siler. Silme flash'ın en yavaş işlemi;
        // 1 MB için birkaç saniye sürebilir, bu yüzden uzun zaman aşımı.
        val begin = flashBeginPayload(eraseSize, blockCount, address)
        command(CMD_FLASH_BEGIN, begin, timeoutMs = ERASE_TIMEOUT_MS)

        for (sequence in 0 until blockCount) {
            val offset = sequence * FLASH_BLOCK_SIZE
            val length = minOf(FLASH_BLOCK_SIZE, data.size - offset)

            // Son blok kısa olabilir; ROM tam blok bekler, kalanı 0xFF ile
            // doldurulur (silinmiş flash'ın doğal değeri).
            val block = ByteArray(FLASH_BLOCK_SIZE) { 0xFF.toByte() }
            System.arraycopy(data, offset, block, 0, length)

            val payload = ByteBuffer.allocate(16 + FLASH_BLOCK_SIZE)
                .order(ByteOrder.LITTLE_ENDIAN).apply {
                    putInt(FLASH_BLOCK_SIZE)
                    putInt(sequence)
                    putInt(0)
                    putInt(0)
                    put(block)
                }.array()

            command(
                CMD_FLASH_DATA, payload,
                timeoutMs = DEFAULT_TIMEOUT_MS,
                checksum = espChecksum(block),
            )
            onRegionProgress((offset + length).toLong())
        }
    }

    /**
     * Yazılan bölgenin MD5'ini yongaya hesaplatıp karşılaştırır.
     *
     * Bayt bayt geri okumaktan çok daha hızlı ve aynı güvenceyi verir.
     */
    private suspend fun verifyMd5(address: Int, data: ByteArray, onLog: (String) -> Unit) {
        val request = ByteBuffer.allocate(16).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(address)
            putInt(data.size)
            putInt(0)
            putInt(0)
        }.array()

        // ROM, MD5'i 32 karakterlik onaltılık METİN olarak, durum
        // baytlarından ÖNCE döner (stub 16 ham bayt döner, onu kullanmıyoruz).
        val response = runCatching {
            command(
                CMD_SPI_FLASH_MD5, request,
                timeoutMs = MD5_TIMEOUT_MS, responseDataLength = 32,
            )
        }.getOrElse {
            // Bazı eski ROM sürümlerinde bu komut yok; doğrulamayı atla.
            onLog("  (this chip does not support MD5 verification, skipped)")
            return
        }

        // ROM yükleyicisi MD5'i 32 karakterlik onaltılık metin olarak döner.
        val reported = response.take(32).toByteArray().toString(Charsets.US_ASCII)
        if (!reported.matches(Regex("[0-9a-f]{32}"))) {
            onLog("  (could not read the MD5 reply, verification skipped)")
            return
        }

        val expected = MessageDigest.getInstance("MD5").digest(data)
            .joinToString("") { "%02x".format(it) }

        if (reported != expected) {
            throw UsbException(
                "Verification failed (0x%05X). The data written does not match what was read back.".format(address),
            )
        }
        onLog("  Verified.")
    }

    // --- Paket katmanı -----------------------------------------------------

    /**
     * Tek bir komut gönderir ve yanıtı doğrular.
     *
     * @param checksum yalnızca veri taşıyan komutlarda anlamlı; diğerlerinde 0
     * @return yanıt paketinin gövdesi (durum baytları çıkarılmış)
     */
    private fun command(
        command: Byte,
        payload: ByteArray,
        timeoutMs: Int,
        checksum: Int = 0,
        expectResponse: Boolean = true,
        responseDataLength: Int = 0,
    ): ByteArray {
        val packet = ByteBuffer.allocate(8 + payload.size).order(ByteOrder.LITTLE_ENDIAN).apply {
            put(0)                       // yön: istek
            put(command)
            putShort(payload.size.toShort())
            putInt(checksum)
            put(payload)
        }.array()

        port.write(SlipCodec.encode(packet), WRITE_TIMEOUT_MS)
        if (!expectResponse) return ByteArray(0)

        val deadline = System.currentTimeMillis() + timeoutMs
        // Yanıt gelmediğinde hatayı açıklamak için: hattan hiç çerçeve mi
        // gelmedi (yonga sustu / hız uyuşmuyor), yoksa başka komutun yanıtı mı?
        var ignoredFrames = 0
        var lastIgnored: ByteArray? = null
        while (System.currentTimeMillis() < deadline) {
            val frame = SlipCodec.readFrame(port, (deadline - System.currentTimeMillis()).toInt())
                ?: continue

            // Yanıt en az 8 baytlık başlık taşımalı ve aynı komuta ait olmalı;
            // eşleşmeyen çerçeveler önceki komutlardan artmış olabilir.
            if (frame.size < 8 || frame[0] != 1.toByte() || frame[1] != command) {
                ignoredFrames++
                lastIgnored = frame
                continue
            }

            val body = frame.copyOfRange(8, frame.size)

            // Durum baytları gövdenin BAŞINDA, komuta özgü yanıt verisinin
            // hemen ardından gelir: [veri...][durum][hata][ayrılmış x2].
            // Sondan okumak yanlış: ESP32 ROM'u iki de "ayrılmış" bayt
            // ekliyor ve onlar çöp olabiliyor — sahte hatalar bundan
            // çıkıyordu (0x63 gibi tanımsız kodlar), gerçek hatalar da
            // gözden kaçabiliyordu.
            if (body.size < responseDataLength + 2) continue

            val failed = body[responseDataLength]
            if (failed != 0.toByte()) {
                val code = body[responseDataLength + 1].toInt() and 0xFF
                throw UsbException(
                    espErrorMessage(command, code) +
                        " [raw reply: ${frame.joinToString(" ") { "%02X".format(it) }}]",
                )
            }
            return body.copyOfRange(0, responseDataLength)
        }
        val detail = if (ignoredFrames == 0) {
            "no data arrived"
        } else {
            "$ignoredFrames unrelated frame(s), last: " +
                lastIgnored!!.take(24).joinToString(" ") { "%02X".format(it) }
        }
        throw UsbException("The chip did not answer the command (0x%02X) [%s].".format(command, detail))
    }

    /**
     * ESP yükleyicisinin veri sağlaması: sabit bir tohumdan başlayan XOR.
     * CRC değil — zayıf ama protokolün tanımı bu.
     */
    private fun espChecksum(data: ByteArray): Int {
        var checksum = 0xEF
        for (b in data) checksum = checksum xor (b.toInt() and 0xFF)
        return checksum
    }

    /** ROM hata kodları (esptool `FatalError.WithResult` tablosunun karşılığı). */
    private fun espErrorMessage(command: Byte, code: Int): String = when (code) {
        0x00 -> "Undefined error."
        0x01 -> "Invalid parameter."
        0x02 -> "The chip could not allocate memory."
        0x03 -> "The chip could not send a reply."
        0x04 -> "The chip could not receive the message."
        0x05 -> "Invalid message format (bad length or framing)."
        0x06 -> "The message was valid but the command did not succeed."
        0x07 -> "Checksum error: the data arrived corrupted. Try a lower baud rate."
        0x08 -> "Flash write error."
        0x09 -> "Flash read error."
        0x0A -> "Flash read length error."
        0x0B -> "Decompression error."
        else -> "Chip error 0x%02X (command 0x%02X).".format(code, command)
    }

    private fun le32(value: Int): ByteArray =
        ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(value).array()

    private fun drainInput() = SerialIo.drain(port)

    private companion object {
        const val CMD_FLASH_BEGIN: Byte = 0x02
        const val CMD_FLASH_DATA: Byte = 0x03
        const val CMD_FLASH_END: Byte = 0x04
        const val CMD_SYNC: Byte = 0x08
        const val CMD_SPI_SET_PARAMS: Byte = 0x0B
        const val CMD_SPI_ATTACH: Byte = 0x0D
        const val CMD_CHANGE_BAUDRATE: Byte = 0x0F
        const val CMD_SPI_FLASH_MD5: Byte = 0x13
        const val CMD_READ_REG: Byte = 0x0A

        const val EFUSE_BLK0_RDATA1 = 0x3FF5A004
        const val EFUSE_BLK0_RDATA2 = 0x3FF5A008

        /** ESP ROM bootloader'ının sabit başlangıç hızı. */
        const val ROM_BAUD = 115_200

        /**
         * ROM yükleyicisinin kabul ettiği blok boyutu. Stub 0x4000 kaldırır
         * ama ROM'da 0x400 üstü paketler kaybolabiliyor.
         */
        const val FLASH_BLOCK_SIZE = 0x400

        const val SYNC_ATTEMPTS = 10
        const val WRITE_TIMEOUT_MS = 3000
        const val DEFAULT_TIMEOUT_MS = 3000

        /** Büyük bölgelerin silinmesi flash'ta onlarca saniye sürebilir. */
        const val ERASE_TIMEOUT_MS = 60_000

        /** Tüm yongayı silmek 16 MB'lık flash'ta dakikaya yaklaşabiliyor. */
        const val FULL_ERASE_TIMEOUT_MS = 180_000
        const val MD5_TIMEOUT_MS = 30_000
    }
}
