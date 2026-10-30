package com.zemits.zemits_factory.usb

import com.hoho.android.usbserial.driver.UsbSerialPort
import java.io.ByteArrayOutputStream

/**
 * ESP ROM bootloader'ının kullandığı SLIP çerçeveleme (RFC 1055).
 *
 * Her paket `0xC0` ile başlar ve biter. Veride geçen `0xC0` ve `0xDB`
 * baytları kaçış dizileriyle değiştirilir; aksi halde çerçeve sınırı
 * yanlış yerde algılanır.
 */
object SlipCodec {

    private const val END: Byte = 0xC0.toByte()
    private const val ESC: Byte = 0xDB.toByte()
    private const val ESC_END: Byte = 0xDC.toByte()
    private const val ESC_ESC: Byte = 0xDD.toByte()

    fun encode(payload: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(payload.size + 16)
        out.write(END.toInt())
        for (b in payload) {
            when (b) {
                END -> { out.write(ESC.toInt()); out.write(ESC_END.toInt()) }
                ESC -> { out.write(ESC.toInt()); out.write(ESC_ESC.toInt()) }
                else -> out.write(b.toInt())
            }
        }
        out.write(END.toInt())
        return out.toByteArray()
    }

    /**
     * Porttan tek bir tam SLIP çerçevesi okur.
     *
     * @return çerçevenin kaçışları çözülmüş içeriği; süre dolarsa null
     */
    fun readFrame(port: UsbSerialPort, timeoutMs: Int): ByteArray? {
        val deadline = System.currentTimeMillis() + timeoutMs
        val out = ByteArrayOutputStream(256)
        val chunk = ByteArray(1024)

        var started = false
        var escaped = false

        while (System.currentTimeMillis() < deadline) {
            val read = SerialIo.read(port, chunk, 50)
            for (i in 0 until read) {
                val b = chunk[i]
                when {
                    !started -> if (b == END) started = true // çerçeve öncesi çöpü at
                    escaped -> {
                        out.write(
                            when (b) {
                                ESC_END -> END.toInt()
                                ESC_ESC -> ESC.toInt()
                                // Geçersiz kaçış: bozuk çerçeve, baştan başla.
                                else -> return null
                            },
                        )
                        escaped = false
                    }
                    b == ESC -> escaped = true
                    b == END -> {
                        // Arka arkaya iki END gelirse ilki önceki çerçevenin
                        // bitişi sayılır; boş çerçeveyi atlayıp okumaya devam et.
                        if (out.size() == 0) continue
                        return out.toByteArray()
                    }
                    else -> out.write(b.toInt())
                }
            }
        }
        return null
    }
}
