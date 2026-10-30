package com.zemits.zemits_factory.usb

import com.hoho.android.usbserial.driver.UsbSerialPort
import java.io.IOException

/**
 * Seri porttan okumanın güvenli hâli.
 *
 * usb-serial-for-android, `bulkTransfer` zaman aşımından önce -1 dönerse
 * bağlantının hâlâ ayakta olduğunu doğrulamak için cihaza standart bir USB
 * GET_STATUS kontrol isteği gönderiyor. Bu istek başarısız olursa
 * `IOException("USB get_status request failed")` fırlatıyor.
 *
 * Sorun şu: birçok USB-seri köprüsü (özellikle CH340 klonları ve bazı CDC
 * cihazlar) bu standart isteği hiç yanıtlamıyor. Cihaz gayet çalışır
 * durumdayken kütüphane onu kopmuş sayıyor; sonuç olarak hem seri izleyici
 * hem de yükleme "get status request failed" ile düşüyordu.
 *
 * Burada bu yanlış alarm yutuluyor ve "veri yok" olarak ele alınıyor.
 * Gerçek kopmalar yine yakalanıyor: port kapandığında kütüphane farklı bir
 * mesaj ("Connection closed") veriyor ve o yukarı iletiliyor.
 */
object SerialIo {

    /**
     * @return okunan bayt sayısı; veri yoksa ya da yanlış alarm oluştuysa 0
     * @throws IOException yalnızca port gerçekten kapandıysa
     */
    fun read(port: UsbSerialPort, destination: ByteArray, timeoutMs: Int): Int = try {
        port.read(destination, timeoutMs)
    } catch (e: IOException) {
        if (isRealDisconnect(e)) throw e else 0
    }

    /**
     * Tampondaki eski baytları atar.
     *
     * Reset öncesinden kalan çöp, protokol yanıtı sanılırsa senkronizasyon
     * hiç kurulamıyor.
     */
    fun drain(port: UsbSerialPort) {
        val scratch = ByteArray(256)
        // Sınırlı tur: sürekli veri basan bir kart varsa sonsuza dek dönmesin.
        repeat(DRAIN_ROUNDS) {
            if (read(port, scratch, DRAIN_TIMEOUT_MS) <= 0) return
        }
    }

    /**
     * Yalnızca portun kapanması gerçek bir kopmadır. Diğer IO hataları
     * yukarıdaki yanlış alarm olabilir ve okuma yeniden denenebilir.
     */
    private fun isRealDisconnect(e: IOException): Boolean =
        e.message?.contains("Connection closed", ignoreCase = true) == true

    private const val DRAIN_ROUNDS = 32
    private const val DRAIN_TIMEOUT_MS = 20
}
