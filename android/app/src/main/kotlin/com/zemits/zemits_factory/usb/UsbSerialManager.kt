package com.zemits.zemits_factory.usb

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import kotlin.coroutines.resume
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull

/** Bağlı bir kartın kullanıcıya gösterilen bilgileri. */
data class SerialDeviceInfo(
    val deviceId: Int,
    val vendorId: Int,
    val productId: Int,
    val productName: String?,
    /** Sürücü sınıfından türetilen köprü yongası adı, örn. "CH340". */
    val driverName: String,
    val hasPermission: Boolean,
)

/**
 * USB OTG ile bağlı seri kartları bulur, izin ister ve port açar.
 *
 * Android'de USB erişimi kullanıcı onayı gerektirir. Onay cihaz bazlıdır ve
 * cihaz çıkarılınca düşer — bu yüzden her yükleme öncesi kontrol edilir.
 */
class UsbSerialManager(private val context: Context) {

    private val usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager

    /** Şu anda açık olan port; aynı anda tek karta bağlanılır. */
    var openPort: UsbSerialPort? = null
        private set

    fun listDevices(): List<SerialDeviceInfo> =
        UsbSerialProber.getDefaultProber().findAllDrivers(usbManager).map { driver ->
            val device = driver.device
            SerialDeviceInfo(
                deviceId = device.deviceId,
                vendorId = device.vendorId,
                productId = device.productId,
                productName = device.productName,
                driverName = driver.javaClass.simpleName.removeSuffix("SerialDriver"),
                hasPermission = usbManager.hasPermission(device),
            )
        }

    /**
     * Bu kimlikteki cihaz şu an takılı mı.
     *
     * Android her takılışta yeni bir kimlik veriyor; eski kimlikle yapılan
     * işlem cihazı bulamıyor. [requestPermission] bu durumda da `false`
     * döndüğü için çağıran taraf "izin verilmedi" sanıyordu — önce bununla
     * ayırmak gerekiyor.
     */
    fun isAttached(deviceId: Int): Boolean = findDevice(deviceId) != null

    /**
     * Kullanıcıdan USB izni ister ve yanıtı bekler. Zaten izin varsa hemen döner.
     *
     * Sonuç iki yoldan beklenir: sistemin izin yayını ve [UsbManager.hasPermission]
     * yoklaması. MIUI (Android 11) izin penceresi onaylandığı hâlde yayını teslim
     * etmeyebiliyor; yalnız yayına güvenen kod sonsuza kadar bekliyordu. [timeoutMs]
     * dolarsa son izin durumu döner.
     */
    suspend fun requestPermission(deviceId: Int, timeoutMs: Long = 60_000): Boolean {
        val device = findDevice(deviceId) ?: return false
        if (usbManager.hasPermission(device)) return true

        val result = withTimeoutOrNull(timeoutMs) {
            suspendCancellableCoroutine { continuation ->
                val done = AtomicBoolean(false)
                lateinit var receiver: BroadcastReceiver

                fun finish(granted: Boolean) {
                    if (!done.compareAndSet(false, true)) return
                    runCatching { context.unregisterReceiver(receiver) }
                    if (continuation.isActive) continuation.resume(granted)
                }

                receiver = object : BroadcastReceiver() {
                    override fun onReceive(ctx: Context, intent: Intent) {
                        if (intent.action != ACTION_USB_PERMISSION) return
                        finish(intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false))
                    }
                }

                val filter = IntentFilter(ACTION_USB_PERMISSION)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    @Suppress("UnspecifiedRegisterReceiverFlag")
                    context.registerReceiver(receiver, filter)
                }

                continuation.invokeOnCancellation {
                    done.set(true)
                    runCatching { context.unregisterReceiver(receiver) }
                }

                // FLAG_MUTABLE şart: sistem izin sonucunu intent'e ekleyerek
                // geri gönderir, immutable bir PendingIntent ile bunu yapamaz.
                val pending = PendingIntent.getBroadcast(
                    context, 0,
                    Intent(ACTION_USB_PERMISSION).setPackage(context.packageName),
                    PendingIntent.FLAG_MUTABLE,
                )
                usbManager.requestPermission(device, pending)

                // Yayın gelmezse izin durumunu yokla.
                Thread {
                    while (!done.get()) {
                        if (usbManager.hasPermission(device)) {
                            finish(true)
                            break
                        }
                        Thread.sleep(300)
                    }
                }.apply { isDaemon = true }.start()
            }
        }
        return result ?: usbManager.hasPermission(device)
    }

    /**
     * Portu verilen hızda açar.
     *
     * DTR/RTS başlangıçta kapalı bırakılır: birçok kartta DTR resetle
     * bağlıdır ve port açar açmaz kartı sıfırlamak, yükleme protokolünün
     * zamanlamasını bozar. Reset kararını programlayıcı verir.
     */
    fun open(deviceId: Int, baudRate: Int): UsbSerialPort {
        closePort()

        val driver = UsbSerialProber.getDefaultProber().findAllDrivers(usbManager)
            .firstOrNull { it.device.deviceId == deviceId }
            ?: throw UsbException("Device not found (id=$deviceId). The cable may have been unplugged.")

        if (!usbManager.hasPermission(driver.device)) {
            throw UsbException("No USB permission for this device.")
        }

        val connection = usbManager.openDevice(driver.device)
            ?: throw UsbException("Could not open the USB connection. Another app may be using the device.")

        val port = driver.ports.firstOrNull()
            ?: throw UsbException("No serial port found on the device.")

        port.open(connection)
        port.setParameters(baudRate, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
        port.dtr = false
        port.rts = false

        openPort = port
        return port
    }

    fun closePort() {
        openPort?.let { runCatching { it.close() } }
        openPort = null
    }

    private fun findDevice(deviceId: Int): UsbDevice? =
        usbManager.deviceList.values.firstOrNull { it.deviceId == deviceId }

    companion object {
        private const val ACTION_USB_PERMISSION = "com.zemits.zemits_factory.USB_PERMISSION"
    }
}

class UsbException(message: String) : Exception(message)
