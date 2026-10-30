package com.zemits.zemits_factory

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.zemits.zemits_factory.usb.EspLoader
import com.zemits.zemits_factory.usb.EspRomSpec
import com.zemits.zemits_factory.usb.ModuleConsole
import com.zemits.zemits_factory.usb.UsbException
import com.zemits.zemits_factory.usb.UsbSerialManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Dart ↔ USB yükleyici köprüsü.
 *
 * `zemits/usb` metotları hemen döner; yazma sırasında ilerleme ve log satırları
 * `zemits/usb_events` üzerinden `{"type": ...}` haritaları olarak akar.
 * Sketch32'deki köprünün yalnız ESP ROM yüklemesi için sadeleştirilmiş hâli.
 */
class UsbBridge(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val usb = UsbSerialManager(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null
    private var activeJob: Job? = null

    init {
        MethodChannel(messenger, "zemits/usb").setMethodCallHandler(this)
        EventChannel(messenger, "zemits/usb_events").setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listDevices" -> result.success(
                usb.listDevices().map {
                    mapOf(
                        "deviceId" to it.deviceId,
                        "vendorId" to it.vendorId,
                        "productId" to it.productId,
                        "productName" to it.productName,
                        "driverName" to it.driverName,
                        "hasPermission" to it.hasPermission,
                    )
                },
            )
            "flash" -> startFlash(call, result)
            "console" -> runConsole(call, result)
            else -> result.notImplemented()
        }
    }

    /**
     * Argümanlar: `deviceId`, `images: [{address, path}]`, opsiyonel `baudRate`.
     * Başarıda `{mac: "24A160123456", info: "<konsol info JSON>"?, productionReset: bool}` döner;
     * hata `FLASH` koduyla.
     */
    private fun startFlash(call: MethodCall, result: MethodChannel.Result) {
        if (activeJob?.isActive == true) {
            result.error("BUSY", "Another upload is already running.", null)
            return
        }
        val deviceId = call.argument<Int>("deviceId")!!
        val images = call.argument<List<Map<String, Any>>>("images")!!.associate {
            (it["address"] as Number).toInt() to File(it["path"] as String)
        }
        val spec = EspRomSpec(baudRate = call.argument<Int>("baudRate") ?: 921_600)

        // Her aşama hem logcat'e (adb logcat -s ZemitsFlash) hem uygulamadaki günlüğe.
        val log: (String) -> Unit = { line ->
            android.util.Log.i("ZemitsFlash", line)
            emit(mapOf("type" to "log", "line" to line))
        }

        activeJob = scope.launch {
            try {
                // Android her takılışta yeni kimlik verir; liste eskimişse ve takılı tek
                // seri cihaz varsa onu kullan.
                var id = deviceId
                if (!usb.isAttached(id)) {
                    val attached = usb.listDevices()
                    id = attached.singleOrNull()?.deviceId
                        ?: throw Exception("Board not found: the USB cable was unplugged or the board was re-plugged. Tap refresh and try again.")
                    log("USB device was re-plugged; using ${attached.single().driverName} (id $id).")
                }
                log("Waiting for USB permission...")
                if (!usb.requestPermission(id)) {
                    throw Exception("USB permission not granted. Unplug and re-plug the board, allow access, and try again.")
                }
                log("USB permission granted. Opening serial port...")
                val port = usb.open(id, 115_200)
                log("Serial port open.")
                val mac = EspLoader(port, spec).flash(
                    images,
                    onProgress = { p -> emit(mapOf("type" to "progress", "value" to p)) },
                    onLog = log,
                )
                val hex = mac.joinToString("") { "%02X".format(it) }

                // Aynı karta ikinci yükleme: NVS silinmediği için kart "üretim tamamlandı"
                // durumunda açılabilir ve fabrika BLE servisi başlamaz. Konsoldan bakılır,
                // gerekiyorsa bayrak kaldırılır. Başarısızlık yüklemeyi bozmaz; BLE adımı söyler.
                var infoJson: String? = null
                var productionReset = false
                try {
                    usb.closePort()
                    val console = ModuleConsole(usb.open(id, 115_200), log)
                    console.reset()
                    log("Checking the module on the serial console...")
                    val info = console.waitForInfo()
                    infoJson = info.toString()
                    if (info.optString("moduleId") != "ZM$hex") {
                        log("Warning: console reports module ${info.optString("moduleId")}, expected ZM$hex.")
                    }
                    if (info.optBoolean("productionDone", false)) {
                        log("This board was already finalized — returning it to production mode...")
                        val r = console.request("production reset")
                        if (!r.optBoolean("ok", false)) throw UsbException("production reset failed: $r")
                        productionReset = true
                        log("Production mode restored; the module restarts.")
                    } else {
                        log("Module is in production mode.")
                    }
                } catch (e: Exception) {
                    log("Warning: serial console check skipped (${e.message}).")
                }

                val out = mapOf("mac" to hex, "info" to infoJson, "productionReset" to productionReset)
                main.post { result.success(out) }
            } catch (e: Exception) {
                log("ERROR: ${e.message}")
                main.post { result.error("FLASH", e.message ?: "Unknown upload error", null) }
            } finally {
                usb.closePort()
            }
        }
    }

    /**
     * Modülün seri konsoluna tek komut (`deviceId`, `command`); '@' yanıtını JSON metni
     * olarak döner. Kart resetlenmez: tablet o sırada BLE ile de bağlı olabilir.
     * Seri no değişikliği gibi fiziksel erişim isteyen işler için (B-01).
     */
    private fun runConsole(call: MethodCall, result: MethodChannel.Result) {
        if (activeJob?.isActive == true) {
            result.error("BUSY", "Another USB operation is running.", null)
            return
        }
        val deviceId = call.argument<Int>("deviceId")!!
        val command = call.argument<String>("command")!!
        val log: (String) -> Unit = { line ->
            android.util.Log.i("ZemitsFlash", line)
            emit(mapOf("type" to "log", "line" to line))
        }
        activeJob = scope.launch {
            try {
                val id = if (usb.isAttached(deviceId)) deviceId else usb.listDevices().singleOrNull()?.deviceId
                    ?: throw Exception("Module not connected over USB. Connect it with the OTG cable and try again.")
                if (!usb.requestPermission(id)) throw Exception("USB permission not granted.")
                log("Console: $command")
                val reply = ModuleConsole(usb.open(id, 115_200), log).request(command)
                main.post { result.success(reply.toString()) }
            } catch (e: Exception) {
                log("ERROR: ${e.message}")
                main.post { result.error("CONSOLE", e.message ?: "Console error", null) }
            } finally {
                usb.closePort()
            }
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    /** Olay kanalı yalnız ana iş parçacığından beslenebilir. */
    private fun emit(event: Map<String, Any?>) {
        main.post { events?.success(event) }
    }
}
